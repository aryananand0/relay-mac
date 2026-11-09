"use strict";

// ---- Tuning -------------------------------------------------------------
// Pointer acceleration, shaped like the Mac's: slow finger = 1:1-ish precision,
// fast flick = big jumps, with a smooth S-curve in between (no sudden kick).
//   gain = settings.speed * (GAIN_SLOW + (GAIN_FAST - GAIN_SLOW) * smoothstep(speed between SPEED_SLOW and SPEED_FAST))
// Speeds are finger speed in CSS px per ms. Cursor speed, scroll speed and
// scroll direction are user settings (the gear button), stored on the phone.
const GAIN_SLOW = 1.2;         // precise placement (text, small buttons)
const GAIN_FAST = 7.0;         // a quick swipe crosses a 1920 px TV in about two strokes
const SPEED_SLOW = 0.05;
const SPEED_FAST = 2.2;
const SPEED_SMOOTHING_MS = 25; // finger-speed averaging window; steadies the gain without lag
const TAP_MAX_MS = 280;        // longer touches are not taps
const TAP_MAX_TRAVEL = 10;     // px of finger travel allowed in a tap
const DOUBLE_CLICK_MS = 350;   // second tap within this window is a double-click
const DRAG_WINDOW_MS = 300;    // touch down this soon after a tap, then move = drag
const DRAG_START_TRAVEL = 6;   // px the second touch must move before the drag starts
const SWIPE_DISTANCE = 45;     // px three or four fingers must travel to trigger a swipe
const PINCH_START = 24;        // px the fingers must spread or close (more than they slide) to zoom
const PINCH_STEP = 60;         // px of spread per zoom step (one ⌘+ or ⌘−)

const SCROLL_GAIN = 1.6;       // Mac scroll pixels per finger px at scroll speed 1
const MOMENTUM_TAU_MS = 400;   // momentum decay time constant (bigger = glides longer)
const MOMENTUM_MIN_SPEED = 0.25; // px/ms of finger speed needed at lift-off to glide
const MOMENTUM_STALE_MS = 80;  // fingers resting this long before lift = no glide

const CONTROL_PORT = 8766;
const CODE_KEY = "relay.pairingCode";

// ---- Settings (stored on the phone) ------------------------------------------
const SETTINGS_KEY = "relay.settings";
const DEFAULT_SETTINGS = { speed: 1, scroll: 1, natural: true, hand: "both" };
const settings = (() => {
  try { return { ...DEFAULT_SETTINGS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}") }; }
  catch { return { ...DEFAULT_SETTINGS }; }
})();
function saveSettings() { try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch {} }

// ---- Elements -----------------------------------------------------------
const $ = (id) => document.getElementById(id);
const pad = $("pad"), conn = $("conn"), statusText = $("status-text"), rttText = $("rtt");
const offline = $("offline"), hint = $("hint");
const warning = $("warning"), pairing = $("pairing"), pairingForm = $("pairing-form");
const pairingInput = $("pairing-code"), pairingError = $("pairing-error");

// ---- Pairing code storage ----------------------------------------------
function loadCode() { try { return localStorage.getItem(CODE_KEY) || ""; } catch { return ""; } }
function saveCode(c) { try { localStorage.setItem(CODE_KEY, c); } catch {} }
function clearCode() { try { localStorage.removeItem(CODE_KEY); } catch {} }

let code = loadCode();
const fromUrl = new URLSearchParams(location.hash.slice(1)).get("k");
if (fromUrl) {
  code = fromUrl.toUpperCase();
  saveCode(code);
  // The code stays in the address on purpose: "Add to Home Screen" saves this URL,
  // and the Home Screen app has its own storage, so the icon pairs itself on first launch.
}

function showPairing(error) {
  pairing.hidden = false;
  pairingError.hidden = !error;
  pairingInput.value = "";
}

pairingForm.addEventListener("submit", (e) => {
  e.preventDefault();
  const entered = pairingInput.value.toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!entered) return;
  code = entered;
  saveCode(code);
  pairing.hidden = true;
  pairingInput.blur();
  connect(true);
});

// ---- Connection ---------------------------------------------------------
let ws = null;
let authed = false;
let retryDelay = 300;
let retryTimer = null;
let lastPong = 0;

// Short blips while reconnecting stay quiet; only a real outage covers the pad.
const OFFLINE_AFTER_MS = 2500;
let offlineTimer = null;

function setStatus(state, text) {
  conn.dataset.state = state || "connecting";
  statusText.textContent = text;
  if (state !== "ok") rttText.textContent = "";
  if (state === "ok") {
    clearTimeout(offlineTimer);
    offlineTimer = null;
    offline.hidden = true;
  } else if (!offlineTimer && offline.hidden) {
    offlineTimer = setTimeout(() => showOffline(), OFFLINE_AFTER_MS);
  }
}

const OFFLINE_TITLE = "Can't reach your Mac";
const OFFLINE_DETAIL = "Check that your Mac is awake and your iPhone is on the same Wi‑Fi.";
function showOffline(title = OFFLINE_TITLE, detail = OFFLINE_DETAIL) {
  offline.querySelector("strong").textContent = title;
  offline.querySelector("span").textContent = detail;
  offline.hidden = false;
}

function connect(immediate) {
  if (!code) { showPairing(false); return; }
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
  clearTimeout(retryTimer);
  if (immediate) retryDelay = 300;

  setStatus("connecting", "Connecting");
  const socket = new WebSocket(`ws://${location.hostname}:${CONTROL_PORT}/`);
  ws = socket;
  authed = false;

  socket.binaryType = "arraybuffer";
  socket.onopen = () => socket.send("a " + code);
  socket.onmessage = (ev) => {
    if (ev.data instanceof ArrayBuffer) { showFrame(ev.data); return; }
    const data = String(ev.data);
    if (data.startsWith("B ")) { showMacClipboard(data.slice(2)); return; }
    const parts = data.split(" ");
    switch (parts[0]) {
      case "ok":
        authed = true;
        retryDelay = 300;
        lastPong = performance.now();
        setStatus("ok", "Connected");
        ping();
        send("q power");
        if (mode === "remote") send("q vol");
        requestPreview();
        break;
      case "no":
        clearCode();
        code = "";
        socket.onclose = null;
        socket.close();
        ws = null;
        setStatus("bad", "Not paired");
        showPairing(true);
        break;
      case "v":
        showVolume(parts);
        break;
      case "W":
        showPower(Number(parts[1]), Number(parts[2]));
        break;
      case "S":
        showLayout(parts);
        break;
      case "C":
        showCursor(Number(parts[1]), Number(parts[2]));
        break;
      case "paused":
        setStatus("bad", "Paused on your Mac");
        showOffline("Relay is paused on your Mac", "Turn it back on from the Relay icon in the Mac's menu bar.");
        break;
      case "P": {
        lastPong = performance.now();
        const rtt = performance.now() - Number(parts[1]);
        if (Number.isFinite(rtt)) rttText.textContent = `${Math.round(rtt)} ms`;
        warning.hidden = parts[2] !== "0";
        break;
      }
    }
  };
  socket.onclose = () => {
    if (ws !== socket) return;
    authed = false;
    setStatus("bad", "Reconnecting");
    retryTimer = setTimeout(() => connect(false), retryDelay);
    retryDelay = Math.min(retryDelay * 2, 3000);
  };
}

function send(msg) {
  if (authed && ws && ws.readyState === WebSocket.OPEN) { ws.send(msg); return true; }
  return false;
}

function ping() { send("p " + performance.now().toFixed(1)); }

// Keep-alive + dead-socket detection (iOS freezes sockets in the background).
setInterval(() => {
  if (!authed) return;
  if (performance.now() - lastPong > 5000) { ws.close(); return; }
  ping();
}, 2000);

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") { stopPreview(); return; }
  requestPreview();
  if (authed) {
    // The socket may look open but be dead after a suspend; verify quickly.
    const sentAt = performance.now();
    ping();
    send("q power");                       // a timer may have ended while away
    if (mode === "remote") send("q vol");   // volume may have changed while away
    setTimeout(() => { if (lastPong < sentAt && ws) ws.close(); }, 1200);
  } else {
    connect(true);
  }
});
window.addEventListener("pageshow", () => connect(true));

// ---- Movement and scrolling ---------------------------------------------
// Deltas are sent right away unless the socket is backed up; leftovers ride
// along with the next message.
const pending = { m: { x: 0, y: 0 }, s: { x: 0, y: 0 } };

function queue(kind, dx, dy) {
  pending[kind].x += dx;
  pending[kind].y += dy;
  if (ws && ws.bufferedAmount > 512) return;
  flush(kind);
}

function flush(kind) {
  const p = pending[kind];
  if (p.x === 0 && p.y === 0) return;
  if (send(`${kind} ${p.x.toFixed(2)} ${p.y.toFixed(2)}`)) p.x = p.y = 0;
}

function flushMove() { flush("m"); }

/// Finger delta → wheel delta. With natural scrolling the content follows the fingers.
function queueScroll(fingerDx, fingerDy) {
  const k = SCROLL_GAIN * settings.scroll * (settings.natural ? 1 : -1);
  queue("s", fingerDx * k, fingerDy * k);
}

// Glide after a two-finger flick, like a Mac trackpad.
let momentum = null;   // { vx, vy, t } in finger px/ms

function startMomentum(vx, vy) {
  if (Math.hypot(vx, vy) < MOMENTUM_MIN_SPEED) return;
  momentum = { vx, vy, t: performance.now() };
  requestAnimationFrame(stepMomentum);
}

function stepMomentum(now) {
  if (!momentum) return;
  const dt = Math.min(Math.max(now - momentum.t, 0), 50);
  momentum.t = now;
  const decay = Math.exp(-dt / MOMENTUM_TAU_MS);
  momentum.vx *= decay;
  momentum.vy *= decay;
  queueScroll(momentum.vx * dt, momentum.vy * dt);
  if (Math.hypot(momentum.vx, momentum.vy) < 0.02) { momentum = null; return; }
  requestAnimationFrame(stepMomentum);
}

function stopMomentum() { momentum = null; }

// ---- Clicks -------------------------------------------------------------
let lastClick = { button: -1, at: 0, count: 0 };

function nextClickCount(button, now) {
  const repeat = button === lastClick.button && now - lastClick.at < DOUBLE_CLICK_MS;
  const count = repeat ? Math.min(lastClick.count + 1, 3) : 1;
  lastClick = { button, at: now, count };
  return count;
}

function click(button) {
  flushMove();
  send(`c ${button} ${nextClickCount(button, performance.now())}`);
}

// ---- Trackpad gestures --------------------------------------------------
//   one finger            move the cursor
//   tap / tap tap         click / double-click
//   tap, then touch+move  drag (left button held until the finger lifts)
//   two fingers           scroll, with momentum on a flick
//   two-finger tap        right-click
//   pinch                 zoom in/out (⌘+ / ⌘−, which browsers and most apps use)
//   3–4 fingers           swipe like a MacBook: ←/→ switch desktops and full-screen apps,
//                         ↑ Mission Control, ↓ the current app's windows (App Exposé)
let gesture = null;   // { startedAt, maxFingers, travel, spread, dragCandidate, dragging, scrolled, pinching, pinch, swipeFrom, swiped }
let track = null;     // the finger driving the cursor: { id, x, y, t }
let pair = null;      // two-finger centroid and finger distance: { x, y, t, n, s }
let speed = 0;        // smoothed one-finger speed, px/ms
let scrollVelocity = { x: 0, y: 0 };
let lastTapAt = -Infinity;

function follow(touch, t) { track = { id: touch.identifier, x: touch.clientX, y: touch.clientY, t }; }
function findTouch(list, id) { for (const t of list) if (t.identifier === id) return t; return null; }
function centroid(list, t) {
  let x = 0, y = 0;
  for (const touch of list) { x += touch.clientX; y += touch.clientY; }
  const s = list.length === 2
    ? Math.hypot(list[0].clientX - list[1].clientX, list[0].clientY - list[1].clientY) : 0;
  return { x: x / list.length, y: y / list.length, t, n: list.length, s };
}

function pointerGain(speed) {
  const t = Math.min(Math.max((speed - SPEED_SLOW) / (SPEED_FAST - SPEED_SLOW), 0), 1);
  return settings.speed * (GAIN_SLOW + (GAIN_FAST - GAIN_SLOW) * t * t * (3 - 2 * t));
}

pad.addEventListener("touchstart", (e) => {
  e.preventDefault();
  stopMomentum();
  const fingers = e.targetTouches.length;
  if (!gesture) {
    gesture = {
      startedAt: e.timeStamp, maxFingers: 0, travel: 0, spread: 0,
      dragCandidate: fingers === 1 && e.timeStamp - lastTapAt < DRAG_WINDOW_MS,
      dragging: false, scrolled: false, pinching: false, pinch: 0, swipeFrom: null, swiped: false,
    };
  }
  gesture.maxFingers = Math.max(gesture.maxFingers, fingers);
  if (fingers === 1) { follow(e.targetTouches[0], e.timeStamp); speed = 0; }
  if (fingers >= 2 && !gesture.dragging) {
    gesture.dragCandidate = false;
    pair = centroid(e.targetTouches, e.timeStamp);
    scrollVelocity = { x: 0, y: 0 };
  }
  pad.classList.add("touching");
}, { passive: false });

pad.addEventListener("touchmove", (e) => {
  e.preventDefault();
  if (!gesture) return;
  const touches = e.targetTouches;

  if (touches.length >= 3 && !gesture.dragging) {
    trackSwipe(centroid(touches, e.timeStamp));
    return;
  }
  // Once three fingers have been down, lifting back to two never scrolls.
  if (gesture.maxFingers >= 3 && !gesture.dragging) return;

  if (touches.length >= 2 && !gesture.dragging) {
    const c = centroid(touches, e.timeStamp);
    if (!pair || pair.n !== c.n) { pair = c; return; }
    const dx = c.x - pair.x, dy = c.y - pair.y, ds = c.s - pair.s;
    const dt = Math.max(c.t - pair.t, 1);
    pair = c;
    if (gesture.pinching) { trackPinch(ds); return; }
    gesture.travel += Math.hypot(dx, dy);
    gesture.spread += ds;
    // Pinch or scroll? Fingers spreading or closing more than they slide = pinch.
    // (Holding one finger still and moving the other slides the centre half as far.)
    const spread = Math.abs(gesture.spread);
    if (!gesture.scrolled && c.n === 2 && spread >= PINCH_START && spread > 1.5 * gesture.travel) {
      gesture.pinching = true;
      gesture.travel = Infinity;   // never a tap
      lastClick.button = -1;
      trackPinch(gesture.spread);
      return;
    }
    if (gesture.travel < TAP_MAX_TRAVEL) return;   // still might be a two-finger tap
    if (!gesture.scrolled && spread >= gesture.travel) return;   // not clear yet
    lastClick.button = -1;
    gesture.scrolled = true;
    scrollVelocity.x = scrollVelocity.x * 0.6 + (dx / dt) * 0.4;
    scrollVelocity.y = scrollVelocity.y * 0.6 + (dy / dt) * 0.4;
    queueScroll(dx, dy);
    return;
  }

  // The finger left behind after a scroll or right-click never moves the cursor.
  if (gesture.maxFingers >= 2 && !gesture.dragging) return;

  const touch = (track && findTouch(touches, track.id)) || touches[0];
  if (!touch) return;
  if (!track || track.id !== touch.identifier) { follow(touch, e.timeStamp); return; }

  const dx = touch.clientX - track.x;
  const dy = touch.clientY - track.y;
  const dt = Math.max(e.timeStamp - track.t, 1);
  const dist = Math.hypot(dx, dy);
  follow(touch, e.timeStamp);
  gesture.travel += dist;
  if (gesture.travel > TAP_MAX_TRAVEL) lastClick.button = -1;

  if (gesture.dragCandidate && !gesture.dragging && gesture.travel > DRAG_START_TRAVEL) {
    flushMove();
    send("d 0 1");
    gesture.dragging = true;
  }

  // Time-weighted average: correct whether touch events arrive at 60 or 120 Hz.
  const alpha = 1 - Math.exp(-dt / SPEED_SMOOTHING_MS);
  speed += (Math.min(dist / dt, 6) - speed) * alpha;
  const gain = pointerGain(speed);
  queue("m", dx * gain, dy * gain);
}, { passive: false });

// Mac shortcuts behind the multi-finger swipes (System Settings › Keyboard ›
// Keyboard Shortcuts › Mission Control; all on by default). Directions follow the
// MacBook: fingers moving left bring in the desktop on the right.
const SWIPES = {
  left: "k right ctrl",    // next desktop / full-screen app
  right: "k left ctrl",    // previous desktop / full-screen app
  up: "k up ctrl",         // Mission Control
  down: "k down ctrl",     // App Exposé
};

function trackSwipe(c) {
  if (!gesture.swipeFrom || gesture.swipeFrom.n !== c.n) {
    // (Re)start measuring when the finger count changes, so fingers landing
    // one after another don't read as movement.
    gesture.swipeFrom = c;
    stopMomentum();
    return;
  }
  if (gesture.swiped) return;   // one action per swipe, like the Mac
  const dx = c.x - gesture.swipeFrom.x, dy = c.y - gesture.swipeFrom.y;
  if (Math.hypot(dx, dy) < SWIPE_DISTANCE) return;
  const direction = Math.abs(dx) > Math.abs(dy) ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down");
  gesture.swiped = true;
  gesture.travel = Infinity;    // never a tap
  lastClick.button = -1;
  flushMove();
  send(SWIPES[direction]);
  ripple(false);
}

function trackPinch(ds) {
  gesture.pinch += ds;
  while (Math.abs(gesture.pinch) >= PINCH_STEP) {
    const zoomIn = gesture.pinch > 0;
    gesture.pinch -= zoomIn ? PINCH_STEP : -PINCH_STEP;
    flushMove();
    send(zoomIn ? "k = cmd" : "k - cmd");
    ripple(!zoomIn);
  }
}

function endTouch(e) {
  e.preventDefault();
  if (!gesture) return;
  const remaining = e.targetTouches.length;

  // Leaving two-finger mode: flick into momentum if the fingers were still moving.
  if (pair && remaining < 2) {
    if (gesture.scrolled && gesture.maxFingers < 3 && e.timeStamp - pair.t < MOMENTUM_STALE_MS) {
      flush("s");
      startMomentum(scrollVelocity.x, scrollVelocity.y);
    }
    pair = null;
  }
  if (remaining > 0) { follow(e.targetTouches[0], e.timeStamp); return; }

  pad.classList.remove("touching");
  flushMove();
  const isTap = e.type === "touchend" && !gesture.dragging &&
    gesture.travel < TAP_MAX_TRAVEL && e.timeStamp - gesture.startedAt < TAP_MAX_MS;
  if (gesture.dragging) {
    send("u 0 1");
  } else if (isTap && gesture.maxFingers <= 2) {
    const right = gesture.maxFingers === 2;
    click(right ? 1 : 0);
    ripple(right);
    lastTapAt = right ? -Infinity : e.timeStamp;
  }
  gesture = null;
  track = null;
}
pad.addEventListener("touchend", endTouch, { passive: false });
pad.addEventListener("touchcancel", endTouch, { passive: false });

// ---- Touch feedback -----------------------------------------------------
// Amber dots light up under the finger, and a ring marks each click.
const HINT_KEY = "relay.hintSeen";
let fingerX = 0, fingerY = 0;
try { if (localStorage.getItem(HINT_KEY)) hint.hidden = true; } catch {}

function showFinger(e) {
  const list = e.targetTouches;
  if (!list.length) return;
  const rect = pad.getBoundingClientRect();
  let x = 0, y = 0;
  for (const t of list) { x += t.clientX; y += t.clientY; }
  fingerX = x / list.length - rect.left;
  fingerY = y / list.length - rect.top;
  pad.style.setProperty("--x", `${fingerX}px`);
  pad.style.setProperty("--y", `${fingerY}px`);
}

function ripple(right) {
  const ring = document.createElement("span");
  ring.className = right ? "ripple right" : "ripple";
  ring.style.left = `${fingerX}px`;
  ring.style.top = `${fingerY}px`;
  ring.addEventListener("animationend", () => ring.remove());
  pad.appendChild(ring);
  setTimeout(() => ring.remove(), 1000);
}

pad.addEventListener("touchstart", (e) => {
  showFinger(e);
  if (!hint.hidden && !hint.classList.contains("gone")) {
    hint.classList.add("gone");
    try { localStorage.setItem(HINT_KEY, "1"); } catch {}
  }
}, { passive: true });
pad.addEventListener("touchmove", showFinger, { passive: true });

// ---- Physical-style buttons (hold Click + move on the pad = drag) -------
for (const el of document.querySelectorAll("#buttons button[data-button]")) {
  const button = Number(el.dataset.button);
  let count = 1;
  let held = false;
  el.addEventListener("touchstart", (e) => {
    e.preventDefault();
    if (held) return;
    held = true;
    flushMove();
    count = nextClickCount(button, performance.now());
    send(`d ${button} ${count}`);
    el.classList.add("down");
  }, { passive: false });
  const release = (e) => {
    e.preventDefault();
    if (!held) return;
    held = false;
    flushMove();
    send(`u ${button} ${count}`);
    el.classList.remove("down");
  };
  el.addEventListener("touchend", release, { passive: false });
  el.addEventListener("touchcancel", release, { passive: false });
}

// ---- Keyboard -----------------------------------------------------------
// The iOS keyboard types into a hidden textarea. Keystrokes are intercepted in
// `beforeinput` and forwarded; anything that slips through (predictive text,
// dictation, paste, IME composition) is recovered by diffing the field.
// The field always holds a few zero-width characters, so Backspace always has
// something to delete and iOS keeps firing it.
const kbInput = $("kb-input"), kbToggle = $("btn-keyboard"), toolbar = $("toolbar");
const SENTINEL = "​​​​";
const SHORTCUT_CHARS = /^[a-z0-9\-=\[\]\;',.\/`]$/;
const MOD_ORDER = ["ctrl", "opt", "shift", "cmd"];
const mods = { ctrl: 0, opt: 0, shift: 0, cmd: 0 };   // 0 off, 1 next key only, 2 locked
let composing = false;

function resetInput() {
  kbInput.value = SENTINEL;
  kbInput.setSelectionRange(SENTINEL.length, SENTINEL.length);
}

function activeMods(extra = []) {
  const on = MOD_ORDER.filter((m) => mods[m] > 0 || extra.includes(m));
  return on.length ? on.join(",") : "-";
}

function consumeMods() {
  for (const m of MOD_ORDER) if (mods[m] === 1) mods[m] = 0;
  renderMods();
}

function sendKey(name, extra = []) {
  send(`k ${name} ${activeMods(extra)}`);
  consumeMods();
}

function sendText(text) {
  if (MOD_ORDER.some((m) => mods[m] > 0)) {
    // A modifier is armed: characters become shortcuts (⌘ + L → ⌘L).
    for (const ch of text) {
      if (ch === "\n") sendKey("return");
      else if (ch === " ") sendKey("space");
      else if (SHORTCUT_CHARS.test(ch.toLowerCase()))
        sendKey(ch.toLowerCase(), ch !== ch.toLowerCase() ? ["shift"] : []);
      else { send(`t ${ch}`); consumeMods(); }
    }
    return;
  }
  text.split("\n").forEach((line, i) => {
    if (i > 0) send("k return -");
    if (line) send(`t ${line}`);
  });
}

kbInput.addEventListener("beforeinput", (e) => {
  if (composing || e.isComposing) return;
  const key = {
    insertLineBreak: ["return"], insertParagraph: ["return"],
    deleteContentBackward: ["delete"], deleteContentForward: ["fwddelete"],
    deleteWordBackward: ["delete", ["opt"]], deleteWordForward: ["fwddelete", ["opt"]],
    deleteSoftLineBackward: ["delete", ["cmd"]], deleteHardLineBackward: ["delete", ["cmd"]],
  }[e.inputType];
  if (key) { e.preventDefault(); sendKey(key[0], key[1]); return; }
  if (e.inputType === "insertText" && e.data) { e.preventDefault(); sendText(e.data); }
  // Everything else lands in the field and is picked up by syncFromInput.
});

function syncFromInput() {
  const value = kbInput.value;
  if (value === SENTINEL) return;
  let kept = 0;
  while (kept < SENTINEL.length && value[kept] === SENTINEL[kept]) kept++;
  const removed = SENTINEL.length - kept;
  const inserted = value.slice(kept).replace(/​/g, "");
  for (let i = 0; i < removed; i++) sendKey("delete");
  if (inserted) sendText(inserted);
  resetInput();
}

kbInput.addEventListener("input", () => { if (!composing) syncFromInput(); });
kbInput.addEventListener("compositionstart", () => { composing = true; });
kbInput.addEventListener("compositionend", () => { composing = false; syncFromInput(); });

function fitToVisibleViewport() {
  // Keep the whole UI above the iOS keyboard.
  const vv = window.visualViewport;
  if (!vv) return;
  document.body.style.height = `${vv.height}px`;
  document.body.style.transform = `translateY(${vv.offsetTop}px)`;
}
if (window.visualViewport) {
  visualViewport.addEventListener("resize", fitToVisibleViewport);
  visualViewport.addEventListener("scroll", fitToVisibleViewport);
}

function enterKeyboardMode() {
  if (document.body.classList.contains("kb-open")) return;
  document.body.classList.add("kb-open");
  resetInput();
  window.scrollTo(0, 0);
}
kbInput.addEventListener("focus", enterKeyboardMode);
kbInput.addEventListener("blur", () => {
  document.body.classList.remove("kb-open");
  for (const m of MOD_ORDER) mods[m] = 0;
  renderMods();
  document.body.style.height = "";
  document.body.style.transform = "";
});

// iOS only shows the keyboard for focus() inside a user gesture, so this is a click handler.
kbToggle.addEventListener("click", () => {
  if (document.activeElement === kbInput) kbInput.blur();
  else {
    resetInput();
    kbInput.focus();
    if (document.activeElement === kbInput) enterKeyboardMode();
  }
});

// Toolbar: act on touchstart (and prevent default) so the textarea keeps focus.
const REPEAT_DELAY_MS = 400, REPEAT_EVERY_MS = 60, LOCK_TAP_MS = 350;
const modTappedAt = { ctrl: 0, opt: 0, shift: 0, cmd: 0 };

function renderMods() {
  for (const el of toolbar.querySelectorAll("[data-mod]")) {
    const state = mods[el.dataset.mod];
    el.classList.toggle("armed", state === 1);
    el.classList.toggle("locked", state === 2);
  }
}

for (const el of toolbar.querySelectorAll("button")) {
  let repeatTimer = null;
  el.addEventListener("touchstart", (e) => {
    e.preventDefault();
    el.classList.add("down");
    const mod = el.dataset.mod;
    if (mod) {
      // Tap: next key only. Double-tap: locked. Tap again: off.
      const now = performance.now();
      if (mods[mod] === 0) mods[mod] = 1;
      else if (mods[mod] === 1 && now - modTappedAt[mod] < LOCK_TAP_MS) mods[mod] = 2;
      else mods[mod] = 0;
      modTappedAt[mod] = now;
      renderMods();
      return;
    }
    sendKey(el.dataset.key);
    if (el.hasAttribute("data-repeat")) {
      repeatTimer = setTimeout(function again() {
        sendKey(el.dataset.key);
        repeatTimer = setTimeout(again, REPEAT_EVERY_MS);
      }, REPEAT_DELAY_MS);
    }
  }, { passive: false });
  const release = (e) => {
    e.preventDefault();
    el.classList.remove("down");
    clearTimeout(repeatTimer);
    repeatTimer = null;
  };
  el.addEventListener("touchend", release, { passive: false });
  el.addEventListener("touchcancel", release, { passive: false });
}

// ---- Settings sheet -----------------------------------------------------
const sheet = $("settings"), settingsButton = $("btn-settings");
const speedInput = $("set-speed"), scrollInput = $("set-scroll"), naturalInput = $("set-natural");
const speedValue = $("set-speed-value"), scrollValue = $("set-scroll-value");
const handChoices = $("set-hand");

function renderSettings() {
  speedInput.value = settings.speed;
  scrollInput.value = settings.scroll;
  naturalInput.checked = settings.natural;
  speedValue.textContent = `${Math.round(settings.speed * 100)}%`;
  scrollValue.textContent = `${Math.round(settings.scroll * 100)}%`;
  for (const b of handChoices.querySelectorAll("[data-hand]")) {
    b.classList.toggle("on", b.dataset.hand === settings.hand);
  }
  applyLayout();
}

// One-handed layout: everything sits at the bottom, with the main buttons on the
// thumb's side. Only applies in portrait; landscape always uses both hands.
function applyLayout() {
  const body = document.body.classList;
  body.toggle("one-hand", settings.hand !== "both");
  body.toggle("hand-left", settings.hand === "left");
  body.toggle("hand-right", settings.hand === "right");
}

function openSettings() {
  if (document.activeElement === kbInput) kbInput.blur();
  renderSettings();
  sheet.hidden = false;
}
function closeSettings() { sheet.hidden = true; }

settingsButton.addEventListener("click", openSettings);
$("settings-done").addEventListener("click", closeSettings);
sheet.addEventListener("click", (e) => { if (e.target === sheet) closeSettings(); });
speedInput.addEventListener("input", () => { settings.speed = Number(speedInput.value); saveSettings(); renderSettings(); });
scrollInput.addEventListener("input", () => { settings.scroll = Number(scrollInput.value); saveSettings(); renderSettings(); });
naturalInput.addEventListener("change", () => { settings.natural = naturalInput.checked; saveSettings(); });
for (const b of handChoices.querySelectorAll("[data-hand]")) {
  b.addEventListener("click", () => { settings.hand = b.dataset.hand; saveSettings(); renderSettings(); });
}
$("settings-reset").addEventListener("click", () => {
  Object.assign(settings, DEFAULT_SETTINGS);
  saveSettings();
  renderSettings();
});
$("settings-hints").addEventListener("click", () => {
  try { localStorage.removeItem(HINT_KEY); } catch {}
  hint.hidden = false;
  hint.classList.remove("gone");
  setMode("trackpad");
  closeSettings();
});

// ---- Modes: Trackpad / Remote / Mac -----------------------------------------
const MODE_KEY = "relay.mode";
const trackpadView = $("trackpad"), remoteView = $("remote"), macView = $("mac");
let mode = "trackpad";

function setMode(next) {
  mode = ["remote", "mac"].includes(next) ? next : "trackpad";
  trackpadView.hidden = mode !== "trackpad";
  remoteView.hidden = mode !== "remote";
  macView.hidden = mode !== "mac";
  document.body.dataset.mode = mode;
  for (const tab of document.querySelectorAll(".modes [data-mode]")) {
    tab.setAttribute("aria-selected", String(tab.dataset.mode === mode));
  }
  try { localStorage.setItem(MODE_KEY, mode); } catch {}
  if (mode === "remote") send("q vol");
  if (mode === "trackpad") requestPreview(); else stopPreview();
}

for (const tab of document.querySelectorAll(".modes [data-mode]")) {
  tab.addEventListener("click", () => setMode(tab.dataset.mode));
}
try { setMode(localStorage.getItem(MODE_KEY) || "trackpad"); } catch { setMode("trackpad"); }
applyLayout();

// ---- Remote and Mac buttons ---------------------------------------------
// Each button sends its data-cmd on touch-down, like a physical remote;
// data-repeat buttons (volume, skip) repeat while held.
for (const el of remoteView.querySelectorAll("button[data-cmd]")) {
  let repeatTimer = null;
  el.addEventListener("touchstart", (e) => {
    e.preventDefault();
    el.classList.add("down");
    sendCommand(el.dataset.cmd);
    if (el.hasAttribute("data-repeat")) {
      repeatTimer = setTimeout(function again() {
        send(el.dataset.cmd);
        repeatTimer = setTimeout(again, 180);
      }, 450);
    }
  }, { passive: false });
  const release = (e) => {
    e.preventDefault();
    el.classList.remove("down");
    clearTimeout(repeatTimer);
    repeatTimer = null;
  };
  el.addEventListener("touchend", release, { passive: false });
  el.addEventListener("touchcancel", release, { passive: false });
}

// ---- Volume status ("v <level|-> <muted> <device name>") -----------------
const VOLUME_STEPS = 16;   // macOS volume keys move in sixteenths
const volumeMeter = $("volume-meter"), volumeDevice = $("volume-device");
const volumeNote = $("volume-note"), muteButton = $("btn-mute");
volumeMeter.innerHTML = "<span></span>".repeat(VOLUME_STEPS);

function showVolume(parts) {
  const level = parts[1] === "-" ? null : Number(parts[1]);
  const muted = parts[2] === "1";
  const device = parts.slice(3).join(" ");
  volumeDevice.textContent = device;
  muteButton.classList.toggle("on", muted);
  muteButton.setAttribute("aria-label", muted ? "Unmute" : "Mute");
  volumeMeter.classList.toggle("muted", muted);
  volumeMeter.classList.toggle("unknown", level === null);
  const lit = level === null ? 0 : Math.round((level / 100) * VOLUME_STEPS);
  volumeMeter.querySelectorAll("span").forEach((seg, i) => seg.classList.toggle("lit", i < lit));
  if (level === null) {
    volumeMeter.removeAttribute("aria-valuenow");
    volumeNote.textContent = `${device} sets its own volume. Use its remote to change it.`;
    volumeNote.hidden = false;
  } else {
    volumeMeter.setAttribute("aria-valuenow", String(level));
    volumeNote.hidden = !muted;
    volumeNote.textContent = muted ? "Sound is muted." : "";
  }
}

// The Mac tab can scroll, so its buttons act on a tap rather than on touch-down.
for (const el of macView.querySelectorAll("button[data-cmd]")) {
  el.addEventListener("click", () => sendCommand(el.dataset.cmd));
}

function sendCommand(cmd) {
  const [kind, arg] = cmd.split(" ");
  if (kind === "w" || kind === "z") choice[kind] = arg;   // remembered to highlight the choice
  if (!send(cmd)) return;
  if (kind === "f") showFound();
}

// ---- Find my cursor -------------------------------------------------------
const findButton = $("btn-find");
function showFound() {
  findButton.classList.add("on");
  setTimeout(() => findButton.classList.remove("on"), 700);
}
findButton.addEventListener("click", () => sendCommand("f"));

// ---- Keep awake and sleep timer ("W <awake> <sleep>") ---------------------
// awake: 0 off, -1 until turned off, else seconds left; sleep: 0 off, else seconds left.
const powerChip = $("power-chip"), awakeState = $("awake-state"), sleepState = $("sleep-state");
const choice = { w: null, z: null };
let power = { awake: 0, sleep: 0, at: 0 };
let powerTicker = null;

function showPower(awake, sleep) {
  if (!Number.isFinite(awake) || !Number.isFinite(sleep)) return;
  power = { awake, sleep, at: performance.now() };
  if (awake === 0) choice.w = "off"; else if (awake < 0) choice.w = "on";
  if (sleep === 0) choice.z = "off";
  clearInterval(powerTicker);
  powerTicker = awake > 0 || sleep > 0 ? setInterval(renderPower, 10000) : null;
  renderPower();
}

function secondsLeft(total) {
  return Math.max(0, total - (performance.now() - power.at) / 1000);
}
function clock(seconds) {
  return new Date(Date.now() + seconds * 1000).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
}
function duration(seconds) {
  const m = Math.max(1, Math.ceil(seconds / 60));
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h${m % 60 ? ` ${m % 60} min` : ""}`;
}

function renderPower() {
  const awake = power.awake > 0 ? secondsLeft(power.awake) : power.awake;
  const sleep = power.sleep > 0 ? secondsLeft(power.sleep) : 0;
  awakeState.textContent = awake === 0 ? "Off" : awake < 0 ? "Until you turn it off" : `Until ${clock(awake)}`;
  sleepState.textContent = sleep > 0 ? `Sleeps at ${clock(sleep)}` : "Off";
  awakeState.classList.toggle("live", awake !== 0);
  sleepState.classList.toggle("live", sleep > 0);
  for (const b of macView.querySelectorAll(".choices button[data-cmd]")) {
    const [kind, arg] = b.dataset.cmd.split(" ");
    b.classList.toggle("on", choice[kind] === arg);
  }
  // The chip in the top bar shows from every mode; tap it to open the Mac tab.
  powerChip.hidden = awake === 0 && sleep === 0;
  powerChip.innerHTML = sleep > 0
    ? `<svg width="13" height="13" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/></svg>${duration(sleep)}`
    : `<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/></svg>Awake`;
  powerChip.setAttribute("aria-label", sleep > 0 ? `Sleep timer: ${duration(sleep)} left` : "Keeping Mac awake");
}
powerChip.addEventListener("click", () => setMode("mac"));
renderPower();

// ---- Clipboard -------------------------------------------------------------
// Safari only allows clipboard access on https pages, so text goes through a box:
// paste into it (touch and hold › Paste) to send, or get the Mac's text into it.
const clipText = $("clip-text"), clipState = $("clip-state");
let clipStateTimer = null;

function setClipState(text) {
  clipState.textContent = text;
  clearTimeout(clipStateTimer);
  if (text) clipStateTimer = setTimeout(() => { clipState.textContent = ""; }, 3000);
}

function sendClipboard(paste) {
  const text = clipText.value;
  if (!text) { setClipState("Paste something first"); return; }
  if (!send("b " + text)) { setClipState("Not connected"); return; }
  if (paste) send("k v cmd");
  setClipState(paste ? "Pasted on your Mac" : "On your Mac's clipboard");
  clipText.blur();
}

function showMacClipboard(text) {
  clipText.value = text;
  setClipState(text ? "From your Mac" : "Mac's clipboard has no text");
}

$("clip-send").addEventListener("click", () => sendClipboard(false));
$("clip-paste").addEventListener("click", () => sendClipboard(true));
$("clip-get").addEventListener("click", () => { if (!send("q clip")) setClipState("Not connected"); });
$("clip-copy").addEventListener("click", () => {
  if (!clipText.value) { setClipState("Nothing to copy"); return; }
  clipText.focus();
  clipText.select();
  clipText.setSelectionRange(0, clipText.value.length);
  let copied = false;
  try { copied = document.execCommand("copy"); } catch {}
  clipText.blur();
  setClipState(copied ? "Copied to your iPhone" : "Select the text and tap Copy");
});

// ---- Screen preview ----------------------------------------------------------
// Off until you tap the screen button, and only while the Trackpad is showing and
// Relay is on screen. By default ("Auto") the Mac sends only the screen the cursor is
// on, full width, and switches when the cursor moves to another screen. "All" stacks
// every screen, each as wide as possible; 1, 2… pin one screen (or swipe between them).
// The Mac sends a frame only when that screen changes, slows down when you're not
// touching anything, and pauses the preview after 3 minutes untouched.
const previewPanel = $("preview"), stage = $("preview-stage"), previewTabs = $("preview-tabs");
const previewMsg = $("preview-msg"), screenButton = $("btn-screen"), previewCursor = $("preview-cursor");
const previewRetry = $("preview-retry");
const PREVIEW_MODE_KEY = "relay.previewMode";
const AUTO = -2, ALL = -1, TILE_GAP = 6;
// (var, not let: setMode reads these while the page is still starting up.)
var previewOn = false;
var previewMode = AUTO;   // AUTO, ALL, or one screen's index
var layout = null;        // { x, y, w, h, shown, rects: [{ x, y, w, h }] } in Mac points
var tiles = [];           // one <img> per screen
var boxes = [];           // where each shown screen sits on the stage, in CSS px
try { const m = Number(localStorage.getItem(PREVIEW_MODE_KEY)); if (m >= AUTO) previewMode = m; } catch {}

function previewWanted() {
  return previewOn && mode === "trackpad" && document.visibilityState === "visible";
}

function shownIndices() {
  if (!layout) return [];
  return layout.shown >= 0 ? [layout.shown] : layout.rects.map((_, i) => i);
}

// The largest width at which the given screens fit, stacked top to bottom.
function fitWidth(indices) {
  const landscape = window.matchMedia("(orientation: landscape) and (max-height: 540px)").matches;
  const availW = previewPanel.clientWidth - 16;
  const share = indices.length > 1 ? 0.56 : 0.42;   // "All" may use more of the pad's height
  const availH = landscape ? previewPanel.clientHeight - 16 : trackpadView.clientHeight * share;
  if (!layout || !indices.length) return Math.max(60, Math.min(availW, availH * 1.6));
  const heightPerWidth = indices.reduce((sum, i) => sum + layout.rects[i].h / layout.rects[i].w, 0);
  return Math.max(60, Math.min(availW, (availH - TILE_GAP * (indices.length - 1)) / heightPerWidth));
}

function requestPreview() {
  if (!previewWanted()) return;
  let indices = [0];
  if (layout) indices = previewMode === ALL ? layout.rects.map((_, i) => i) : [Math.max(previewMode, 0)];
  // Ask for exactly the size it's shown at. Two pixels per point is sharp enough for a
  // preview and costs the Mac less than three.
  const px = Math.round(fitWidth(indices) * Math.min(window.devicePixelRatio || 1, 2));
  if (send(`i on ${px} ${previewMode}`) && !tiles.length) showPreviewMessage(null);
}

function stopPreview() {
  if (previewOn) send("i off");
}

function setPreview(on) {
  previewOn = on;
  document.body.classList.toggle("previewing", on);
  previewPanel.hidden = !on;
  screenButton.classList.toggle("on", on);
  screenButton.setAttribute("aria-pressed", String(on));
  if (on) { sizeStage(); requestPreview(); }
  else { send("i off"); clearTiles(); layout = null; }
}
screenButton.addEventListener("click", () => {
  if (mode !== "trackpad") { setMode("trackpad"); if (previewOn) return; }
  setPreview(!previewOn);
});

function choosePreview(next) {
  if (next === previewMode && !(layout && layout.paused)) return;
  previewMode = next;
  try { localStorage.setItem(PREVIEW_MODE_KEY, String(next)); } catch {}
  requestPreview();
}

function clearTiles() {
  for (const img of tiles) { if (img && img.src) URL.revokeObjectURL(img.src); if (img) img.remove(); }
  tiles = [];
  boxes = [];
  previewCursor.toggleAttribute("hidden", true);   // (an SVG element has no .hidden property)
}

function showPreviewMessage(text, button = "Try again") {
  previewMsg.hidden = !text;
  stage.hidden = !!text;
  if (text) { previewMsg.querySelector("p").textContent = text; previewRetry.textContent = button; }
}
previewRetry.addEventListener("click", requestPreview);

// "S <x> <y> <w> <h> <shown> <x,y,w,h>…", "S denied" or "S paused"
function showLayout(parts) {
  if (parts[1] === "denied") {
    clearTiles();
    showPreviewMessage("To show your screen here, Relay needs Screen Recording permission. On your Mac, open System Settings › Privacy & Security › Screen & System Audio Recording and turn on Relay. Then choose Restart Relay from the Relay icon in the menu bar.");
    return;
  }
  if (parts[1] === "paused") {
    clearTiles();
    showPreviewMessage("Preview paused to save battery after 3 minutes without touching.", "Resume");
    return;
  }
  const [x, y, w, h, shown] = parts.slice(1, 6).map(Number);
  const rects = parts.slice(6).map((r) => { const [rx, ry, rw, rh] = r.split(",").map(Number); return { x: rx, y: ry, w: rw, h: rh }; });
  layout = { x, y, w, h, shown, rects };
  showPreviewMessage(null);
  clearTiles();
  for (const i of shownIndices()) {
    const img = document.createElement("img");
    img.alt = "";
    img.className = "tile";
    stage.insertBefore(img, previewCursor);
    tiles[i] = img;
  }
  renderPicker();
  sizeStage();
}

// Auto · 1 · 2 · All, only with more than one screen. In Auto, the screen being
// followed is outlined.
function renderPicker() {
  previewTabs.innerHTML = "";
  if (!layout || layout.rects.length < 2) return;
  const choices = [[AUTO, "Auto", "Follow the cursor"],
    ...layout.rects.map((_, i) => [i, String(i + 1), `Screen ${i + 1}`]), [ALL, "All", "All screens"]];
  for (const [value, label, name] of choices) {
    const b = document.createElement("button");
    b.textContent = label;
    b.setAttribute("aria-label", name);
    b.classList.toggle("on", value === previewMode);
    b.classList.toggle("follow", previewMode === AUTO && value === layout.shown);
    b.addEventListener("touchstart", (e) => { e.stopPropagation(); }, { passive: true });
    b.addEventListener("touchend", (e) => { e.preventDefault(); e.stopPropagation(); choosePreview(value); });
    previewTabs.appendChild(b);
  }
}

// Lay the shown screens out on the stage: one screen fills the width; several are
// stacked so each is as wide as it can be (side by side they'd be tiny on a phone).
function sizeStage() {
  if (!previewOn) return;
  const indices = shownIndices();
  const w = fitWidth(indices);
  boxes = [];
  let top = 0;
  for (const i of indices) {
    const r = layout.rects[i];
    const h = (w * r.h) / r.w;
    boxes[i] = { x: 0, y: top, w, h };
    const img = tiles[i];
    if (img) Object.assign(img.style, { left: "0px", top: `${top}px`, width: `${w}px`, height: `${h}px` });
    top += h + TILE_GAP;
  }
  const height = indices.length ? top - TILE_GAP : w / 1.6;
  stage.style.width = `${w}px`;
  stage.style.height = `${height}px`;
}
window.addEventListener("resize", () => { sizeStage(); });

// Which shown screen a stage position (CSS px) is on, and the Mac point there.
function stageToMac(px, py) {
  for (const i of shownIndices()) {
    const b = boxes[i], r = layout.rects[i];
    if (b && px >= b.x && px <= b.x + b.w && py >= b.y && py <= b.y + b.h) {
      return { x: r.x + ((px - b.x) / b.w) * r.w, y: r.y + ((py - b.y) / b.h) * r.h };
    }
  }
  return null;
}

// "C x y": the Mac sends the cursor position on its own (frames don't include the
// cursor), so moving it costs a few bytes instead of a new picture of the screen.
function showCursor(x, y) {
  if (!layout || !Number.isFinite(x) || !Number.isFinite(y)) return;
  for (const i of shownIndices()) {
    const r = layout.rects[i], b = boxes[i];
    if (b && x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h) {
      previewCursor.style.left = `${b.x + ((x - r.x) / r.w) * b.w}px`;
      previewCursor.style.top = `${b.y + ((y - r.y) / r.h) * b.h}px`;
      previewCursor.toggleAttribute("hidden", false);
      return;
    }
  }
  previewCursor.toggleAttribute("hidden", true);
}

// Binary frame: 1 byte screen index, then a JPEG.
function showFrame(buffer) {
  const index = new Uint8Array(buffer, 0, 1)[0];
  const img = tiles[index];
  const ack = () => send(`i ack ${index}`);
  if (!img) { ack(); return; }
  const url = URL.createObjectURL(new Blob([new Uint8Array(buffer, 1)], { type: "image/jpeg" }));
  const old = img.src;
  img.onload = () => { if (old) URL.revokeObjectURL(old); img.classList.add("live"); ack(); };
  img.onerror = () => { URL.revokeObjectURL(url); ack(); };
  img.src = url;
}

// Tap the preview to put the cursor there; swipe sideways to show the next screen.
let stageTouch = null;
stage.addEventListener("touchstart", (e) => {
  e.preventDefault();
  const t = e.changedTouches[0];
  stageTouch = { x: t.clientX, y: t.clientY, at: e.timeStamp };
}, { passive: false });
stage.addEventListener("touchend", (e) => {
  e.preventDefault();
  const t = e.changedTouches[0];
  if (!stageTouch || !layout) return;
  const dx = t.clientX - stageTouch.x, dy = t.clientY - stageTouch.y;
  const quick = e.timeStamp - stageTouch.at < 500;
  stageTouch = null;
  const count = layout.rects.length;
  if (count > 1 && layout.shown >= 0 && Math.abs(dx) > 50 && Math.abs(dx) > 2 * Math.abs(dy)) {
    choosePreview((layout.shown + (dx < 0 ? 1 : count - 1)) % count);
    return;
  }
  if (Math.hypot(dx, dy) > TAP_MAX_TRAVEL || !quick) return;
  const rect = stage.getBoundingClientRect();
  const px = t.clientX - rect.left, py = t.clientY - rect.top;
  const point = stageToMac(px, py);
  if (!point) return;
  send(`j ${point.x.toFixed(1)} ${point.y.toFixed(1)}`);
  const dot = document.createElement("span");
  dot.className = "ripple";
  dot.style.left = `${px}px`;
  dot.style.top = `${py}px`;
  dot.addEventListener("animationend", () => dot.remove());
  stage.appendChild(dot);
}, { passive: false });

// Block pinch-zoom and page rubber-banding everywhere except the pairing form.
document.addEventListener("gesturestart", (e) => e.preventDefault());
// The pairing form, the settings sliders and the Mac tab (which can scroll) need
// normal touch handling.
document.addEventListener("touchmove", (e) => {
  if (pairing.hidden && sheet.hidden && !e.target.closest(".mac")) e.preventDefault();
}, { passive: false });

connect(true);

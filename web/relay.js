"use strict";

// ---- Tuning -------------------------------------------------------------
// Pointer acceleration, shaped like the Mac's: slow finger = 1:1-ish precision,
// fast flick = big jumps, with a smooth S-curve in between (no sudden kick).
//   gain = SENSITIVITY * (GAIN_SLOW + (GAIN_FAST - GAIN_SLOW) * smoothstep(speed between SPEED_SLOW and SPEED_FAST))
// Speeds are finger speed in CSS px per ms. Raise SENSITIVITY to make everything faster.
const SENSITIVITY = 1.0;
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

const SCROLL_GAIN = 1.6;       // Mac scroll pixels per finger px
const NATURAL_SCROLL = true;   // content follows your fingers, like a Mac trackpad
const MOMENTUM_TAU_MS = 400;   // momentum decay time constant (bigger = glides longer)
const MOMENTUM_MIN_SPEED = 0.25; // px/ms of finger speed needed at lift-off to glide
const MOMENTUM_STALE_MS = 80;  // fingers resting this long before lift = no glide

const CONTROL_PORT = 8766;
const CODE_KEY = "relay.pairingCode";

// ---- Elements -----------------------------------------------------------
const $ = (id) => document.getElementById(id);
const pad = $("pad"), conn = $("conn"), statusText = $("status-text"), rttText = $("rtt");
const offline = $("offline"), hint = $("hint"), keyboardLabel = $("keyboard-label");
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
    offlineTimer = setTimeout(() => { offline.hidden = false; }, OFFLINE_AFTER_MS);
  }
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

  socket.onopen = () => socket.send("a " + code);
  socket.onmessage = (ev) => {
    const parts = String(ev.data).split(" ");
    switch (parts[0]) {
      case "ok":
        authed = true;
        retryDelay = 300;
        lastPong = performance.now();
        setStatus("ok", "Connected");
        ping();
        if (mode === "remote") send("q vol");
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
  if (document.visibilityState !== "visible") return;
  if (authed) {
    // The socket may look open but be dead after a suspend; verify quickly.
    const sentAt = performance.now();
    ping();
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
  const k = SCROLL_GAIN * (NATURAL_SCROLL ? 1 : -1);
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
let gesture = null;   // { startedAt, maxFingers, travel, dragCandidate, dragging, scrolled }
let track = null;     // the finger driving the cursor: { id, x, y, t }
let pair = null;      // two-finger centroid: { x, y, t, n }
let speed = 0;        // smoothed one-finger speed, px/ms
let scrollVelocity = { x: 0, y: 0 };
let lastTapAt = -Infinity;

function follow(touch, t) { track = { id: touch.identifier, x: touch.clientX, y: touch.clientY, t }; }
function findTouch(list, id) { for (const t of list) if (t.identifier === id) return t; return null; }
function centroid(list, t) {
  let x = 0, y = 0;
  for (const touch of list) { x += touch.clientX; y += touch.clientY; }
  return { x: x / list.length, y: y / list.length, t, n: list.length };
}

function pointerGain(speed) {
  const t = Math.min(Math.max((speed - SPEED_SLOW) / (SPEED_FAST - SPEED_SLOW), 0), 1);
  return SENSITIVITY * (GAIN_SLOW + (GAIN_FAST - GAIN_SLOW) * t * t * (3 - 2 * t));
}

pad.addEventListener("touchstart", (e) => {
  e.preventDefault();
  stopMomentum();
  const fingers = e.targetTouches.length;
  if (!gesture) {
    gesture = {
      startedAt: e.timeStamp, maxFingers: 0, travel: 0,
      dragCandidate: fingers === 1 && e.timeStamp - lastTapAt < DRAG_WINDOW_MS,
      dragging: false, scrolled: false,
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

  if (touches.length >= 2 && !gesture.dragging) {
    const c = centroid(touches, e.timeStamp);
    if (!pair || pair.n !== c.n) { pair = c; return; }
    const dx = c.x - pair.x, dy = c.y - pair.y;
    const dt = Math.max(c.t - pair.t, 1);
    pair = c;
    gesture.travel += Math.hypot(dx, dy);
    if (gesture.travel < TAP_MAX_TRAVEL) return;   // still might be a two-finger tap
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

function endTouch(e) {
  e.preventDefault();
  if (!gesture) return;
  const remaining = e.targetTouches.length;

  // Leaving two-finger mode: flick into momentum if the fingers were still moving.
  if (pair && remaining < 2) {
    if (gesture.scrolled && e.timeStamp - pair.t < MOMENTUM_STALE_MS) {
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
  } else if (isTap) {
    const right = gesture.maxFingers >= 2;
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
  keyboardLabel.textContent = "Done";
  resetInput();
  window.scrollTo(0, 0);
}
kbInput.addEventListener("focus", enterKeyboardMode);
kbInput.addEventListener("blur", () => {
  document.body.classList.remove("kb-open");
  keyboardLabel.textContent = "Keyboard";
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

// ---- Modes: Trackpad / Remote --------------------------------------------
const MODE_KEY = "relay.mode";
const trackpadView = $("trackpad"), remoteView = $("remote");
let mode = "trackpad";

function setMode(next) {
  mode = next === "remote" ? "remote" : "trackpad";
  trackpadView.hidden = mode !== "trackpad";
  remoteView.hidden = mode !== "remote";
  for (const tab of document.querySelectorAll(".modes [data-mode]")) {
    tab.setAttribute("aria-selected", String(tab.dataset.mode === mode));
  }
  try { localStorage.setItem(MODE_KEY, mode); } catch {}
  if (mode === "remote") send("q vol");
}

for (const tab of document.querySelectorAll(".modes [data-mode]")) {
  tab.addEventListener("click", () => setMode(tab.dataset.mode));
}
try { setMode(localStorage.getItem(MODE_KEY) || "trackpad"); } catch { setMode("trackpad"); }

// ---- Remote buttons -----------------------------------------------------
// Each button sends its data-cmd on touch-down, like a physical remote;
// data-repeat buttons (volume, skip) repeat while held.
for (const el of remoteView.querySelectorAll("button[data-cmd]")) {
  let repeatTimer = null;
  el.addEventListener("touchstart", (e) => {
    e.preventDefault();
    el.classList.add("down");
    send(el.dataset.cmd);
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

// Block pinch-zoom and page rubber-banding everywhere except the pairing form.
document.addEventListener("gesturestart", (e) => e.preventDefault());
document.addEventListener("touchmove", (e) => { if (pairing.hidden) e.preventDefault(); }, { passive: false });

connect(true);

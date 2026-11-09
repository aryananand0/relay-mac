"use strict";
// A simulated Mac for README screenshots. tools/screenshots/capture.sh loads the real phone
// page (web/) with this script in place of the network: it speaks Relay's real protocol,
// including the encrypted handshake, but answers with made-up data, so screenshots never
// show anyone's real screen, devices or pairing code.
(() => {
  const DEMO_CODE = "DEMO2345KMNP";
  const shot = new URLSearchParams(location.search).get("shot") || "trackpad";
  // Several shots load side by side and share this origin's storage, so only the (identical)
  // pairing code goes there; each shot's own state is applied after load, below.
  // ?pairing=test leaves storage alone, for testing how the page picks its code.
  if (new URLSearchParams(location.search).get("pairing") !== "test") {
    try { localStorage.setItem("relay.pairingCode", DEMO_CODE); } catch {}
  }

  const enc = new TextEncoder(), dec = new TextDecoder();
  const SCREENS = [{ x: 0, y: 0, w: 1512, h: 982 }, { x: 1512, y: -98, w: 1920, h: 1080 }];

  // A made-up desktop: wallpaper, menu bar, a couple of windows. Drawn, not captured.
  function desktop(w, h, variant) {
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    const g = c.getContext("2d");
    const bg = g.createLinearGradient(0, 0, w, h);
    bg.addColorStop(0, variant ? "#1d2b3a" : "#2a2238"); bg.addColorStop(1, variant ? "#0e1620" : "#151020");
    g.fillStyle = bg; g.fillRect(0, 0, w, h);
    g.fillStyle = "rgba(255,255,255,0.10)"; g.fillRect(0, 0, w, h * 0.03);
    const win = (x, y, ww, hh, accent) => {
      g.fillStyle = "rgba(28,28,32,0.96)"; g.beginPath(); g.roundRect(x, y, ww, hh, h * 0.012); g.fill();
      ["#ff5f57", "#febc2e", "#28c840"].forEach((col, i) => { g.fillStyle = col; g.beginPath(); g.arc(x + h * (0.022 + i * 0.022), y + h * 0.022, h * 0.007, 0, 7); g.fill(); });
      g.fillStyle = accent; g.fillRect(x + ww * 0.05, y + hh * 0.14, ww * 0.9, hh * 0.5);
      g.fillStyle = "rgba(255,255,255,0.18)";
      for (let i = 0; i < 4; i++) g.fillRect(x + ww * 0.05, y + hh * (0.7 + i * 0.07), ww * (0.85 - i * 0.15), hh * 0.03);
    };
    if (variant) { win(w * 0.08, h * 0.1, w * 0.84, h * 0.8, "#203a55"); }
    else { win(w * 0.06, h * 0.1, w * 0.55, h * 0.62, "#3b2a5c"); win(w * 0.5, h * 0.32, w * 0.42, h * 0.55, "#28463d"); }
    // Synchronous, so frames are ready before the headless screenshot is taken.
    return Uint8Array.from(atob(c.toDataURL("image/jpeg", 0.85).split(",")[1]), (ch) => ch.charCodeAt(0));
  }

  class DemoMac {
    constructor() {
      this.readyState = 0; this.bufferedAmount = 0; this.binaryType = "arraybuffer";
      this.macNonce = crypto.getRandomValues(new Uint8Array(16));
      this.macSecret = crypto.getRandomValues(new Uint8Array(32));
      this.macPublic = RelayCrypto.x25519(this.macSecret, RelayCrypto.BASE);
      this.salt = crypto.getRandomValues(new Uint8Array(16));
      const hello = ["n", this.macNonce, this.macPublic, this.salt].map((x) => typeof x === "string" ? x : RelayCrypto.toHex(x));
      setTimeout(() => { this.readyState = 1; this.deliver(hello.join(" ") + " 600000"); }, 30);
    }
    deliver(data) { setTimeout(() => this.onmessage && this.onmessage({ data }), 5); }
    sendSealed(kind, bytes) {
      const plain = new Uint8Array(bytes.length + 1); plain[0] = kind; plain.set(bytes, 1);
      this.deliver(RelayCrypto.seal(this.toPhone, this.outCount++, plain).buffer);
    }
    say(text) { this.sendSealed(0x54, enc.encode(text)); }
    send(data) {
      if (typeof data === "string") {          // the handshake
        const [, nonceHex, publicHex, proofHex] = data.split(" ");
        const phonePublic = RelayCrypto.fromHex(publicHex);
        const shared = RelayCrypto.x25519(this.macSecret, phonePublic);
        const stretched = RelayCrypto.stretchCode(DEMO_CODE, RelayCrypto.toHex(this.salt), 600000);
        const keys = RelayCrypto.hkdf(RelayCrypto.concat(shared, stretched),
          RelayCrypto.concat(this.macNonce, RelayCrypto.fromHex(nonceHex), this.macPublic, phonePublic), enc.encode("relay v2"), 96);
        // Check the proof like the real Mac does, so a wrong code is refused.
        const expected = RelayCrypto.toHex(RelayCrypto.hmac(keys.subarray(0, 32), enc.encode("relay-auth-v2")));
        window.demoAttempts = (window.demoAttempts || 0) + 1;
        if (window.demoLockedOut) { this.deliver("wait"); return; }
        if (expected !== proofHex) { this.deliver("no"); return; }
        this.fromPhone = keys.slice(32, 64); this.toPhone = keys.slice(64, 96); this.inCount = 0; this.outCount = 0;
        this.say("ok");
        return;
      }
      const text = dec.decode(RelayCrypto.open(this.fromPhone, this.inCount++, data).subarray(1));
      const [cmd, a, b] = text.split(" ");
      if (cmd === "p") setTimeout(() => this.say(`P ${a} 1`), 4);
      if (cmd === "q" && a === "vol") this.say("v 63 0 MacBook Pro Speakers");
      if (cmd === "q" && a === "power") this.say(shot === "mac" ? "W -1 2580" : "W 0 0");
      if (cmd === "i" && a === "on") this.preview(Number(text.split(" ")[3]));
    }
    preview(mode) {
      const shown = mode === -1 ? -1 : 0;
      this.say(`S 0 -98 3432 1080 ${shown} ` + SCREENS.map((s) => `${s.x},${s.y},${s.w},${s.h}`).join(" "));
      for (const i of shown === -1 ? [0, 1] : [0]) {
        const s = SCREENS[i];
        const jpeg = desktop(Math.round(s.w / 2), Math.round(s.h / 2), i);
        const frame = new Uint8Array(jpeg.length + 1); frame[0] = i; frame.set(jpeg, 1);
        this.sendSealed(0x46, frame);
      }
      this.say("C 560 330");
    }
    close() {}
  }
  window.WebSocket = DemoMac;
  window.WebSocket.CONNECTING = 0; window.WebSocket.OPEN = 1;

  // Screenshots are still images: skip the fade-in so frames show at once.
  document.addEventListener("DOMContentLoaded", () => {
    const style = document.createElement("style");
    style.textContent = ".preview-stage .tile { transition: none !important; }";
    document.head.appendChild(style);
  });

  // Per-shot setup once the real page has connected.
  window.addEventListener("load", () => setTimeout(() => {
    setMode({ remote: "remote", mac: "mac" }[shot] || "trackpad");
    hint.hidden = shot !== "trackpad";
    hint.classList.remove("gone");
    previewMode = shot === "screens" ? -1 : -2;
    if (["preview", "screens", "landscape"].includes(shot)) { setPreview(true); }
    if (shot === "mac") { $("clip-text").value = "https://example.com/recipes/weeknight-pasta"; }
  }, 400));
})();

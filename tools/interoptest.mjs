// Pairs with the running Relay using the phone's own web/crypto.js (in Node instead of
// Safari) and exchanges encrypted messages, proving the phone and Mac implementations agree.
// Usage: node tools/interoptest.mjs <pairing code>
import { createRequire } from "node:module";
const RC = createRequire(import.meta.url)("../web/crypto.js");
const code = process.argv[2];
const enc = new TextEncoder(), dec = new TextDecoder();
const ws = new WebSocket("ws://127.0.0.1:8766/");
ws.binaryType = "arraybuffer";
let channel = null;
const fail = (why) => { console.log("FAIL:", why); process.exit(1); };
setTimeout(() => fail("timed out"), 10000);

ws.onmessage = (ev) => {
  if (typeof ev.data === "string") {
    const p = ev.data.split(" ");
    if (p[0] !== "n") fail(`refused: ${ev.data}`);
    const t0 = performance.now();
    const stretched = RC.stretchCode(code, p[3], Number(p[4]));
    const hello = RC.handshake(stretched, p[1], p[2]);
    console.log(`stretched the code (${p[4]} rounds) in ${Math.round(performance.now() - t0)} ms`);
    channel = { send: hello.sendKey, recv: hello.receiveKey, out: 0, in: 0 };
    ws.send(hello.reply);
    return;
  }
  const plain = RC.open(channel.recv, channel.in++, new Uint8Array(ev.data));
  if (!plain) fail("could not open a message from the Mac");
  const text = dec.decode(plain.subarray(1));
  if (text === "ok") {
    ws.send(RC.seal(channel.send, channel.out++, enc.encode("Tp 42")));
  } else if (text.startsWith("P 42 ")) {
    console.log("PASS: web/crypto.js pairs with the Mac app and talks encrypted");
    ws.close();
    process.exit(0);
  }
};
ws.onerror = () => fail("connection error");

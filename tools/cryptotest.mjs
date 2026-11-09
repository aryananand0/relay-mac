// Checks web/crypto.js against Node's crypto module (OpenSSL) byte for byte:
// SHA-256, HMAC-SHA256, HKDF-SHA256 and ChaCha20-Poly1305, over many random inputs and
// sizes, plus tamper and wrong-counter rejection.  Run: node tools/cryptotest.mjs
import { createRequire } from "node:module";
import crypto from "node:crypto";
const require = createRequire(import.meta.url);
const RC = require("../web/crypto.js");

let failures = 0;
const check = (ok, what) => { if (!ok) { failures++; console.log("FAIL:", what); } };
const eq = (a, b) => Buffer.from(a).equals(Buffer.from(b));
const rand = (n) => new Uint8Array(crypto.randomBytes(n));
const sizes = [0, 1, 15, 16, 17, 31, 32, 55, 56, 63, 64, 65, 127, 128, 1000, 4096, 80_000];

for (const n of sizes) {
  const data = rand(n), key = rand(n % 100 + 1);
  check(eq(RC.sha256(data), crypto.createHash("sha256").update(data).digest()), `sha256 ${n}`);
  check(eq(RC.hmac(key, data), crypto.createHmac("sha256", key).update(data).digest()), `hmac ${n}`);
}
const longKey = rand(150), msg = rand(77);
check(eq(RC.hmac(longKey, msg), crypto.createHmac("sha256", longKey).update(msg).digest()), "hmac long key");

for (const len of [32, 96, 100]) {
  const ikm = rand(12), salt = rand(32), info = new TextEncoder().encode("relay v1");
  check(eq(RC.hkdf(ikm, salt, info, len), new Uint8Array(crypto.hkdfSync("sha256", ikm, salt, info, len))), `hkdf ${len}`);
}

for (const n of sizes) {
  const key = rand(32), counter = Math.floor(Math.random() * 1e9), plain = rand(n);
  const nonce = Buffer.alloc(12); nonce.writeBigUInt64BE(BigInt(counter), 4);
  const c = crypto.createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  const expected = Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
  const sealed = RC.seal(key, counter, plain);
  check(eq(sealed, expected), `seal ${n}`);
  check(eq(RC.open(key, counter, sealed) ?? [1], plain), `open ${n}`);
  check(RC.open(key, counter + 1, sealed) === null, `wrong counter rejected ${n}`);
  const tampered = sealed.slice(); tampered[Math.floor(Math.random() * tampered.length)] ^= 1;
  check(RC.open(key, counter, tampered) === null, `tampered rejected ${n}`);
}

// PBKDF2 against Node, including the 600 000 iterations Relay uses (timed).
for (const iters of [1, 2, 1000]) {
  const pw = rand(12), salt = rand(16);
  check(eq(RC.pbkdf2(pw, salt, iters), crypto.pbkdf2Sync(pw, salt, iters, 32, "sha256")), `pbkdf2 ${iters}`);
}
{
  const pw = new TextEncoder().encode("ABCDEFGHJKMN"), salt = rand(16);
  const t0 = performance.now();
  const ours = RC.pbkdf2(pw, salt, 600000);
  const ms = performance.now() - t0;
  check(eq(ours, crypto.pbkdf2Sync(pw, salt, 600000, 32, "sha256")), "pbkdf2 600000");
  console.log(`pbkdf2 600000 iterations: ${Math.round(ms)} ms in Node`);
}

// X25519 against Node and RFC 7748 §5.2.
const b64u = (s) => new Uint8Array(Buffer.from(s, "base64url"));
for (let i = 0; i < 5; i++) {
  const a = crypto.generateKeyPairSync("x25519"), b = crypto.generateKeyPairSync("x25519");
  const aPriv = b64u(a.privateKey.export({ format: "jwk" }).d), aPub = b64u(a.publicKey.export({ format: "jwk" }).x);
  const bPub = b64u(b.publicKey.export({ format: "jwk" }).x);
  check(eq(RC.x25519(aPriv, RC.BASE), aPub), "x25519 public key");
  check(eq(RC.x25519(aPriv, bPub), crypto.diffieHellman({ privateKey: a.privateKey, publicKey: b.publicKey })), "x25519 shared secret");
}
check(RC.toHex(RC.x25519(RC.fromHex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                         RC.fromHex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")))
  === "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", "RFC 7748 vector");

// A published test vector too (RFC 4231, HMAC-SHA256 test case 2):
check(RC.toHex(RC.hmac(new TextEncoder().encode("Jefe"), new TextEncoder().encode("what do ya want for nothing?")))
  === "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "RFC 4231 case 2");

console.log(failures === 0 ? "PASS: crypto.js matches Node crypto" : `FAIL: ${failures} crypto checks failed`);
process.exit(failures ? 1 : 0);

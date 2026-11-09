"use strict";
// Relay's end-to-end encryption, phone side.
//
// Safari only offers its built-in crypto (crypto.subtle) on https pages, and Relay's page is
// served over plain http from the Mac, so the few primitives needed are implemented here:
// SHA-256, HMAC-SHA256, HKDF and PBKDF2 (RFC 2104, 5869, 8018), X25519 (RFC 7748) and
// ChaCha20-Poly1305 (RFC 8439).
// The Mac side uses Apple's CryptoKit; tools/cryptotest.mjs checks this file against Node's
// crypto module byte for byte.
//
// Protocol: see Sources/Relay/SecureChannel.swift, which this mirrors. In short, each
// connection does a fresh X25519 exchange, mixes in the pairing code (stretched with PBKDF2),
// proves knowledge of it with an HMAC, and then seals every message with ChaCha20-Poly1305.
// The code never crosses the network, a recording of the traffic gives no way to test guesses
// for it, and recorded sessions stay unreadable even if the code leaks later.
const RelayCrypto = (() => {
  const encoder = new TextEncoder();

  // ---- SHA-256 ----------------------------------------------------------------
  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);

  function sha256(data) {
    const bitLength = data.length * 8;
    const padded = new Uint8Array(((data.length + 9 + 63) >> 6) << 6);
    padded.set(data);
    padded[data.length] = 0x80;
    const view = new DataView(padded.buffer);
    view.setUint32(padded.length - 8, Math.floor(bitLength / 0x100000000));
    view.setUint32(padded.length - 4, bitLength >>> 0);
    const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
    const w = new Uint32Array(64);
    for (let off = 0; off < padded.length; off += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4);
      for (let i = 16; i < 64; i++) {
        const a = w[i - 15], b = w[i - 2];
        const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
        const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let [a, b, c, d, e, f, g, hh] = h;
      for (let i = 0; i < 64; i++) {
        const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
        const t1 = (hh + S1 + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0;
        const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
        const t2 = (S0 + ((a & b) ^ (a & c) ^ (b & c))) | 0;
        hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
      }
      h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    const out = new Uint8Array(32);
    const outView = new DataView(out.buffer);
    for (let i = 0; i < 8; i++) outView.setUint32(i * 4, h[i]);
    return out;
  }

  function concat(...parts) {
    const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
    let off = 0;
    for (const p of parts) { out.set(p, off); off += p.length; }
    return out;
  }

  function hmac(key, message) {
    if (key.length > 64) key = sha256(key);
    const block = new Uint8Array(64);
    block.set(key);
    const inner = block.map((b) => b ^ 0x36), outer = block.map((b) => b ^ 0x5c);
    return sha256(concat(outer, sha256(concat(inner, message))));
  }

  // ---- SHA-256 compression on words, for a fast PBKDF2 ------------------------------
  const W = new Uint32Array(64);   // reused: PBKDF2 calls this over a million times
  function compress(state, w16, out) {
    const w = W;
    for (let i = 0; i < 16; i++) w[i] = w16[i];
    for (let i = 16; i < 64; i++) {
      const a = w[i - 15], b = w[i - 2];
      const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
      const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let a = state[0], b = state[1], c = state[2], d = state[3];
    let e = state[4], f = state[5], g = state[6], h = state[7];
    for (let i = 0; i < 64; i++) {
      const S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7));
      const t1 = (h + S1 + ((e & f) ^ (~e & g)) + K[i] + w[i]) | 0;
      const S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10));
      const t2 = (S0 + ((a & b) ^ (a & c) ^ (b & c))) | 0;
      h = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    out[0] = state[0] + a; out[1] = state[1] + b; out[2] = state[2] + c; out[3] = state[3] + d;
    out[4] = state[4] + e; out[5] = state[5] + f; out[6] = state[6] + g; out[7] = state[7] + h;
  }
  const IV = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                              0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const beWords = (bytes) => { const v = new DataView(bytes.buffer, bytes.byteOffset); return Uint32Array.from({ length: bytes.length / 4 }, (_, i) => v.getUint32(i * 4)); };

  // PBKDF2-HMAC-SHA256 with a 32-byte output. Each iteration is two SHA-256 block
  // compressions on precomputed HMAC states (about 0.5 s for 600 000 on an iPhone).
  function pbkdf2(password, salt, iterations) {
    let key = password.length > 64 ? sha256(password) : password;
    const block = new Uint8Array(64); block.set(key);
    const inner = new Uint32Array(8), outer = new Uint32Array(8);
    compress(IV, beWords(block.map((b) => b ^ 0x36)), inner);
    compress(IV, beWords(block.map((b) => b ^ 0x5c)), outer);
    let u = beWords(hmac(password, concat(salt, new Uint8Array([0, 0, 0, 1]))));
    const t = u.slice();
    const msg = new Uint32Array(16); msg[8] = 0x80000000; msg[15] = (64 + 32) * 8;
    const mid = new Uint32Array(8);
    for (let i = 1; i < iterations; i++) {
      msg.set(u); compress(inner, msg, mid);
      msg.set(mid); compress(outer, msg, u);
      for (let j = 0; j < 8; j++) t[j] ^= u[j];
    }
    const out = new Uint8Array(32), v = new DataView(out.buffer);
    for (let j = 0; j < 8; j++) v.setUint32(j * 4, t[j]);
    return out;
  }

  // ---- X25519 (RFC 7748), with BigInt for clarity; runs once per connection ----------
  const P25519 = (1n << 255n) - 19n;
  const mod = (x) => { const r = x % P25519; return r < 0n ? r + P25519 : r; };
  function powMod(b, e) { let r = 1n; b = mod(b); while (e > 0n) { if (e & 1n) r = mod(r * b); b = mod(b * b); e >>= 1n; } return r; }
  const leToBig = (bytes) => bytes.reduceRight((n, byte) => (n << 8n) | BigInt(byte), 0n);
  function bigToLe(n) { const out = new Uint8Array(32); for (let i = 0; i < 32; i++) { out[i] = Number(n & 0xffn); n >>= 8n; } return out; }

  function x25519(scalar, uBytes) {
    const k = scalar.slice(); k[0] &= 248; k[31] &= 127; k[31] |= 64;
    const kn = leToBig(k);
    const u = uBytes.slice(); u[31] &= 127;
    const x1 = mod(leToBig(u));
    let x2 = 1n, z2 = 0n, x3 = x1, z3 = 1n, swap = 0n;
    for (let t = 254n; t >= 0n; t--) {
      const kt = (kn >> t) & 1n;
      swap ^= kt;
      if (swap) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
      swap = kt;
      const A = mod(x2 + z2), AA = mod(A * A), B = mod(x2 - z2), BB = mod(B * B), E = mod(AA - BB);
      const C = mod(x3 + z3), D = mod(x3 - z3), DA = mod(D * A), CB = mod(C * B);
      x3 = mod((DA + CB) ** 2n); z3 = mod(x1 * mod((DA - CB) ** 2n));
      x2 = mod(AA * BB); z2 = mod(E * (AA + 121665n * E));
    }
    if (swap) { [x2, x3] = [x3, x2]; [z2, z3] = [z3, z2]; }
    return bigToLe(mod(x2 * powMod(z2, P25519 - 2n)));
  }
  const BASE = new Uint8Array(32); BASE[0] = 9;

  function hkdf(ikm, salt, info, length) {
    const prk = hmac(salt, ikm);
    const out = new Uint8Array(length);
    let previous = new Uint8Array(0);
    for (let i = 1, off = 0; off < length; i++) {
      previous = hmac(prk, concat(previous, info, new Uint8Array([i])));
      out.set(previous.subarray(0, Math.min(32, length - off)), off);
      off += 32;
    }
    return out;
  }

  // ---- ChaCha20 ----------------------------------------------------------------
  function chachaBlock(keyWords, counter, nonceWords, out) {
    const s = new Uint32Array(16);
    s[0] = 0x61707865; s[1] = 0x3320646e; s[2] = 0x79622d32; s[3] = 0x6b206574;
    s.set(keyWords, 4);
    s[12] = counter;
    s.set(nonceWords, 13);
    const x = s.slice();
    const qr = (a, b, c, d) => {
      x[a] += x[b]; x[d] ^= x[a]; x[d] = (x[d] << 16) | (x[d] >>> 16);
      x[c] += x[d]; x[b] ^= x[c]; x[b] = (x[b] << 12) | (x[b] >>> 20);
      x[a] += x[b]; x[d] ^= x[a]; x[d] = (x[d] << 8) | (x[d] >>> 24);
      x[c] += x[d]; x[b] ^= x[c]; x[b] = (x[b] << 7) | (x[b] >>> 25);
    };
    for (let i = 0; i < 10; i++) {
      qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15);
      qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14);
    }
    for (let i = 0; i < 16; i++) out[i] = (x[i] + s[i]) >>> 0;
  }

  function words(bytes) {
    const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const w = new Uint32Array(bytes.length / 4);
    for (let i = 0; i < w.length; i++) w[i] = v.getUint32(i * 4, true);
    return w;
  }

  // XORs data with the ChaCha20 keystream starting at block `counter`.
  function chacha20(key, nonce, counter, data) {
    const keyWords = words(key), nonceWords = words(nonce);
    const out = new Uint8Array(data.length);
    const block = new Uint32Array(16);
    const blockBytes = new Uint8Array(block.buffer);   // little-endian on every Apple device
    for (let off = 0; off < data.length; off += 64, counter++) {
      chachaBlock(keyWords, counter, nonceWords, block);
      const n = Math.min(64, data.length - off);
      for (let i = 0; i < n; i++) out[off + i] = data[off + i] ^ blockBytes[i];
    }
    return out;
  }

  // ---- Poly1305 (BigInt keeps it short and exact) -------------------------------------
  const P = (1n << 130n) - 5n, MASK130 = (1n << 130n) - 1n, MASK128 = (1n << 128n) - 1n;
  const TOP = 1n << 128n;

  function le128(bytes, off) {
    const v = new DataView(bytes.buffer, bytes.byteOffset + off, 16);
    return v.getBigUint64(0, true) | (v.getBigUint64(8, true) << 64n);
  }

  function poly1305(oneTimeKey, ciphertext) {
    const r = le128(oneTimeKey, 0) & 0x0ffffffc0ffffffc0ffffffc0fffffffn;
    const s = le128(oneTimeKey, 16);
    // AEAD MAC input: ciphertext padded to 16 bytes, then le64(aad length = 0) ‖ le64(ct length).
    const padded = new Uint8Array(((ciphertext.length + 15) >> 4 << 4) + 16);
    padded.set(ciphertext);
    new DataView(padded.buffer).setBigUint64(padded.length - 8, BigInt(ciphertext.length), true);
    let acc = 0n;
    for (let off = 0; off < padded.length; off += 16) {
      acc = (acc + le128(padded, off) + TOP) * r;
      acc = (acc & MASK130) + (acc >> 130n) * 5n;
      acc = (acc & MASK130) + (acc >> 130n) * 5n;
    }
    if (acc >= P) acc -= P;
    acc = (acc + s) & MASK128;
    const tag = new Uint8Array(16);
    const v = new DataView(tag.buffer);
    v.setBigUint64(0, acc & 0xffffffffffffffffn, true);
    v.setBigUint64(8, acc >> 64n, true);
    return tag;
  }

  function nonceFor(counter) {
    const nonce = new Uint8Array(12);
    new DataView(nonce.buffer).setBigUint64(4, BigInt(counter));
    return nonce;
  }

  // ChaCha20-Poly1305 with empty additional data. Returns ciphertext ‖ 16-byte tag.
  function seal(key, counter, plaintext) {
    const nonce = nonceFor(counter);
    const polyKey = chacha20(key, nonce, 0, new Uint8Array(32));
    const ciphertext = chacha20(key, nonce, 1, plaintext);
    return concat(ciphertext, poly1305(polyKey, ciphertext));
  }

  // Returns the plaintext, or null if the message was tampered with or out of order.
  function open(key, counter, sealed) {
    if (sealed.length < 16) return null;
    const nonce = nonceFor(counter);
    const ciphertext = sealed.subarray(0, sealed.length - 16);
    const expected = poly1305(chacha20(key, nonce, 0, new Uint8Array(32)), ciphertext);
    let diff = 0;
    for (let i = 0; i < 16; i++) diff |= expected[i] ^ sealed[sealed.length - 16 + i];
    return diff === 0 ? chacha20(key, nonce, 1, ciphertext) : null;
  }

  const toHex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
  function fromHex(hex) {
    if (!/^([0-9a-f]{2})*$/i.test(hex)) return null;
    const out = new Uint8Array(hex.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
    return out;
  }

  // The pairing code stretched with PBKDF2 under this Mac's salt. Slow on purpose, so it's
  // computed once per Mac and code and cached by the page.
  function stretchCode(code, saltHex, iterations) {
    return pbkdf2(encoder.encode(code), fromHex(saltHex), iterations);
  }

  // Answers the Mac's challenge "n <nonce> <public key> <salt> <iterations>" (parsed by the
  // caller) given the stretched code. Returns the "a …" reply and the session keys.
  function handshake(stretched, macNonceHex, macPublicHex) {
    const macNonce = fromHex(macNonceHex), macPublic = fromHex(macPublicHex);
    if (!macNonce || macNonce.length !== 16 || !macPublic || macPublic.length !== 32) return null;
    const phoneNonce = crypto.getRandomValues(new Uint8Array(16));
    const phoneSecret = crypto.getRandomValues(new Uint8Array(32));
    const phonePublic = x25519(phoneSecret, BASE);
    const shared = x25519(phoneSecret, macPublic);
    if (shared.every((b) => b === 0)) return null;   // a low-order public key
    const keys = hkdf(concat(shared, stretched), concat(macNonce, phoneNonce, macPublic, phonePublic),
                      encoder.encode("relay v2"), 96);
    const proof = hmac(keys.subarray(0, 32), encoder.encode("relay-auth-v2"));
    return {
      reply: `a ${toHex(phoneNonce)} ${toHex(phonePublic)} ${toHex(proof)}`,
      sendKey: keys.slice(32, 64),
      receiveKey: keys.slice(64, 96),
    };
  }

  return { sha256, hmac, hkdf, pbkdf2, x25519, BASE, stretchCode, seal, open, handshake, concat, toHex, fromHex };
})();

if (typeof module !== "undefined") module.exports = RelayCrypto;   // for tools/cryptotest.mjs

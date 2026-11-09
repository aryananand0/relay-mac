# Working on Relay

Relay is a public, open-source app that lets a phone control a Mac: cursor, keyboard, clipboard and screen. Treat every change as something strangers will install. These rules apply to every development session, human or AI, and they don't need to be asked for each time.

## The project in one minute

- **Mac app:** `Sources/Relay/` (Swift, no dependencies). It serves `web/` over HTTPS on port 8443 and takes commands over a secure WebSocket on 8766. Plain HTTP on 8765 serves only the setup page and certificate profile (and `/pair` to the Mac itself, with a per-launch token). `TLSIdentity.swift` manages the name-constrained local CA and server certificate in the Keychain.
- **Phone page:** `web/` is plain HTML/CSS/JS. `web/crypto.js` is the phone's side of the encryption.
- **Security model:** see SECURITY.md and the README's "Privacy and security". In short:
  - local-network peers only
  - the pairing proof is an HKDF/HMAC challenge, and the code is never sent
  - everything after pairing is ChaCha20-Poly1305 (`SecureChannel.swift` ↔ `web/crypto.js`)
  - the WebSocket accepts only Relay's own page as Origin
  - strict CSP
  - the pairing page is served to loopback with a localhost Host header only
- **Battery:** nothing may poll or run timers while idle. Measure CPU when adding background work.

## Rule 1: Security review before committing

Before committing any significant change, without waiting to be asked:

1. Review the changed code for security problems: input handling, injection, path handling, unsafe HTML, auth and session logic, crypto use.
2. Check new permissions, entitlements, network listeners, data flows, and anything newly captured, stored, logged or sent.
3. Check for hardcoded secrets and personal information: keys, tokens, real pairing codes, home-folder paths, names, emails, hostnames, IP addresses.
4. Evaluate any new dependency. Relay has none today, so adding one needs a strong reason.
5. Run the tests (Rule 4) and add a check to `tools/securitytest.swift` when you change pairing, encryption, the web server or the control protocol.
6. Fix what you find before committing. If something can't be fixed, say so plainly.
7. Make sure no generated artifacts or private files are staged (`git status`, `./scripts/check-repo.sh --staged`).

Match the depth to the change. A typo fix needs a glance. Changes to pairing, encryption, networking, permissions, screen capture, the clipboard or logging need a careful review.

## Rule 2: Keep the README true

Before committing anything users would notice, check the README and update the relevant section for changes to:
- features or workflows
- installation, configuration or permissions
- security or privacy behaviour, or compatibility

When the interface changes noticeably, re-capture the screenshots with `tools/screenshots/capture.sh`. It uses a simulated Mac with made-up data, so real screens never appear. Don't add redundant sections.

## Rule 3: Privacy and secrets

Never commit:
- credentials, private keys or certificates
- `.env` files with values
- your pairing code, logs from `~/Library/Logs/Relay`
- screenshots of real screens, personal documents, account data
- machine-specific paths or names

Use made-up data in tests, examples and screenshots. The pre-commit hook (`git config core.hooksPath .githooks`) and CI catch the obvious cases; they don't replace judgement.

## Rule 4: Verify before committing

- Run `./scripts/check-repo.sh`, `node tools/cryptotest.mjs`, and, for Mac-side changes, `./scripts/install.sh && ./tools/test.sh`.
- Build with `swift build -c release --arch arm64` if you didn't install.
- Review the final diff. Make sure no unrelated files changed and the docs match the code.
- Never claim a test or scan passed without running it. If a check couldn't run, say which and why.

## Rule 5: Commit attribution

- No AI co-author or attribution lines in commits: no `Co-Authored-By: Claude …`, no Codex, ChatGPT, Copilot or other agent trailers, and no "Generated with …" lines. The same applies to pull request descriptions and source comments.
- Don't change the configured Git author identity, and don't add or remove human co-authors.
- Write a short imperative summary line, optionally followed by a body explaining why.
- `.claude/settings.json` turns off Claude Code's automatic attribution, and `.githooks/commit-msg` rejects AI trailers. Check the final message anyway.

## Rule 6: Routine checks vs. actions that need approval

Do security reviews, tests and README updates as a normal part of the work; don't ask whether to do them. Always get the maintainer's explicit approval first for:
- rotating or revoking credentials
- rewriting published history or force-pushing
- publishing releases or making the repository public
- exposing private files or changing external accounts
- deleting user data

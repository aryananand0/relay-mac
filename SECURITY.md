# Security policy

Relay lets a phone control a Mac. It can move the cursor, type, read and set the clipboard, and show the screen. A vulnerability can therefore be serious, so reports are very welcome.

## Reporting a vulnerability

Please report privately, not in a public issue.

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers can see it.

Please don't post details in public issues, discussions or pull requests until a fix is available. Public details give attackers a head start on everyone who hasn't updated.

A useful report includes:

- what an attacker can do, and from where (for example "anyone on the same Wi-Fi", "a website open on the Mac")
- steps to reproduce, or a proof of concept
- the Relay commit or version, the macOS version, and the iPhone/iOS version if relevant
- any idea you have for a fix

There is no bug bounty. Reports are handled on a best-effort basis.

## Supported versions

Relay has no versioned releases yet. Security fixes go to the `main` branch; please test against the latest `main`.

## What Relay is designed to protect against

The [Security section of the README](README.md#privacy-and-security) describes the design. In short:

- **Only local devices:** the Mac accepts connections only from private, link-local or same-subnet addresses. Relay never contacts the internet and has no accounts, cloud service or telemetry.
- **Pairing code:** a phone must prove it knows the pairing code before anything is accepted. Five wrong attempts lock that address out for a minute.
- **Encryption:** each connection does a fresh X25519 exchange, authenticated by the pairing code stretched with PBKDF2 (600 000 rounds). Then everything is encrypted with ChaCha20-Poly1305. The code never crosses the network; recorded traffic can't be used to guess it offline or to decrypt past sessions.
- **HTTPS:** the phone page and control connection use TLS with a certificate from a certificate authority Relay creates on the Mac. Its keys are non-exportable Keychain keys. Name Constraints limit it to `.local` names, `localhost` and private addresses, with email and URI names locked to the reserved `invalid` domain, and its Extended Key Usage allows web servers only. So it can't vouch for real websites, email or code.
- **Browser isolation:** only Relay's own page may open the control connection, and the pairing page is served only to the Mac itself, behind a per-launch token that only your user account can read.

Known limits, which are not vulnerabilities in themselves but are worth understanding:

- **Pairing code strength:** anyone who has the pairing code (or a photo of the QR code) can control the Mac. Use **New Pairing Code…** in the menu bar if it may have leaked.
- **Active attackers:** someone who can intercept and alter traffic could try guesses against one captured pairing attempt; each guess costs 600 000 PBKDF2 rounds against a 12-character (about 59-bit) code. Pairing attempts are also rate-limited per address and globally.
- **First-time setup:** the certificate has to get to the iPhone once. AirDrop (menu bar › Send Certificate to iPhone…) is authenticated. Downloading it over the network is trust-on-first-use, so the pairing page shows its SHA-256 fingerprint to compare in iPhone Settings.
- **Local trust store:** the certificate authority is trusted by the iPhone for local names. Remove its profile (Settings › General › VPN & Device Management) if you stop using Relay.

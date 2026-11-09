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
- **Encryption:** after pairing, everything between phone and Mac is encrypted and authenticated with ChaCha20-Poly1305, under keys derived from the pairing code. The code itself never crosses the network.
- **Browser isolation:** only Relay's own page may open the control connection, and the pairing page is served only to the Mac itself.

Known limits, which are not vulnerabilities in themselves but are worth understanding:

- **Pairing code strength:** anyone who has the pairing code (or a photo of the QR code) can control the Mac. Use **New Pairing Code…** in the menu bar if it may have leaked.
- **Offline guessing:** someone who records the Wi-Fi traffic of a pairing could try to guess the code offline. New codes are 12 characters (about 59 bits) to make that impractical. Codes created by versions before this change were 8 characters, so replace those with **New Pairing Code…**.
- **No server identity check:** the phone page itself is delivered over plain http from the Mac, so an attacker who controls the network could serve a modified page to a phone. Use Relay on networks you trust, and pause it elsewhere.

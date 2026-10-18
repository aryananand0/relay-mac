# Relay

Use your iPhone as a trackpad, keyboard and media remote for your Mac over your home Wi-Fi. Free, local, nothing hosted.

- **Mac:** `Relay.app` is a small Swift background helper. It serves the phone page on port 8765, receives input over a WebSocket on port 8766, and posts real input events through Core Graphics.
- **iPhone:** a plain HTML/JS web app, added to the Home Screen.

## Set up once

```bash
./scripts/install.sh   # builds Relay, installs it to ~/Applications, starts it now and at every login
./scripts/pair.sh      # shows a QR code to scan with your iPhone camera
```

1. **Accessibility:** enable Relay in System Settings › Privacy & Security › Accessibility. Without this, the cursor won't move, and the phone shows a warning.
2. **Firewall:** when the iPhone first connects, macOS asks whether Relay may accept incoming connections. Click **Allow**.
3. **iPhone:** scan the QR code, then tap Share › Add to Home Screen. The icon has the pairing code built in.

## Every day after that

Tap Relay on your Home Screen. That's it: Relay starts with your Mac, and the page reconnects within a fraction of a second whenever you open it. Safari doesn't need to stay open.

The dot-grid icon in the Mac's menu bar shows Relay's state: one lit dot means ready, all dots lit means a phone is connected, and dimmed means paused. Its menu has:
- **Show Pairing Code…** opens the QR page.
- **Pause Relay** turns phones away, for example on hotel or guest Wi-Fi. It stays paused until you turn it off.
- **Open Log**
- **Quit Relay** stops Relay until your next login.

- **Mac asleep:** Relay can't reach a sleeping Mac (a web page can't wake one). It works whenever the Mac is awake, including with the display asleep; the first touch wakes the display.
- **Other scripts:** `./scripts/stop.sh` stops Relay until the next login, and `./scripts/uninstall.sh` removes it. Re-run `install.sh` after changing the code.
- **Files:** the pairing code is in `~/Library/Application Support/Relay/pairing-code` (delete it and re-run `install.sh` for a new one). The log is at `~/Library/Logs/Relay/relay.log`.

## Resource use (measured on an M4 MacBook Pro)

| State | CPU | Memory | Timer wakeups |
|---|---|---|---|
| No phone connected | 0% | 13 MB | none |
| Phone open, not touching | 0% | 13 MB | none |
| Finger moving | about 2% of one core | 13 MB | 120/s, only while moving |

Relay holds no sleep assertions. Its input counts as user activity exactly like the real trackpad, so the Mac sleeps on its normal schedule. App Nap is turned off only while a phone is connected, so cursor timing stays exact.

## Gestures

| Gesture | Action |
|---|---|
| One finger | Move the cursor (with pointer acceleration) |
| Tap / tap twice | Click / double-click |
| Tap, then touch again and move | Drag (the button is released when you lift) |
| Two fingers | Scroll (natural direction); flick to glide |
| Two-finger tap | Right-click |
| Three or four fingers left / right | Switch desktop or full-screen app, like a MacBook |
| Three or four fingers up | Mission Control |
| Three or four fingers down | All windows of the current app (App Exposé) |
| Hold **Click** and move with your other thumb | Drag across more than one swipe |

Tap the sliders icon at the top right to change cursor speed, scroll speed and natural scrolling. Changes apply immediately and are saved on the phone. The same sheet can bring back the gesture tips. Finer tuning (acceleration curve, momentum, tap timings) is in constants at the top of `web/relay.js`.

The Mac paces cursor motion at 120 Hz instead of moving whenever a Wi-Fi packet happens to arrive. That keeps motion even when Wi-Fi delivers packets late or in bunches, at a cost of about 4 ms of latency.

## Remote

Switch to **Remote** in the bottom bar for big controls while watching. Relay remembers which mode you used last.

| Control | What it does on the Mac |
|---|---|
| Play/pause, previous, next | The keyboard's media keys, so they control whatever is playing (YouTube or Netflix in a browser, Music, Spotify) |
| Skip back / forward | ← / → (YouTube: 5 s, Netflix: 10 s); hold to repeat |
| Volume − / + / mute | The keyboard's volume keys; the meter shows the Mac's real volume and output device |
| Video full screen | `f`, which works in YouTube and Netflix players |
| Mission Control, Switch app, Spotlight | ⌃↑, ⌘Tab, ⌘Space |
| Previous page / Next page | ⌘[ / ⌘] |
| Turn display off | Displays sleep; the next touch on the phone wakes them |

If your TV controls its own volume over HDMI, which macOS often can't change, the meter says so and you use the TV remote for volume.

## Keyboard

Tap the keyboard button to open the iPhone keyboard. The trackpad stays usable above it.

- **Typing:** typed text goes straight to the Mac as Unicode, so accents, emoji and other languages work. Backspace (including hold-to-repeat), Return, paste, dictation and predictive-text suggestions are all forwarded.
- **Toolbar:** **esc**, **tab**, the arrow keys (hold to repeat), and the modifiers **⌃ ⌥ ⇧ ⌘**.
  - Tap a modifier to apply it to the next key only, for example ⌘ then `l` gives ⌘L.
  - Double-tap a modifier to lock it. Tap it again to unlock.
- **Layout note:** shortcuts use US key positions; plain typing doesn't depend on the layout.

## Security

- **Pairing code:** 8 characters, required before any input is accepted. Five wrong guesses lock that address out for 60 seconds.
- **Local devices only:** connections are accepted only from private, link-local or same-subnet addresses.
- **No Bonjour advertising:** Relay never advertises itself and never opens outbound connections.
- **Relay's own page only:** browsers may open the control connection only from Relay's own page, so other websites can't try pairing codes.
- **Unencrypted traffic:** the pairing code and anything you type travel unencrypted over your Wi-Fi. Anyone on the same network who has its password could capture them. Pause Relay on Wi-Fi you don't trust.

## Development

- `./tools/test.sh` runs the Mac-side checks against the running Relay: cursor movement, motion smoothness, scrolling, typing into a test window, and volume (restored afterwards). Add `--display` to also test turning the display off and waking it.
- `swift tools/make-icons.swift` redraws the logo: the iPhone icon, `web/logo.svg` and the Mac app icon.

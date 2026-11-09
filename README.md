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
- **Keeping Mac awake… / Sleep timer… — Turn Off** appears while either is on, so you can cancel it from the Mac.
- **Pause Relay** turns phones away, for example on hotel or guest Wi-Fi. It stays paused until you turn it off.
- **Open Log**
- **Restart Relay** is needed once, right after you allow Screen Recording (macOS applies that permission only when an app starts).
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
| Screen preview open, nothing happening | about 1% (Relay) + 0.7% (macOS capture) | | at most 1 frame/s, then 1 per 3 s |

Relay holds no sleep assertions unless you turn on Keep Mac awake or a sleep timer (see below). Its input counts as user activity exactly like the real trackpad, so the Mac sleeps on its normal schedule. App Nap is turned off only while a phone is connected, so cursor timing stays exact.

## Gestures

| Gesture | Action |
|---|---|
| One finger | Move the cursor (with pointer acceleration) |
| Tap / tap twice | Click / double-click |
| Tap, then touch again and move | Drag (the button is released when you lift) |
| Two fingers | Scroll (natural direction); flick to glide |
| Two-finger tap | Right-click |
| Pinch out / in | Zoom in / out (⌘+ / ⌘−, in browsers and most apps) |
| Three or four fingers left / right | Switch desktop or full-screen app, like a MacBook |
| Three or four fingers up | Mission Control |
| Three or four fingers down | All windows of the current app (App Exposé) |
| Hold **Click** and move with your other thumb | Drag across more than one swipe |

The crosshair button at the top is **Find my cursor**: it moves the cursor to the middle of its screen and shakes it, so macOS briefly shows it large. This needs "Shake mouse pointer to locate", which is on by default (System Settings › Accessibility › Display › Pointer).

Tap the sliders icon at the top right to change cursor speed, scroll speed, natural scrolling and the layout. Changes apply immediately and are saved on the phone. The same sheet can bring back the gesture tips. Finer tuning (acceleration curve, momentum, tap timings) is in constants at the top of `web/relay.js`.

The Mac paces cursor motion at 120 Hz instead of moving whenever a Wi-Fi packet happens to arrive. That keeps motion even when Wi-Fi delivers packets late or in bunches, at a cost of about 4 ms of latency.

## Screen preview

Tap the screen button at the top to see the Mac's screen above the trackpad. Tap the preview to put the cursor there.

With a TV or second display attached, the chips on the preview choose what you see:
- **Auto** (the default) shows the screen your cursor is on, at full width, and switches by itself when the cursor moves to another screen. The followed screen's number is outlined.
- **1, 2 …** pin one screen. Swipe sideways on the preview to flip to the next one.
- **All** stacks every screen on top of each other, so each one is as wide as the phone allows. Side by side they'd be too small to read.

Relay remembers your choice on the phone.

The first time, Relay asks for Screen Recording permission: turn on Relay in System Settings › Privacy & Security › Screen & System Audio Recording, then choose **Restart Relay** from the menu bar icon. While the preview runs, macOS shows its purple recording indicator in the menu bar, so you can always tell.

Built to cost as little power as possible:
- **Off unless you open it.** Nothing is captured until you tap the button. Capture stops the moment you close the preview, switch to Remote or Mac, lock the phone, switch apps, or lose Wi-Fi. If the phone vanishes without saying goodbye, the Mac notices within about 7 seconds and stops. It's always off when you open Relay.
- **One screen at a time.** Auto and pinned screens capture only the screen you're looking at, so a second display costs nothing extra.
- **Only changes are sent.** A still screen sends nothing.
- **Slows down when you don't need it.** Up to 6 frames per second for 1.5 s after you click, scroll or type, so you see the result. At most 1 per second while you're using Relay. After 30 seconds untouched, 1 every 3 seconds. After 3 minutes untouched the preview pauses itself; tap **Resume** to continue.
- **The cursor travels separately.** Moving the cursor sends only its position (a few bytes, up to 20 times a second) and the phone draws it, instead of re-sending the whole screen.
- **Small frames, cheap work.** macOS shrinks each frame on the GPU to exactly the size it's shown on the phone (at most 2 pixels per point). The hardware JPEG encoder takes about 1 ms per frame on a background (efficiency-core) queue. A new frame is sent only after the phone has shown the last one, so nothing ever queues up.

Measured on the M4 MacBook Pro with the built-in screen and a 2560×1080 display, over 15 s (share of one CPU core):

| | Relay | macOS capture service |
|---|---|---|
| Preview closed | 0% | 0% |
| Auto, nothing happening | 0.8% | 0.7% |
| All (two screens), nothing happening | 0.9% | 0.5% |
| Auto while moving the cursor | about the same as moving the cursor without the preview | 0.2% |

## Layouts

- **Landscape:** turn the phone sideways for a wide trackpad. The Trackpad / Remote / Mac switcher moves to a column on the right.
- **One-handed:** in Settings › Layout, pick Left hand or Right hand. Everything moves to the bottom of the screen, and the Click button and keyboard button sit on your thumb's side. Landscape always uses the two-handed layout.

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

## Mac tab

| Control | What it does |
|---|---|
| Keep Mac awake: 1 hour, 2 hours, Always | Stops the Mac and its display from going to sleep, so a film on the TV isn't interrupted. Off lets it sleep normally again. |
| Sleep timer: 15 min to 90 min | Keeps the Mac on until then, then pauses whatever is playing (if sound is playing) and puts the Mac to sleep. It also turns Keep Mac awake off. |
| Clipboard | Paste a link or text into the box (touch and hold › Paste), then **Send to Mac** puts it on the Mac's clipboard, or **Send & paste** also presses ⌘V. **Get from Mac** fetches the Mac's clipboard text into the box, and **Copy to iPhone** copies it to the phone. |
| Find cursor, Lock Mac, Display off | Find cursor is the same as the top-bar button. Lock Mac presses ⌃⌘Q. Display off turns the screens off; the next touch wakes them. |

While Keep Mac awake or a sleep timer is on, a small chip at the top of every screen shows it ("Awake" or the minutes left). Tap the chip to open the Mac tab.

- **Mac already asleep:** if the Mac sleeps anyway (for example the lid is closed with no TV attached), a timer that ended while it was asleep is dropped, so waking the Mac never puts it straight back to sleep.
- **Why a box for the clipboard:** Safari only lets pages read or write the iPhone clipboard over https, and Relay's page is plain http. Pasting into a box works everywhere.

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
- **Screen preview:** a paired phone can see your screens while the preview is open. macOS's purple indicator shows whenever that's happening, and Pause Relay or closing the preview stops it.
- **Clipboard:** a paired phone can read the Mac's clipboard text, but only when you tap **Get from Mac**. If you copy passwords on the Mac, keep in mind anyone with your pairing code could fetch one.
- **Unencrypted traffic:** the pairing code and anything you type travel unencrypted over your Wi-Fi. Anyone on the same network who has its password could capture them. Pause Relay on Wi-Fi you don't trust.

## Development

- `./tools/test.sh` runs the Mac-side checks against the running Relay: cursor movement, motion smoothness, scrolling, typing into a test window, volume (restored afterwards), keep awake and the sleep timer (dry run, so the Mac doesn't sleep), the clipboard (restored afterwards), find my cursor, and the screen preview (at rest, and with two screens that Auto follows the cursor). Add `--display` to also test turning the display off and waking it.
- `swift tools/make-icons.swift` redraws the logo: the iPhone icon, `web/logo.svg` and the Mac app icon.

# Tidal Labs — Garmin (Connect IQ)

A surf-session tracker for Garmin watches, written in Monkey C. Start a session when you
paddle out, tap DOWN for every wave you catch, hold START when you come in. On two-button
touchscreen watches, which have no DOWN key, START does both.

Each wave is recorded as a **lap** in the FIT file, so the wave count, the lap timestamps,
the GPS track and heart rate all reach Garmin Connect through the normal activity sync with
no extra plumbing. The wave times are additionally kept in `Application.Storage` so they can
be pushed straight to the Tidal Labs iPhone app over Bluetooth — see [Phone sync](#phone-sync).

This is a standalone Connect IQ app. It shares nothing with the Swift/Xcode project or the
Apple Watch target beyond the visual language.

## Buttons

Physical buttons only. The app never responds to the touchscreen.

There are two key maps. `SurfDelegate` picks between them at construction from
`System.getDeviceSettings().inputButtons & System.BUTTON_INPUT_DOWN`, so nothing is wired
per product in the jungle and the five-button path is untouched by the two-button one.

### Five-button watches (fenix, Instinct, Forerunner, …)

| Button | Idle | Recording |
|---|---|---|
| **START** (`KEY_ENTER`) press | begin session | (nothing) |
| **START** hold 1000 ms | — | stop + save session |
| **DOWN** (`KEY_DOWN`) press | (nothing) | log a wave → `Session.addLap()` |
| **UP** (`KEY_UP`) press | push pending sessions to the iPhone | (nothing) |
| **BACK** (`KEY_ESC`) | exits app | swallowed |

Instinct engraves the upper-right key **GPS**, not START — see [Naming the keys on
screen](#naming-the-keys-on-screen).

### Two-button touchscreens (Venu, vívoactive, Venu X1, Venu 3)

There is no UP or DOWN key, so ENTER and BACK carry everything. Touch is *not* the fallback
— the delegate exists precisely because a wet screen taps itself.

| Button | Idle | Recording |
|---|---|---|
| **START** (`KEY_ENTER`) press | begin session | log a wave → `Session.addLap()` |
| **START** hold 1500 ms | — | stop + save session |
| **BACK** (`KEY_ESC`) press | sync, *only* while the Sync capsule is on screen; otherwise exits app | swallowed |

Two deliberate differences from the five-button map:

- **The hold is 1500 ms, not 1000.** The same key logs waves here, so a fumbled press held a
  beat too long would otherwise end the session mid-surf. The extra 500 ms is the margin.
- **BACK only syncs when there is something to sync.** The idle screen draws the Sync Waves
  capsule exactly when `getPendingCount() > 0`, and that is exactly when BACK is consumed. In
  every other state BACK keeps its normal meaning and leaves the app, so the button never
  does something the screen is not offering, and the app is never inescapable.

**Venu 3 lands here even though it reports three keys.** It reports `enter, esc, menu`, and
the map is chosen off `BUTTON_INPUT_DOWN`, which Venu 3 does not have — so it takes the
two-button path and MENU is currently unused. MENU is *not* a third key: the SDK device
definition (`Devices/venu3/simulator.json`) puts `menu` at the same coordinates as `esc`
with `isHold: true`, i.e. it is a long-press of the Back button. The watch's real third
physical button is the middle Custom/Voice Assistant key, which Connect IQ never delivers.
So moving sync to MENU would mean "hold BACK", not "press the middle button", and it stays
on a plain BACK press because that is the gesture the capsule can name in the space it has.

### Naming the keys on screen

Every screen names the key it answers to — `Start (START)`, `Sync 3 (UP)`, and, while
recording, `DOWN wave` / `hold START end`. The word in the parentheses is the one Garmin's
own owner's manual prints for that key, which is not the same across the three families:

| Family | Products | `KEY_ENTER` | sync key | wave key |
|---|---|---|---|---|
| fenix 8 / 8 Solar / 8 Pro / E, enduro 3, D2 Mach 2 Pro, Forerunner 70 / 170 / 570 / 970 | 15 | **START** | UP | DOWN |
| Instinct 3 AMOLED / 3 Solar / E, Instinct Crossover AMOLED | 5 | **GPS** | UP | DOWN |
| Venu 3 / 4, Venu X1, vívoactive 6 | 5 | **ACTION** | BACK | — (ENTER logs) |

Instinct engraves its keys (CTRL, UP, ABC, GPS, SET) and the manual calls the upper-right
one GPS; the fenix and Forerunner manuals call the same position START; the touchscreens
have no engraving at all and their manuals say "action button" and "back button".

Two string ids carry the difference — `KeyEnter` and `KeySync`, defaulting to START and UP
in `resources/strings/strings.xml`, overridden per family by `resources-keys-instinct` and
`resources-keys-venu` in `monkey.jungle`. A later `resourcePath` entry wins over an earlier
one, so only the strings that actually differ are duplicated. DOWN is the same word on every
five-button product in the list, so it is inline in `SurfView`.

The recording hint is one line where it fits and two where it does not — measured, not
guessed; every screen 260px and under wraps it. The 176px Instincts lose the top third to
the always-on sub-display and have no room for the hint under a full-height wave block, so
there the count and its caption share a row (`3 WAVES`, drawn by the `COUNT` row style,
bottom-aligned) and the two freed lines carry the hint. The inline row is measured against
the same width budget as the clock, because three digits plus " WAVES" is the wider string.

Hold-to-stop is deliberate: a stray press mid-session must not kill the recording. A
long-press of BACK still exits at the system level and cannot be blocked, so
`AppBase.onStop()` calls `SessionController.end()` — an app kill saves the session rather
than losing it.

The view is an `InputDelegate`, **not** a `BehaviorDelegate`. `BehaviorDelegate.onSelect()`
fires on a screen tap as well as an ENTER press, and a wet screen taps itself. For the same
reason the app calls `WatchUi.configureTouchEvents({:enabled => false})` while recording,
which is the closest thing Connect IQ has to Water Lock. It suppresses touch *delivery to
the app*; it does not lock the physical buttons, and there is no API that does.

## Supported devices

Twenty-five products. Twenty 5-button watches sharing one key map:

```
d2mach2pro     enduro3         fenix843mm      fenix847mm      fenix8pro47mm
fenix8solar47mm fenix8solar51mm fenixe         fr170           fr170m
fr57042mm      fr57047mm       fr70            fr970           instinct3amoled45mm
instinct3amoled50mm instinct3solar45mm instinctcrossoveramoled instincte40mm instincte45mm
```

…and five touchscreens on the second key map:

```
venu3          venu441mm       venu445mm       venux1          vivoactive6
```

`venu3` sits at exactly `API level 5.2` — the floor, and the only product in the list below
6.0. Lower `minApiLevel` and you change which API calls are legal for all twenty-five, so it
stays where it is. Venu 3 is also the only 3-key product here (`enter, esc, menu`); the rest
of that tier (Venu 2 Plus, Approach S62) predates 5.2.0.

### What is excluded and why

- **All Edge devices** — cycling computers, not wearable, and `configureTouchEvents` is not
  supported on any of them.

Garmin has no rotary/crown/bezel input of any kind, so the Apple Watch app's Digital Crown
gesture for logging a wave has no equivalent here; DOWN is the substitute. The upper-left
LIGHT button is never delivered to Connect IQ apps and cannot be used.

## Build

```bash
cd garmin
SDK=$(cat ~/Library/Application\ Support/Garmin/ConnectIQ/current-sdk.cfg)

# one device
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/TidalLabs-fenix847mm.prg \
    -y developer_key.der -d fenix847mm -w

# sideload into the simulator (launch it first with "$SDK/bin/connectiq")
"$SDK/bin/monkeydo" bin/TidalLabs-fenix847mm.prg fenix847mm
```

`monkeydo` stays attached to the simulator until you kill it — run it in the background if
you are scripting.

Every product in `manifest.xml` builds with **zero warnings** under `-w`. Sweep them all:

```bash
for d in $(grep -o 'iq:product id="[^"]*"' manifest.xml | sed 's/.*id="//;s/"//'); do
    "$SDK/bin/monkeyc" -f monkey.jungle -o "bin/sweep-$d.prg" -y developer_key.der -d "$d" -w
done
```

### Developer key

The signing key is gitignored and has to be generated once before the first build:

```bash
openssl genrsa -out developer_key.pem 4096
openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem \
    -out developer_key.der -nocrypt
```

### Tests

```bash
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/test.prg -y developer_key.der -d fenix847mm -w -t
"$SDK/bin/monkeydo" bin/test.prg fenix847mm -t
```

`SessionControllerTest.mc` covers the state machine: idle → recording → laps → idle, that a
DOWN press while idle is a no-op, that a second `start()` does not clear the wave count,
that `end()` is safe to call when idle (because `onStop()` calls it unconditionally), and
that empty sessions are not queued for sync.

> **Gotcha:** run the test against a *freshly started* simulator. If the simulator still has
> an activity open from a sideloaded app, or a FIT file loaded under
> `Simulation > Activity Data`, `session.start()` silently fails to enter the recording state
> and the test errors with `ASSERTION FAILED: start() should be recording`. That is
> simulator state, not a code failure — restart the simulator and re-run.

## Sideloading to a real watch

```bash
./sideload.sh
```

Plug the watch in first. The script builds for whatever is connected and copies the PRG
across; it never ejects for you, it prints the `diskutil eject` command instead.

**The product id must match the connected watch exactly.** A PRG built for the wrong product
is ignored silently by the device: no error, no icon, nothing to debug. So `sideload.sh`
reads the watch's own part number out of `/GARMIN/GarminDevice.xml` and looks the product up
in the SDK device database (`~/Library/Application Support/Garmin/ConnectIQ/Devices/*/compiler.json`,
`partNumbers[].number`) rather than trusting you to pick the right one of twenty-five.
Part numbers look like `006-B4536-00` (that one is `fenix847mm`).

Doing it by hand is four steps:

1. Build signed, for your exact product. **No `-t` flag** — that builds the test harness,
   not the app.
   ```bash
   "$SDK/bin/monkeyc" -f monkey.jungle -o bin/TIDALLBS.PRG -y developer_key.der -d <product> -w
   ```
2. Copy to `<volume>/GARMIN/APPS/`.
3. Create `<volume>/GARMIN/APPS/LOGS/TIDALLBS.TXT`. Log files are **not** auto-created and
   the name must match the PRG, or `System.println()` output goes nowhere.
4. `diskutil eject` before unplugging, not a bare cable yank.

The watch rescans on disconnect and the app appears in Activities & Apps as "Tidal Labs".

Gotchas:

- **Venu 3 cannot be sideloaded over USB from a Mac at all.** Use the store package below.
  The script detects the case and says so rather than failing as if nothing were plugged in.
  See [Venu 3 and USB](#venu-3-and-usb) for what was measured.
- Watches cap how many Connect IQ apps can be installed. A sideloaded app takes a slot.
- No breakpoints on hardware — the debugger is simulator-only. On device you get the
  `LOGS/*.TXT` println file and, on a crash, `LOGS/CIQ_LOG.YAML` with a real stack trace
  (file, line, function). Logs archive to `.BAK` past 5 KB, so pull them before they roll.

### Venu 3 and USB

Venu 3 never appears under `/Volumes`, and it presents no MTP interface for a client to talk
to. Measured, not assumed:

| Check | Result |
|---|---|
| USB descriptors | `091e:0003`, class 255/255/255, 1 config, 1 interface, 3 endpoints |
| String descriptors | `iManufacturer=0`, `iProduct=0`, `iSerialNumber=0` — none at all |
| macOS interface nubs | none created (an iPhone on the same bus shows `PTP@0`, `NCM Data@3`, …) |
| `mtp-detect` (libmtp 1.1.23) | `No raw devices found` |
| PTP `GetDeviceInfo` (0x1001) after `libusb_reset_device` | timeout |
| Garmin proprietary Start-Session | works, returns unit ID — the firmware is alive on that protocol |
| Mass-storage switch command (pid `0x042f`, works on vívosmart) | accepted, no re-enumeration |
| Watch unlocked, replugged (new `sessionID`) | identical enumeration |
| `Settings > System > USB Mode` | does not exist on Venu 3 |

So the watch speaks only Garmin's vendor protocol, and macOS has no driver for it. Installing
an MTP client is wasted effort on this model.

**The route that works is the store package**, which reaches the watch over Bluetooth:

```bash
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/TidalLabs.iq -y developer_key.der -e -r -w
```

`-e` packages every product in the manifest, `-r` strips debug info. Upload the `.iq` at
<https://apps.garmin.com/developer/dashboard> as a private app, then install it from Garmin
Connect Mobile. A private app is not listed in the store and needs no review.

## Layout constraints

The whole UI is one view (`SurfView.mc`) that measures the screen and steps font sizes down
to fit. Screens in the product list run from 166 px to 486 px, and `venux1` is the only
non-round one (448x486 rectangle; the round-bezel width budget just runs conservative
there). Three device quirks drive most of the code:

### Instinct sub-display

The semioctagon Instincts (Instinct E 40/45 mm, Instinct 3 Solar 45 mm) have an always-on
circular sub-display physically covering the top right of the screen. Anything the app draws
under it is hidden on hardware.

`WatchUi.getSubscreen()` reports the exact reserved rectangle and returns `null` on every
device without one, so the layout needs no device list: the clock centres in the strip beside
the sub-display and the main content stack starts below it. On `instincte45mm` the reserved
rect is `x=113 y=0 w=62 h=62` of a 176×176 screen — a third of the height is gone, which is
why those screens drop the "Tidal Labs" title row.

### 1 bit-per-pixel screens

Those same three Instincts are the only 1 bpp MIP displays in the product list. There is no
runtime colour-depth API (`Dc` has no `getColorDepth()`), so `SurfView.isSmall()` proxies it
off screen height — every 1 bpp product is under 200 px and everything else is 260 px or
wider.

On 1 bpp, `COLOR_LT_GRAY` and the `0x00FFFF` cyan quantise to **white**, but `COLOR_GREEN`
quantises to **black** and vanishes against the black background. `SurfView.accent()` forces
accents to white there. Every colour used in the view is high-luminance for this reason; red
and dark blue are deliberately avoided.

### Launcher icons

The launcher icon SVG must declare `width`/`height` equal to that device's exact launcher
icon size or the resource compiler warns and rescales it. Eight sizes cover the twenty-five
products and they do **not** line up with device families, so `monkey.jungle` wires them per
device. The art in each `resources-icon*/` folder is identical — only the declared dimensions
differ.

| Folder | Size | Devices |
|---|---|---|
| `resources-icon38` | 38 px | instinctcrossoveramoled |
| `resources-icon40` | 40 px | fenix8solar47mm, fenix8solar51mm, enduro3 |
| `resources-icon52` | 52 px | instincte40mm |
| `resources-icon54` | 54 px | fr170, fr170m, fr57042mm, fr70, venu441mm, vivoactive6 |
| `resources-icon60` | 60 px | fenix843mm, fenixe, instinct3amoled45mm, instinct3amoled50mm |
| `resources-icon62` | 62 px | instinct3solar45mm, instincte45mm |
| `resources-icon65` | 65 px | fenix847mm, fenix8pro47mm, fr57047mm, fr970, d2mach2pro, venu445mm, venux1 |
| `resources-icon70` | 70 px | venu3 |

## Phone sync

Sync Waves pushes every session in `pendingSessions` to the Tidal Labs iOS app, which links the
**Connect IQ Mobile SDK for iOS** (`github.com/garmin/connectiq-companion-app-sdk-ios`, added as a
Swift package). The phone side lives in `TidalLabs/GarminManager.swift`; the watch side needs no
per-phone configuration.

Nothing is lost on a failed push. Sessions stay in `Application.Storage` until the
`ConnectionListener` reports `onComplete()`, so pressing the button again drains the whole backlog.

### Pairing, once

The SDK talks to the watch **directly over Bluetooth**. Garmin Connect Mobile is only the broker
that hands the phone the list of watches the user agreed to share, so pairing is a one-time round
trip:

1. Tidal Labs iOS → Settings → **Garmin watch** → *Connect watch*.
2. iOS launches Garmin Connect Mobile; pick the watch there.
3. GCM launches Tidal Labs back through the `tidallabs-ciq://` URL scheme carrying the device list.

The card then shows the watch and whether it is in range. This is unrelated to Apple Watch pairing
and does not disturb it.

### What "Phone not connected" means now

`SessionController.onSyncError()` still draws it, and it is still the honest answer — it now means
one of:

- The watch was never shared with Tidal Labs from Garmin Connect Mobile (do the pairing above).
- The iOS app is not running. The SDK reaches the watch from the app's own process, so there is
  nothing listening when the app is dead. There is no background mode to cover this: the
  `bluetooth-central` declaration was removed after App Review rejected it under guideline 2.5.4
  (the BLE work lives inside the Connect IQ SDK, so there is no first-party Core Bluetooth code to
  show). **Sync with Tidal Labs open on the phone.**
- Bluetooth off, or the watch out of range.

### App id

The iOS side registers for messages from **every** id the manifest has been published under
(`837E33EF…`, the public listing the manifest builds under now, plus `C80BB06A…` on the personal
account and `B608F363…` on the test-watch account), because a mismatch between the installed
build's id and the registered id fails silently and can only be debugged on hardware. Old ids stay
registered so installs made from the earlier listings keep syncing. If the manifest ever takes a
fourth id, add it to `GarminManager.appUUIDs` too.

### What the phone does with a session

The watch sends `{"sessions": [{"start", "end", "waves": [...]}]}`, epoch seconds throughout, one
wave time per lap. `GarminManager` converts each wave into the same clip window the Apple Watch
uses — `waveDurationSeconds` back from the button press — and hands it to the same
`CameraManager.handleIncomingWatchSessions` inbox, so a Garmin session and an Apple Watch session
are indistinguishable downstream.

One difference: `gpsTrack` is empty for Garmin sessions. The GPS track rides the FIT file to Garmin
Connect, not to the phone, so **auto-follow crop falls back to full frame** on these clips.

The FIT file remains the delivery path for laps, GPS and HR to Garmin Connect, with no phone-app
integration involved at all.

## Files

```
manifest.xml                 25 products, type="watch-app", minApiLevel 5.2.0,
                             permissions Fit / Positioning / Communications
monkey.jungle                base resourcePath + per-device launcher-icon overrides
resources/strings/           app name
resources-icon{38,40,52,54,60,62,65,70}/drawables/
source/TidalLabsApp.mc       AppBase; onStop() saves so an app kill does not lose a session
source/SessionController.mc  state machine, ActivityRecording, sync, SyncListener
source/SurfDelegate.mc       InputDelegate, key handling only
source/SurfView.mc           the single View, all drawing
source/SessionControllerTest.mc  (:test) sessionStateMachine
sideload.sh                  build for the connected watch and copy the PRG onto it
                             (mass-storage watches only; see "Venu 3 and USB")
developer_key.der/.pem       generated, gitignored
```

The phone half lives in the Xcode project, not here:

```
TidalLabs/GarminManager.swift  Connect IQ Mobile SDK bridge: pairing, device events, message
                               receipt, and the conversion into CameraManager's session inbox
Config/PhoneInfo.plist         tidallabs-ciq URL scheme, gcm-ciq query scheme, Bluetooth usage
                               strings
```

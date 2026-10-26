# Device session brief

Paste this into a Claude Code session running **on the laptop the phone is
plugged into** — `claude remote-control` in a terminal in this repo, or the
Claude desktop app. It is written to stand on its own.

---

## What you're picking up

I own an **Oraimo Watch 6R (OSW-823)** and I'm reverse-engineering its BLE
protocol to build an unofficial companion app. This repository is a working
Flutter "BLE laboratory": it scans, connects, browses GATT, reads/writes raw
hex, logs every packet, records capture sessions and exports them as JSON. It
also imports Android HCI snoop logs.

Branch: `mwai/blissful-archimedes-f1pt0j`.

**Nothing about the watch's protocol is known yet.** There is deliberately no
decoder. Before touching anything, read:

- `docs/INVESTIGATIONS.md` — the three questions this session serves, with
  hypotheses and what would refute them
- `docs/PROTOCOL_STATUS.md` — the evidence ledger
- `docs/ARCHITECTURE.md` — why the code is shaped the way it is

## Why you are running on my laptop

The other session runs in a cloud container and cannot reach the phone. You
can. That is the whole reason you exist.

## The setup you're working with

- The phone on USB is an **Infinix**, not a Samsung.
- It says *"Notification access — this feature is not available on this
  device"*. Probably an Android Go / low-RAM build. Confirm:
  `adb shell getprop ro.config.low_ram`. This blocks **notifications only** —
  not BLE, not our app, not pulling the APK.
- The watch is **bound to my iPhone**. I want to keep it that way.
- There is **no Mac**.
- I've approved our app connecting to the watch **read-only**.

## Setup

```bash
adb devices                     # the Infinix must be listed; authorise on the phone
git checkout mwai/blissful-archimedes-f1pt0j && git pull
flutter pub get
flutter analyze --fatal-infos   # must be clean
flutter test                    # must all pass
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

If `adb install` fails on ABI, check `adb shell getprop ro.product.cpu.abi` —
budget phones are sometimes `armeabi-v7a`; install that APK instead.

Developed with **Flutter 3.47.4 / Dart 3.13.3**. Two pins that look like
housekeeping and are not — leave them:

- `permission_handler` at **12.x**: 13 needs compile SDK 37, which the SDK
  manager only publishes as `android-37.0`, and Gradle cannot resolve it.
- `flutter_blue_plus` 2.x is **not BSD**; the nonprofit licence tier is
  declared in `lib/core/bluetooth/flutter_blue_plus_transport.dart`.

## Job 1 — read-only GATT reconnaissance

The first time this app touches the real watch. The goal is the watch's
complete attribute database, exported as evidence.

1. On the **iPhone**: Settings → Bluetooth → **off**. Use Settings, not
   Control Center — the Control Center toggle only disconnects and can quietly
   reconnect. A connected watch usually stops advertising, so this is what
   makes it visible.
2. In our app: **Sessions → Record**, name it `gatt-recon`.
3. **Devices → Scan**. Find the watch; record its name, address, RSSI and the
   raw advertisement data exactly as shown. If it doesn't appear, wait a
   minute; if it still doesn't, restart the watch.
4. Star it → **Connect and explore** → **Connect**. Note the states it passes
   through and the MTU.
5. **If Android shows a pairing / bonding request: decline it.** Accepting
   would create a bond with the Infinix, which is exactly what read-only
   means not doing, and could disturb the iPhone binding. If declining makes
   some characteristics fail with an authentication error, record that — it
   is evidence.
6. **Discover**, then **Read all**, then **Subscribe all**. Each shows a
   report; transcribe any failures verbatim.
7. Crown side-check (see `docs/INVESTIGATIONS.md` §3): with everything
   subscribed, rotate the crown slowly for 10 seconds, then press it once.
   Note any packets that arrive. Nothing arriving proves nothing.
8. Wait a minute with the monitor open, to see whether the watch pushes
   anything unprompted.
9. **Sessions → Stop**, then export `gatt-recon` as JSON. The discovery
   packet's `detail` holds the full GATT tree.
10. **Disconnect**, then turn the iPhone's Bluetooth back on and confirm the
    watch reconnects to Oraimo Health on the iPhone. **Tell me either way.**

Report: the full service/characteristic tree with SIG names where the app
shows them, every value read (the app shows hex and ASCII — firmware revision
strings should be readable), every failure verbatim, and anything that
arrived unprompted.

## Job 2 — pull the Oraimo Health APK

Install Oraimo Health on the Infinix from the Play Store. **Do not sign in or
pair the watch** — we only need the app's code.

```bash
adb shell pm list packages | grep -i oraimo
adb shell pm path <package.name>
mkdir -p research/apk
adb pull <path/to/base.apk> research/apk/oraimo-base.apk
```

`research/apk/` is gitignored on purpose — it's someone else's copyrighted
binary. **Do not commit it.** Analyse it locally with `docs/APK_ANALYSIS.md`,
focused on the three questions:

- **Watch faces:** image conversion, chunking, compression, headers,
  checksums, and the characteristic the face is written to.
- **Emoji:** the notification-forwarding path and how it encodes text —
  charset conversions, emoji-stripping regexes, length limits.
- **Crown:** any setting or command named like crown, knob, rotate, encoder.
  Speculative.

Cross-reference every UUID you find against Job 1's GATT tree. **In the APK
and on the watch is evidence. In the APK only is a hypothesis.**

## Job 3 — things I do on the watch myself

You don't need to run these, but the results should be written up alongside
yours. Ask me for them:

- the **emoji glyph test** results (`docs/INVESTIGATIONS.md` §2), with photos
- the **crown checklist** (§3): firmware version, update available, which
  screens (if any) respond to rotation, what the manual says

## Rules that don't bend

1. **Never invent protocol details.** Nothing becomes a fact without a capture
   or a live read showing it.
2. **No decoder, no packet builder.** Not yet.
3. **No writes to the watch.** Read-only means no characteristic writes at all
   in this session — subscribing (a descriptor write the stack does for you)
   is the one exception, and I've agreed to it.
4. **Observations and hypotheses stay apart**, each citing its evidence. Add
   them to `docs/PROTOCOL_STATUS.md`.
5. **Report failures verbatim.** A clear "this didn't work, here is the exact
   error, here is what I tried" is worth more than a confident guess.

## What to commit

On this branch:

- **Commit:** the exported `gatt-recon` JSON under `research/captures/`
  (gitignored per file, so `git add -f`) — **skim it first**, a snoop of a
  phone can contain other devices' names; findings in
  `docs/PROTOCOL_STATUS.md` and `docs/INVESTIGATIONS.md`.
- **Never commit:** the APK, decompiler output, raw `btsnoop_hci.log` files.

## Deferred, not for this session

Capturing a real watch-face install (Route C in `docs/INVESTIGATIONS.md`)
means pairing the watch with Oraimo Health on Android, which would probably
move it off my iPhone. Don't do it. If Jobs 1 and 2 leave the watch-face
protocol unresolved, say so, and I'll decide.

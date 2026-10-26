# Investigations

Three open questions about the Watch 6R, what is known about each, and the
experiments that would answer them. Everything here is either a sourced fact
or an explicitly labelled **hypothesis**. Nothing in this file is a confirmed
protocol finding — those go in [PROTOCOL_STATUS.md](PROTOCOL_STATUS.md) once
they are.

The setup this was written for:

- The watch is bound to an **iPhone**.
- The Android phone available is an **Infinix** that reports *"Notification
  access — this feature is not available on this device"* (see below).
- There is **no Mac**.
- Firmware modification is **out of scope**, per the project rules.

## Scope at a glance

| Issue | Can we investigate it? | Can an app fix it? |
|---|---|---|
| Watch faces | Yes — live GATT recon and APK analysis now; a capture of a real install later | That is the long-term goal, once the protocol is known |
| Emoji missing on iPhone | Yes — a glyph test needing no tools, plus APK analysis | **Probably not.** See below |
| Crown rotates but does nothing | Partly — mostly with checks on the watch itself | **Not by us.** Either hardware or firmware |

---

## 1. Watch faces

**Question:** how does Oraimo Health get a watch face onto the watch?
Which characteristic, what framing, fragmented or not, acknowledged or not,
compressed, encrypted, checksummed?

**Known:** nothing about this watch yet. A web search summary of Oraimo's
product listing describes AI-generated watch faces (the page itself refused
our fetch, so this is second-hand). If accurate, it implies the transfer path accepts arbitrary
images rather than only picking from a fixed set stored on the watch — a
promising sign for custom faces, but an inference from marketing, not
evidence.

### Route A — live GATT reconnaissance *(done 2026-10-26)*

**Result:** the full attribute database is in
[PROTOCOL_STATUS.md](PROTOCOL_STATUS.md) O3: four vendor services (`feea`,
`fee7`, `190e`, `ae00`) next to the standard ones, with write-without-response
characteristics at `fee2`, `fee5`, `fee6`, `0004` and `ae01`. Which one, if
any, carries watch faces is unknown. That is Route B's job: every UUID the APK
uses can now be checked against this list.

Our lab app on the Infinix, connected **read-only**. Gives the watch's real
attribute database: every service and characteristic UUID, with properties.
Procedure in [DEVICE_SESSION.md](DEVICE_SESSION.md). The exported session
carries the full tree.

This does not show the watch-face protocol by itself. What it does is turn
every UUID found later in the APK from a guess into something checkable.

### Route B — static analysis of the Android APK *(open now)*

Oraimo Health installs on the Infinix from the Play Store **without pairing
the watch**, so the APK can be pulled without touching the iPhone setup. See
[APK_ANALYSIS.md](APK_ANALYSIS.md). For watch faces, look for: image
conversion (watch faces on 240×240 TFT watches are often converted to a
compact pixel format such as RGB565 before sending — **hypothesis**),
chunking of a byte array into fixed-size pieces, `Deflater`/LZ-style
compression, a file header written before image data, and a checksum over
the result.

A UUID found in the APK **and** present in Route A's GATT tree is strong
evidence. Found only in the APK, it is still a hypothesis — decompiled code
contains dead branches and support for other watch models.

### Route C — capture a real install *(deferred, your decision)*

The definitive evidence: an HCI snoop log on Android while Oraimo Health
installs face A, then face B ([CAPTURE_WORKFLOW.md](CAPTURE_WORKFLOW.md)).
It needs Oraimo Health **paired with the watch on Android**, which on most
watches of this kind moves the binding away from the iPhone. The notification
restriction on the Infinix does not block this — watch faces do not need
notification access — but the re-pairing is a real cost and is your call.

---

## 2. Emoji don't appear on the iPhone

**Question:** why do emoji vanish (or break) in notifications on the watch
when it is paired with an iPhone?

### How notifications probably reach the watch

**Hypothesis (strong, but unconfirmed for this watch):** non-Apple watches
paired with an iPhone receive notifications through Apple's **ANCS** (Apple
Notification Center Service). iOS itself sends the notification's title and
text to the watch over Bluetooth, as UTF-8. The Oraimo Health app on the
iPhone is not in that path.

If that holds, then **no iPhone app can fix this**. iOS does not let a
third-party app intercept or rewrite another app's notifications before they
are sent. The text arrives as iOS sent it, and the watch's firmware renders
it — or fails to. Fixing the rendering is a firmware change, which is out of
scope.

What an app *could* do, later, is on **Android**: there a companion app reads
notifications itself and forwards them using the vendor protocol, so it could
substitute something the watch can display. That needs a phone where
notification access works — not this Infinix — and the notification protocol
worked out first.

### The Infinix restriction

*"Notification access — this feature is not available on this device"* is
the message shown on Android Go / low-RAM builds, which block apps from
reading notifications at all
([Niagara Launcher help](https://help.niagaralauncher.app/article/31-notifications-not-showing),
[Kotlin Slack](https://slack-chats.kotlinlang.org/t/13397738/some-android-go-devices-have-notification-access-disabled-an),
[ASUS ZenTalk](https://zentalk.asus.com/en/discussion/21013/notification-access-this-feature-is-not-available-on-this-device)).
Confirm with:

```bash
adb shell getprop ro.config.low_ram      # "true" on a low-RAM / Go build
```

It blocks **notification forwarding only**. BLE, our lab app, pulling the
APK, and watch-face transfers are all unaffected.

### Experiment: the glyph test *(no tools needed)*

Get the iPhone to show one notification per line below, and photograph the
watch for each. A Reminder set a minute ahead works if Oraimo Health forwards
Reminders; otherwise ask someone to send each line as a message.

| # | Send this | Characters | UTF-8 bytes per character |
|---|---|---|---|
| 1 | `Test ABC 123` | plain ASCII — the control | 1 |
| 2 | `Test é ñ ü` | accented Latin | 2 (`é` = `C3 A9`) |
| 3 | `Test ★ ♥ ✓ ☺` | symbols in the Basic Multilingual Plane | 3 (`★` = `E2 98 85`) |
| 4 | `Test 中文` | CJK | 3 (`中` = `E4 B8 AD`) |
| 5 | `Test 😀 👍` | emoji | **4** (`😀` = `F0 9F 98 80`) |
| 6 | `Test ❤️` | BMP heart + variation selector | 3 + 3 |
| 7 | `Test 👨‍👩‍👧` | emoji joined with zero-width joiners | several 4-byte + 3-byte |

The word `Test` before each makes truncation visible.

**How it fails tells you why.** Note exactly what appears:

| What the watch shows | What it suggests |
|---|---|
| Garbage like `ðŸ˜€` for 😀, `Ã©` for é | The watch reads UTF-8 as single-byte text. A decoder problem, affecting everything non-ASCII |
| One box `□` or `?` per emoji | Decoding works; the font simply has no glyph |
| Two boxes per emoji | 4-byte characters handled as two halves (UTF-16 surrogate-style) |
| The message stops at the emoji | The decoder gives up on 4-byte sequences |
| The emoji is silently missing, rest intact | Filtered out — by the watch, or before it got there |
| Lines 2–4 fine, line 5 broken | **Supports the hypothesis below** |
| Only line 1 fine | The font is ASCII-only; emoji are just the most visible casualty |

**Hypothesis E1:** *the watch's text handling stops at the Basic Multilingual
Plane* — characters up to U+FFFF (≤ 3 UTF-8 bytes) can render, characters
above it (all common emoji, 4 bytes) cannot.

- **Supported** if lines 2–4 render and line 5 fails.
- **Refuted** if line 3's symbols fail too (then the limit is lower), or if
  any 4-byte emoji renders correctly.

### Experiment: what the Android app does with emoji *(APK, Route B)*

Search the decompiled Oraimo Health code for the notification-forwarding
path: the `NotificationListenerService` subclass and whatever builds the
message it sends. Look for charset conversions (`UTF-16`, `GBK`,
`getBytes(...)`), regexes or code-point ranges that strip emoji, and length
limits. The watch likely has two text paths — ANCS from iOS, and the vendor
protocol from Android — and the Android encoder is direct evidence about what
the watch's decoder accepts. If the Android app deliberately strips or
replaces emoji, that is close to a confession that the firmware cannot draw
them.

---

## 3. The crown rotates but does nothing

**Question:** the crown physically turns but scrolls nothing; pressing it
wakes the watch. Is it meant to scroll?

**Known:**

- One retailer, [Ryans](https://www.ryans.com/oraimo-watch-6r-bluetooth-calling-smart-watch),
  lists *"Buttons: 1"* and *"Scrollable Pin/Button: Yes"*.
- Oraimo's own listing and other retailers
  ([Startech](https://www.startech.com.bd/oraimo-watch-6r-smart-watch),
  [Sumash Tech](https://www.sumashtech.com/product/oraimo-watch-6r)) do not
  mention a rotating crown either way.
- So whether rotation is a supported feature is **unconfirmed**.

**Why the BLE lab is mostly the wrong tool:** turning the crown is handled
inside the watch to move its own UI. There is no reason that would be sent
over Bluetooth, so captures would almost certainly show nothing, and nothing
would not prove anything.

### Checks, cheapest first

1. **Find the firmware version.** In Oraimo Health on the iPhone (device or
   about screen), or from our app: *Read all* reads the SIG *Firmware
   Revision String* (`2A26`) if the watch exposes Device Information.
   **Done over BLE 2026-10-26:** firmware `JLQFNLKV3.5`, software
   `823-8AW4-1.2.4` (PROTOCOL_STATUS O4). Whether Oraimo Health shows the same
   version string is still to check.
2. **Check for a firmware update** in Oraimo Health. Crown support is the
   kind of thing that ships in an update.
3. **Try rotation on list screens**, not just the watch face: the app list,
   settings, the message list, the watch-face picker. Many watches only use
   the crown to scroll lists, and on the home face it does nothing by design.
4. **Check the user manual** that came in the box, or Oraimo's support page.
5. If the manual says it scrolls and it does not anywhere, that is a
   **warranty claim**, not a reverse-engineering problem.

### Optional side-check over BLE

After *Subscribe all* in our app, rotate the crown slowly for a few seconds
and watch the packet monitor. Any packets that arrive only while rotating are
interesting. **No packets proves nothing**, for the reason above.

**Done 2026-10-26:** with all 8 notify/indicate characteristics subscribed,
~10 s of rotation from 18:04 and one press produced **no packets** (nothing at
all arrived in the 8 minutes after subscribing). Inconclusive, as expected.

While in the APK (Route B), it is worth a search for settings related to
"crown", "knob", "rotate" or "encoder" — some watches have a setting that
enables rotation or reverses its direction. This is a **speculative** lead,
not an expectation.

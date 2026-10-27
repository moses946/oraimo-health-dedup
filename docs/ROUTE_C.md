# Route C — capturing a real watch-face install

A decision document. Nothing here has been done. It says what Route C would
involve, what it would answer, and what it could cost the watch's binding to
the iPhone, so the decision can be made with eyes open.

Everything about the watch's behaviour below comes from reading Oraimo Health
2.0.7 for Android ([PROTOCOL_STATUS.md](PROTOCOL_STATUS.md), A1–A18). None of
it has been seen on the wire, and the iPhone app has not been read at all.
Where a risk rests on an assumption, it says so.

## What it would answer

One session of captures would settle most of what static analysis cannot:

- whether watch faces really go to `fee6`, framed `FE EA …`, with the watch
  requesting chunks and a CRC-16 (init `0xFEEA`) at the end (H3)
- the **format of a real market face file**, which never passes through the
  app's code (A11) — it would be visible byte for byte in the capture
- the compression type the 6R reports, and so which background converter it
  needs (A12–A14)
- what Oraimo Health sends first after connecting (H2)
- whether `ae00` and `190e` are used at all (A10)

## What adding the watch does, per the APK (A18)

The MOY path binds the watch to a **user** with app-level commands, not only
a Bluetooth pairing:

| When | Call | Bytes sent (in the `FE EA` frame) |
|---|---|---|
| Adding the watch | `createBond(code, userId)` | `B0 00` + a 6-character code (`"123456"` if none) |
| Every later connection | `checkUserID(userId)` | `B0 01` + a 32-character user ID |
| Removing the watch | `removeBond()` | `F8` |
| Connection set-up | `queryBtAddress()` | `F1 00` (the watch's Bluetooth Classic address, used for calls) |

Oraimo's device manager logs `bind : …` before `createBond` and
`verifyUserId...` before `checkUserID`. The user ID comes from the app's own
account cache. Where the 6-character code comes from is not yet known.

**The inference** — and it is one — is that the watch remembers which user ID
it is bound to, and the app on every reconnect checks that it is its own.

## The procedure

### Before

1. **Sync the iPhone.** Open Oraimo Health on the iPhone and let it sync, so
   nothing recorded on the watch exists only on the watch.
2. **Write down the watch's state:** the current face, alarms, notification
   settings, do-not-disturb — anything you would not want to set up again.
3. **Charge the watch.** It reported 4 % battery on 2026-10-26; a face install
   that dies halfway is a bad way to find out how recovery works.
4. **On the Infinix**, enable the HCI snoop log (Developer options, unfiltered)
   and toggle Bluetooth off and on ([CAPTURE_WORKFLOW.md](CAPTURE_WORKFLOW.md)).
5. **Revoke Oraimo Health's SMS, call-log and location permissions** on the
   Infinix unless you want it to have them. None are needed for faces.

### During

6. **iPhone: Settings → Bluetooth → off** (Settings, not Control Center).
7. **Infinix: Oraimo Health → add device.** This will probably require signing
   in — the app needs a user ID to bind (A18). See R1 for which account.
8. **If Android asks to pair for calls or audio, decline.** That is the
   Bluetooth Classic bond the iPhone uses for calls (R3).
9. Run the three captures in [CAPTURE_WORKFLOW.md](CAPTURE_WORKFLOW.md):
   `connection-test`, `watchface-A`, `watchface-B` — **free faces only**.
   Optionally a fourth, `background-photo`, to capture the custom-background
   path.
10. Pull the logs; the app imports them (Sessions → Import HCI snoop log).

### After — giving the watch back

There are two ways back, and which is safer is one of the open questions:

- **A. Remove the watch in the Android app** (sends `F8`, A18), then add it in
  the iPhone app. Clean on paper, but what `F8` does to the watch's data is
  unknown (R5).
- **B. Leave Android as it is** (uninstall or just turn its Bluetooth off),
  turn the iPhone's Bluetooth on, and see whether the iPhone app reconnects
  on its own. If it does not, remove and re-add the watch in the iPhone app.

## Risks to the iPhone binding

| # | Risk | How likely | Based on |
|---|---|---|---|
| R1 | **The iPhone app rejects the watch afterwards** because it is now bound to a different user ID | Likely if a **different** account is used on Android | APK: `createBond` writes a user ID; `checkUserID` verifies it on reconnect (A18). Assumes the iOS app does the same check — unverified |
| R2 | iPhone notifications and sync stop **while** Android has the watch | Near certain, temporary | O1/O2: the watch advertised only with the iPhone's Bluetooth off; a connected watch generally does not accept a second phone |
| R3 | **Calls stop working on the iPhone** if the watch accepts a Classic pairing from Android | Avoidable by declining step 8 | APK: `queryBtAddress` reads the Classic address; whether the watch keeps more than one Classic bond is unknown |
| R4 | The iPhone has to **"Forget This Device"** and pair again for notifications | Possible | Assumes notifications use ANCS with an iOS-side bond (hypothesis, INVESTIGATIONS §2); a new bond elsewhere may displace it |
| R5 | **Watch data or settings are cleared** on unbind or rebind | Unknown | `removeBond` sends `F8`; its effect on the watch is not in the APK. Mitigated by steps 1–2 |
| R6 | Sign-in shares data with Oraimo's Android app: the watch's MAC, model and firmware go with every request (A17) | Certain once signed in | APK, A17 |

### Mitigation for R1

**Sign in on Android with the same Oraimo account the iPhone uses.** If the
user ID is per account, the watch would be re-bound to the *same* ID and the
iPhone's check should still pass. That is a hypothesis: the APK shows the ID
coming from the account cache, but not whether it is the account's server-side
ID (shared across phones) or something per install.

### Worst case and recovery

The realistic worst case is: the iPhone app no longer recognises the watch,
iOS needs to forget and re-pair it, and some watch settings need setting up
again. Recovery is the normal one —

1. iPhone: Oraimo Health → remove the device (if it is listed).
2. iPhone: Settings → Bluetooth → the watch → Forget This Device.
3. If the watch still refuses, reset it from its own settings menu.
4. iPhone: add the watch again in Oraimo Health; re-pair for calls when asked.

What could be lost: anything not synced (step 1 prevents that), on-watch
settings (step 2 records them), and the current face (re-installable). Nothing
here suggests a risk to the watch itself — firmware is not touched.

## What would make it lower-risk

- **A second, cheap Watch 6R** (or any OSW-823) bound only to Android. No
  binding to lose. The protocol should be the same; the firmware string
  (`JLQFNLKV3.5`, O4) is worth matching.
- **Reading the iOS app** first would turn R1 and R4 from assumptions into
  facts — but there is no Mac, and no iOS app binary to hand.

## Recommendation

If the iPhone binding matters day to day: do it **signed in with the same
account**, decline any call pairing, sync first, and use way-back **B** before
**A**. If a second watch is an option, that is better than any of the
mitigations above.

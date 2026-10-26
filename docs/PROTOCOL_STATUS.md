# Protocol status

**Last updated:** 2026-10-26, after the first read-only GATT reconnaissance
of the real watch (session `gatt-recon`). Investigation plans are in
[INVESTIGATIONS.md](INVESTIGATIONS.md).

## What is known about the Oraimo Watch 6R (OSW-823) protocol

The watch's attribute database and its identification strings — see
[Confirmed findings](#confirmed-findings). Nothing about the protocol carried
over the vendor services: no packet has been seen on any of them.

Specifically, we do not know:

- [x] Which BLE services the watch exposes — see O1
- [ ] Which characteristics carry commands, and which carry responses
- [ ] Whether there is a packet header, and what is in it
- [ ] Whether packets carry a length field
- [ ] Whether packets carry a sequence number
- [ ] Whether packets carry a checksum, and over which bytes
- [ ] Whether payloads are compressed
- [ ] Whether payloads are encrypted, and if so whether a pairing key is involved
- [ ] What format a watch face is in
- [ ] How a watch face is transferred
- [ ] Whether transfers are acknowledged per fragment or per file
- [ ] What the maximum payload size is, and whether it tracks the ATT MTU

## Why there is no decoder in this repository

Because writing one now would mean inventing a format, and an invented format
that happens to be wrong is worse than no format at all — it looks like
knowledge, gets built on, and is expensive to unwind.

The app therefore contains `BleTransport` (which moves bytes) and the evidence
store (which records them), and nothing in between. The protocol layer the
architecture leaves room for stays empty until something fills it honestly.

## How this document gets updated

1. Capture evidence following [CAPTURE_WORKFLOW.md](CAPTURE_WORKFLOW.md).
2. Record what you saw as **observations**, citing the packets.
3. State what you think it means as a **hypothesis**, together with what would
   disprove it.
4. Try to disprove it. Deliberately. Design the capture that would break it.
5. When a hypothesis survives that, move it to `SUPPORTED` and record it below
   — with a link to the sessions that back it.

A hypothesis at `SUPPORTED` still is not a fact. It is a claim that has not yet
been broken.

## Confirmed findings

These are **observations**: what one live, read-only session showed, nothing
inferred. Evidence for all of them:

- **Capture:** [`research/captures/gatt-recon_2026-10-26_14-53-35.json`](../research/captures/gatt-recon_2026-10-26_14-53-35.json)
  (58 events; the discovery event, seq 27, holds the full tree in `detail`)
- **Setup:** Infinix X657B (HOT 10 Lite), Android 10 Go (API 29),
  `armeabi-v7a`, `ro.config.low_ram=true`; lab app 1.0.0 from CI run
  40340813762. iPhone Bluetooth off in Settings for the duration.
- Cross-checked against the phone's logcat for the same session (not
  committed — it contains other devices).

### O1 — advertisement

| Field | Value |
|---|---|
| Name | `oraimo Watch 6R_B81A` |
| Address | `8D:62:CC:93:B8:1A` |
| Connectable | yes |
| Manufacturer data | company `0xF0EF`, payload `8D62CC93B81A` |
| Service data | UUID `0xFEEA`, payload `38415706010091` |

The manufacturer-data payload is byte-for-byte the device address. The name
suffix `B81A` is the address's last two bytes. Visible only with the iPhone's
Bluetooth off.

### O2 — connection

- Connected without any pairing or bonding request. The watch did not appear
  in Android's bonded-device list afterwards.
- Requested ATT MTU 512; the watch accepted **512** (`onConfigureMTU ...
  mtu=512 status=0`).
- Connection parameter updates seen: `interval=6 latency=0 timeout=500`,
  then `interval=39 latency=0 timeout=500`, then after subscribing
  `interval=28 latency=16 timeout=600` (units as Android reports them; which
  side initiated is not in the log).
- Disconnect from the phone logged as `reason=22`. The watch then reconnected
  to Oraimo Health on the iPhone (user-confirmed).

### O3 — attribute database

9 primary services, 21 characteristics, no included services. Android does
not expose handles, so `handle` is null throughout. SIG names are from the
app's lookup table; the four 16-bit vendor UUIDs are not SIG-assigned
attribute names.

| Service | Characteristic | Properties | CCCD |
|---|---|---|---|
| `1800` Generic Access | `2a00` Device Name | READ, WRITE | |
| `1801` Generic Attribute | `2a05` Service Changed | INDICATE | ✓ |
| `180d` Heart Rate | `2a37` Heart Rate Measurement | NOTIFY | ✓ |
| | `2a38` Body Sensor Location | READ | |
| `180f` Battery | `2a19` Battery Level | READ, NOTIFY | ✓ |
| `180a` Device Information | `2a25` Serial Number String | READ | |
| | `2a26` Firmware Revision String | READ | |
| | `2a28` Software Revision String | READ | |
| | `2a29` Manufacturer Name String | READ | |
| `feea` | `fee1` | READ, NOTIFY | ✓ |
| | `fee2` | WRITE_NR | |
| | `fee3` | NOTIFY | ✓ |
| | `fee4` | READ | |
| | `fee5` | WRITE_NR | |
| | `fee6` | WRITE_NR | |
| `fee7` | `fec9` | READ | |
| | `fea1` | READ, NOTIFY | ✓ |
| `190e` | `0004` | WRITE_NR | |
| | `0003` | NOTIFY | ✓ |
| `ae00` | `ae01` | WRITE_NR | |
| | `ae02` | NOTIFY | ✓ |

Structural observation, no meaning attached: each of `feea`, `190e` and
`ae00` pairs at least one write-without-response characteristic with at least
one notify characteristic.

### O4 — values read

Every readable characteristic, all `GATT_SUCCESS`, no authentication or
encryption errors:

| Char | Hex | ASCII |
|---|---|---|
| `2a00` | `6F7261696D6F2057617463682036525F42383141` | `oraimo Watch 6R_B81A` |
| `2a38` | `01` | |
| `2a19` | `04` | |
| `2a25` | `3442424546383741` | `4BBEF87A` |
| `2a26` | `4A4C51464E4C4B56332E35` | `JLQFNLKV3.5` |
| `2a28` | `3832332D384157342D312E322E34` | `823-8AW4-1.2.4` |
| `2a29` | `4D4F594F554E472D5632` | `MOYOUNG-V2` |
| `fee1` | `000000000000000000000000` (12 bytes) | |
| `fee4` | *(0 bytes)* | |
| `fec9` | `8D62CC93B81A` | — the device address again |
| `fea1` | `01000000` | |

`2a19 = 04` would be 4 % under the SIG Battery Level format; not yet compared
with what the watch's own screen showed.

### O5 — subscriptions and unprompted traffic

- CCCDs enabled on all 8 notify/indicate characteristics, all `GATT_SUCCESS`
  (`02 00` for `2a05`, `01 00` for the rest). The library had also enabled
  `2a05` by itself right after discovery.
- **No notification or indication arrived on any of them** in the 8 min 15 s
  that followed (17:59:58–18:08:13 phone time), which included rotating the
  crown for ~10 s from 18:04, one press, and a minute idle.
- The session made **no characteristic writes**.

## Open hypotheses

### H1 — the vendor protocol comes from a MOYOUNG platform

*Status: UNKNOWN. One clue, no test yet.*

**Claim:** the watch's vendor services (`feea`, `fee7`, `190e`, `ae00`)
implement a protocol from the company or SDK named in its Manufacturer Name
String, so knowledge of that platform would transfer.

**Evidence for:** `2a29` reads `MOYOUNG-V2` (O4). That is a string the
firmware reports about itself, nothing more.

**Supported if** the Oraimo Health APK contains a MOYOUNG-named SDK whose
code uses these same UUIDs.

**Refuted if** the APK's BLE code is unrelated to anything MOYOUNG-named, or
uses none of these UUIDs.

### H2 — the watch only talks when spoken to

*Status: UNKNOWN. Consistent with O5, which cannot distinguish it from the
alternatives.*

**Claim:** the vendor notify characteristics stay silent until the phone sends
a command on a paired write characteristic.

**Alternatives O5 does not rule out:** the watch needs an app-level
handshake or bind before sending anything; or it sends only on events that
did not happen during the session.

**Tested by** the APK (what Oraimo Health writes first after connecting), or a
capture of a real session. Not by us writing to it — this project is
read-only for now.

### E1 — text handling stops at the Basic Multilingual Plane

*Status: UNKNOWN. Not yet tested.*

**Claim:** on the iPhone path, the watch can render characters up to U+FFFF
(at most 3 UTF-8 bytes) but not above it, which is where nearly every emoji
lives (4 bytes).

**Why it is plausible:** emoji go missing on the iPhone; 4-byte UTF-8 is a
classic boundary for embedded text handling. That is a reason to test it,
not evidence for it.

**Supported if** the glyph test shows accented Latin and BMP symbols
(`é`, `★`) rendering while 4-byte emoji (`😀`) do not.

**Refuted if** BMP symbols fail too (the limit is lower), or any 4-byte emoji
renders correctly.

**Depends on** a second, also unconfirmed, hypothesis: that the iPhone
delivers notifications to the watch via ANCS. If true, the fix is firmware and
out of scope for this project.

## Disproven

*(none yet — but this section is as valuable as the one above. Knowing what the
protocol is not narrows the search.)*

# Protocol status

**Last updated:** 2026-10-26, after the first read-only GATT reconnaissance
of the real watch (session `gatt-recon`) and a static reading of Oraimo
Health 2.0.7. Investigation plans are in [INVESTIGATIONS.md](INVESTIGATIONS.md).

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

## APK observations — Oraimo Health 2.0.7

Static reading of `com.transsion.oraimohealth` 2.0.7 (versionCode 87), pulled
from the Infinix on 2026-10-26. The APK and everything extracted from it stay
in the gitignored `research/apk/` and `research/decompiled/`. No decompiler
was available (the JDK/jadx download was refused), so this comes from
parsing the DEX files directly: the string table, method and field
references, and instruction-level dumps of individual methods. Class names
below are R8-obfuscated as they appear (`com/crrepa/h0/d` etc.) and will
change between app versions.

**These are what the code says, not what the watch does.** Each one stays a
hypothesis until a capture shows it on the wire. Where a UUID also appears
in O3, that part is evidence; the behaviour around it is not.

- **A1 — the app maps this watch to a MOYOUNG SDK.** `DeviceTypeEnum`
  (`com.transsion.data.model.enumeration`) constructs `OSW_823` with
  productCode `OSW-823`, displayName `oraimo Watch 6R`, brand `TS-2G` and
  **developer `MOY`** (argument order read from the constructor's field
  stores). Oraimo code branches on `developer == "MOY"` (e.g. `ie/d`, which
  then calls `pf/d`, the largest caller of `com.crrepa.ble`). The app
  bundles at least ten vendor SDKs (`com.zh.ble`, `topstep`, `yc.utesdk`,
  `realsil`, `sjbt`, `sifli`, …); `com.crrepa.ble` (`CRPBleClient`,
  `CRPBleConnection`) is the one on the MOY path.
- **A2 — the crrepa SDK's GATT map matches `feea` on the watch.**
  `com/crrepa/q/b.<init>` looks for a service whose UUID contains `feea` and
  picks out `fee1`, `fee2`, `fee3`, `fee5`, `fee6`, `fee7`, `fee8`, `fee9`,
  plus `180a`/`2a24`/`2a28`/`2a29`, `180f`/`2a19`, `180d`/`2a37` and
  `3802`/`4a02`. The watch has `fee1`–`fee6` but not `fee7`–`fee9` or
  `3802` (O3). Notifications are dispatched by characteristic in
  `com/crrepa/m/a`: `fee1`, `2a37`, `fee7`, `fee8`, `2a19`, `4a02`.
- **A3 — write routing.** Every SDK write goes through a queue
  (`com/crrepa/p/c.d`) and is routed by message type:

  | message type | written to |
  |---|---|
  | 0, 8 (commands) | characteristic chosen by frame byte 4 (the command id): 1→`fee5`, 2→`fee6`, 3→`4a02`, 4→`fee9`, else **`fee2`** |
  | 1 | `fee5` |
  | 2 | `fee6` |
  | 38 | `4a02` |
  | 39 | `fee9` (logged as the "hisilicon characteristic") |

  Writes are chunked to a maximum from `com/crrepa/f/y1.a()` and use
  write-without-response when a flag is set (`m/f.h`).
- **A4 — command frame** (`com/crrepa/f/y1.a(byte cmd, byte[] payload)`):
  `FE EA | b2 | len & 0xFF | cmd | payload…`, where `len = payload + 5` and
  `b2` is `0x10` when `l/b.d()` returns 20, otherwise `0x20 + (len >> 8)`.
  No checksum in the frame.
- **A5 — watch-face transfer engine** (`com/crrepa/h0/*`):
  `h0/a.b` ("sendWatchFaceMessage") sends as message type 2, i.e. **`fee6`**;
  `h0/d.sendMessage` sends as type 1 or 2 (`fee5`/`fee6`). The watch drives
  the transfer: it asks for chunk indices (`h0/d.transFileIndex`, which
  rejects an index that goes backwards, `"offset is error"`), the phone
  answers each with the file slice read via `RandomAccessFile`, and at the
  end the watch reports a CRC that the phone compares with its own and
  answers with a pass/fail (`checkFileCRC`, `sendFileCheckResult`).
  Bitmap faces have their own size/bytes steps (`h0/a`: "sendBitmapSize",
  "sendBitmapBytes start = …").
- **A6 — the file CRC is CRC-16/0x1021, seeded with `0xFEEA`.**
  `h0/e.c` runs `h0/c.a` over the file in 4096-byte blocks from a header
  offset, starting from 65258 (`0xFEEA`). `h0/c.a` is the table-free CRC-16
  (byte swap, then shifts of 4, 12, 5). A literal Python port of the
  disassembly gives `0x29B1` for `"123456789"` with init `0xFFFF` (the
  CRC-16/CCITT-FALSE check value) and agrees with a bitwise reference
  (poly 0x1021, MSB-first, no reflection, no xorout) on random input.
- **A7 — notification text** (`com/crrepa/i/a.a(CRPMessageInfo)`): `title +
  ":" + message`, passed through the emoji filter (A8), truncated by
  characters until its **UTF-8** encoding fits the watch's message length,
  then sent as command 65 (`0x41`) with payload `[type][UTF-8 text]`.
  Also: `querySupportEmojiCount`/`List` send command `0xBB` with payloads
  `16 00` and `16 01 nn`; `queryMessageLength` exists.
- **A8 — the SDK replaces emoji with the text `[emoji]`.** `com/crrepa/c1/g`
  builds a set of ~4,000 code units (U+00A9, U+00AE, U+2194–U+2B55,
  U+3030, U+303D, U+3297/9, the U+1F000–U+1FAFF emoji blocks, U+200D ZWJ,
  U+FE0E, U+20E3, U+E007F). `c1/g.a(String)` first replaces 📹 (U+1F4F9)
  with `[Video Camera]`, then walks the text, joining surrogate pairs, and
  replaces every code point in the set with `[emoji]`. Code points the
  watch reports as supported are removed from the set first, so they pass
  through. Both insertion and lookup cast the code point to a 16-bit `char`,
  so U+1F600 is stored as `0xF600`.
- **A9 — no crown in the MOY path.** None of `CRPBleConnection`'s 422
  methods mention a crown, knob, rotation or encoder. The only crown
  settings in the app (`supportSetCrownTouchState`, `isCrownHapticFeedback`)
  belong to a different vendor SDK, `com.base.sdk`.
- **A11 — two face routes on the MOY path.** Oraimo code calls
  `sendWatchFace(new CRPWatchFaceInfo(file, DEFAULT))` with
  `ClockDialBean.filePath` (`pf/e.R`): a **prebuilt file, sent verbatim**.
  `sendWatchFace` requests the 2M PHY (`setPreferredPhy(2, 2, 0)`) and hands
  the file to the generic engine of A5 (`v0/c` → `h0/d`) with no chip-specific
  branch. The app does not build these files and none for MOY is bundled;
  their format is whatever Oraimo's server serves. The other route is a
  **custom background photo** (`sendWatchFaceBackground` +
  `sendWatchFaceLayout`), converted on the phone according to the
  compression type the watch reports in its layout reply (A12).
- **A12 — compression types and converters.**
  `CRPWatchFaceLayoutInfo$CompressionType` values: LZO=0, RGB_DEDUPLICATION=1,
  RGB_LINE=2, BLUETRUM=3, RTK_8773=4, JIELI=5, JIELI_707=21, SIFLI=254,
  ORIGINAL=255. The background factory (`w0/i.a`) maps them to converters:
  ORIGINAL→`w0/c` (no conversion), LZO→`w0/f` (`wf.bin` →
  `MiniLzoHelper.compress` → `wf_lzo.bin`), RGB_LINE→`w0/e`, AVATAR→`j0/a`,
  BLUETRUM→`w0/b` (adds header bytes), RTK_8773→`w0/g`, JIELI→`w0/d`;
  SIFLI has no entry. JIELI_707 has its own path (`x0/c`).
- **A13 — the SDK's own image encoding** (`y0/b`, `y0/c`, `c1/p`): pixels
  read row by row with `getPixel(x, y)`, converted to **RGB565**
  (`r>>3<<11 | g>>2<<5 | b>>3`); the value `0x0821` is bumped to `0x0822`.
  Serialised either raw (2 bytes per pixel, **big-endian**) or run-length:
  header **`08 21`**, then `[RGB565 BE][count, 1 byte]` per run, runs ≤ 255;
  the run-length form is used only when shorter than `w×h×2` (115200 =
  240×240×2 when the size is unknown). That the header equals the bumped
  colour suggests `0x0821` is reserved as the run-length marker — an
  inference, not something the code states. The size goes first as command
  `0x6E` with a 4-byte length ("sendBitmapSize").
- **A14 — JieLi conversion.** For JIELI, `w0/d` writes each bitmap to a file
  and calls `com.jieli.bmp_convert.BmpConvert.bitmapConvert` (library 1.6.0,
  `libjl_bmp_convert.so`) with type **3 = `TYPE_701N_RGB_NO_PACK`** (same
  value as `TYPE_BR_28_RAW`) and `ConvertParam` format **1 =
  `FORMAT_ARGB_8565`**. The native library exposes `br23_*`, `br28_*` and
  `br35_*` `bmp/png/jpeg_to_res` converters and bundles ETCPACK (ETC1/ETC2);
  its output format is native code and has not been read. The SDK wraps the
  result: `[05][FF FF FF][first file length, 4 bytes][.bin contents…]`.
- **A15 — the advertisement says JieLi.** `CRPScanRecordParser.parseScanRecord`
  takes the service-data element (AD type `0x16`) whose UUID is `0xFEEA`
  and reads bytes 2–4 as `firmwareType` (ASCII, `'0'` removed), byte 5 as
  the MCU platform (1 NORDIC, 2 HUNTERSUN, 3 REALTEK, 4 GOODIX, 5 SIFLI,
  6 JIELI), byte 6 as chip id and bytes 7–8 as a function value. Applied to
  the 6R's captured service data (O1, `EA FE 38 41 57 06 01 00 91`):
  `firmwareType = "8AW"`, **`PLATFORM_JIELI`**, chip id 1, function
  `0x9100`. `8AW` matches the watch's own `2a28` `823-8AW4-1.2.4` (O4).
  Oraimo uses the platform for firmware updates (`pf/e.X`); face conversion
  follows the compression type instead (A12).
- **A16 — the `DialCustom` assets are not for this watch.** They are layout
  templates (per-element PNG glyphs, with size and position encoded in empty
  `config_WxH_XxY.txt` filenames) read by the UTE SDK
  (`com.yc.utesdk.watchface.open.WatchFaceUtil`) and one other vendor's
  code. The `TOPSTEP`-signed `.bin` dials belong to the TS vendor.
- **A17 — where market faces come from.** Oraimo code never calls the
  crrepa SDK's own MOYOUNG face client (`com/crrepa/b1/*`,
  `api.moyoung.com/faces/...`). Faces are listed by Oraimo's backend through
  Retrofit interfaces `rh/a` and `rh/b`, all `POST` (obfuscated annotations,
  read by usage): `api/clockDial/index` (query `count`,
  `supportBuyWatchFace`, `supportBuyType`; returns categories),
  `api/clockDial/getByCategoryId` (query `categoryId`, `supportBuyWatchFace`,
  `supportBuyType`; returns `DialInfoEntity` list), `downloadComplete`,
  `myCloudClockDial`, `getOwnedList`, `getOwnStatus`, `exchangeByCode`.
  The face-list calls carry `TAG_FIXED_DOMAIN:true`, which interceptor
  `rh/n` pins to `https://health-api.oraimo.com/`. Each entry has
  `resourceUrl`, `picUrl`, `fileSize`, price and ownership fields; the file's
  host is in the server's answer, not the APK. Interceptor `rh/c` adds
  `token`, `timestamp`, `language`, phone brand/model/OS, app version and
  store, and the connected watch's `deviceSupplierName`, `deviceType`,
  `deviceDisplayName`, `deviceModel`, `deviceMac` and
  `deviceFirmwareVersion` to every request.
- **A10 — UUIDs not accounted for.** `ae00`/`ae01`/`ae02` appear only in
  another vendor's table (`utenif/utenelse`, the UTE SDK). `190e` and `0004`
  appear nowhere in the DEX strings or native libraries; `00000003-…` only
  in the `com.zhapp.ble` table. `fee7` as a *service* with `fec9`/`fea1`
  is not referenced as such by the crrepa SDK. The app could still build
  these UUIDs numerically; a string search cannot rule that out.

## Open hypotheses

### H1 — the vendor protocol comes from a MOYOUNG platform

*Status: SUPPORTED by the APK (A1, A2). Not yet seen on the wire.*

**Claim:** the watch's vendor services (`feea`, `fee7`, `190e`, `ae00`)
implement a protocol from the company or SDK named in its Manufacturer Name
String, so knowledge of that platform would transfer.

**Evidence for:** `2a29` reads `MOYOUNG-V2` (O4). Oraimo Health assigns
OSW-823 the developer code `MOY` and drives MOY devices with the
`com.crrepa.ble` SDK, whose `feea` map names exactly the `fee1`, `fee2`,
`fee3`, `fee5`, `fee6` the watch exposes (A1, A2) — the criterion set below.

**Limits:** this covers `feea` only. `fee7`, `190e` and `ae00` are not
explained by the crrepa SDK (A10).

**Refuted if** a capture of Oraimo Health talking to this watch shows its
traffic on characteristics other than those in A3, or in a frame shape
unlike A4.

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

**APK note:** consistent with A5, where the watch-face transfer is driven by
the watch asking for chunks, and with the SDK sending query commands (A7)
whose answers arrive as notifications. Neither shows what, if anything, the
watch sends unasked.

### H3 — watch faces go to `fee6`, framed and CRC-checked as in A4–A6

*Status: UNKNOWN on the wire. Built entirely from APK reading.*

**Claim:** Oraimo Health sends a watch face to this watch as a file over
`fee6`, in chunks the watch requests by index, with a whole-file CRC-16
(poly 0x1021, init `0xFEEA`) compared at the end.

**Caveats:** market faces are prebuilt files sent verbatim (A11), so their
format is the server's and has not been seen. Custom backgrounds are
converted on the phone by compression type (A12–A14). The 6R advertises
`PLATFORM_JIELI` (A15), which makes the JIELI or JIELI_707 converter likely,
but the type the watch actually reports comes back only in reply to a layout
query — a write this project has not made. If it is JIELI, the image bytes
come from JieLi's native BR28/701N converter, whose output format is unread.

**Supported if** a capture of a real face install shows `FE EA`-framed
writes and file chunks on `fee6`, and a CRC that matches A6 over the file.

**Refuted if** a face install uses another characteristic or service (for
example `ae01`), or the CRC does not match.

### H4 — emoji are stripped on the Android path because the firmware cannot draw them

*Status: PLAUSIBLE from A8. Says nothing directly about the iPhone path.*

**Claim:** the Android SDK replaces emoji and many BMP symbols with the text
`[emoji]` (A8) because this watch's firmware cannot render them, unless the
watch reports specific glyphs as supported.

**Bearing on E1:** the filter covers BMP symbols such as ☀ ★ ☺ ♥ (U+2600–U+27BF)
as well as 4-byte emoji. If it reflects the firmware's font, the limit is
lower than the Basic Multilingual Plane, which the glyph test would show as
line 3 failing — refuting E1 as stated.

**Supported if** the glyph test (INVESTIGATIONS §2) shows symbols in the
filter's ranges failing on the watch while characters outside them render.

**Refuted if** characters in the filter's set render correctly on the watch
from the iPhone.

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

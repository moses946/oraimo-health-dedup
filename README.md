# Oraimo Lab

A companion app for the **Oraimo Watch 6R (OSW-823)** — and, for now, mostly a
BLE laboratory.

The protocol this watch speaks is undocumented. Nobody here has the service
UUIDs, the characteristic UUIDs, the packet framing, the checksum scheme, or
the watch-face format. So this app does not pretend to speak that protocol. It
scans, connects, browses the attribute database, lets you poke individual
characteristics, records every byte that moves with a timestamp and a
direction, and exports the result as JSON you can reason about later.

**There is no protocol decoder in this repository, and that is deliberate.**
Writing one would mean inventing a format. Evidence first.

---

## What it does today

| | |
|---|---|
| **Nearby Devices** | Unfiltered BLE scan. Name, address, RSSI, advertised service UUIDs, manufacturer and service data as raw hex. Filter by anything; star the watch to pin it to the top. |
| **Connection** | Connect, disconnect, reconnect with capped backoff. Every state is shown — Disconnected, Connecting, Connected, Reconnecting, Error — with the platform's own error text, never a generic "something went wrong". |
| **GATT Explorer** | Every discovered service, characteristic, property and descriptor. |
| **Characteristic** | Read, write raw hex (with or without response), subscribe and unsubscribe. Values shown as hex, ASCII and an offset dump. |
| **Packet Monitor** | Live feed of every BLE operation: time, direction, operation, attribute, payload, length. Pause, clear, filter by direction or characteristic, copy. |
| **Capture Sessions** | Named experiments — `watchface-A`, `change-time` — recorded to SQLite and exported as JSON. |
| **HCI snoop import** | Reads Android's `btsnoop_hci.log`, which is the only way to see what the *official* Oraimo Health app sends. See [docs/CAPTURE_WORKFLOW.md](docs/CAPTURE_WORKFLOW.md). |
| **Protocol Database** | Observations (what was seen) and hypotheses (what it might mean), kept firmly apart. |
| **Developer** | Raw BLE log, packet inspector, and a one-tap export of every piece of research data. |

## What it deliberately does not do

No watch-face installation. No device commands. No `decodePacket()`, no
`encodePacket()`, no protocol constants. Those arrive only once a hypothesis in
the protocol database reaches `SUPPORTED` on real captured evidence.

---

## Running it

Requires the Flutter SDK (built against **3.47.4**, Dart 3.13.3) and the
Android SDK. Android is the development target; iOS is configured but untested.

```bash
flutter pub get
flutter analyze --fatal-infos   # expect: no issues
flutter test                    # expect: all pass
flutter run                     # on a physical Android device

# A small, sideloadable APK (signed with the debug key):
flutter build apk --release --split-per-abi
# -> build/app/outputs/flutter-apk/app-arm64-v8a-release.apk  (~18 MB)
```

Install it with `adb install -r app-arm64-v8a-release.apk`, or copy it to the
phone and open it. Most modern phones are `arm64-v8a`.

The release build requests only the Bluetooth permissions and, on Android 11
and below, location — **no INTERNET permission**. Captured evidence cannot
leave the phone except through an export you perform yourself.

**A physical Android phone is required.** An emulator has no Bluetooth radio
that can reach a real peripheral, so scanning will find nothing in one.

If the watch does not appear in the scan, it is probably already connected to
Oraimo Health — a connected BLE peripheral usually stops advertising.
Disconnect it there first.

---

## Architecture

```
Flutter UI  (presentation/screens, presentation/widgets)
      |
Feature controllers  (features/*)
      |
BLE transport  (core/bluetooth)          Evidence store  (core/storage)
      |                                          |
flutter_blue_plus                           SQLite + JSON export
```

The load-bearing rule is the separation between **moving bytes** and
**interpreting bytes**.

- `core/bluetooth/` moves bytes. It contains no UUID constants, no packet
  construction, and no mention of Oraimo anywhere in it. `BleTransport` is an
  interface, which is what lets the connection logic be tested without a radio.
- `InstrumentedBleTransport` is a decorator that publishes one event per
  operation to `BleEventBus`. Recording lives there rather than at call sites,
  so no future edit can quietly stop an operation being recorded, and failures
  are recorded as packets before the exception is rethrown.
- `features/import/btsnoop/` is pure Dart with no Flutter dependency, which is
  why it can be tested exhaustively against byte-level fixtures.
- Interpretation lives only in `ProtocolObservation` and `ProtocolHypothesis`,
  which cite the packet rows they rest on.

### Layout

```
lib/
  core/
    bluetooth/      transport interface, plugin adapter, instrumentation
    logging/        app log, BLE event bus
    storage/        SQLite schema, repository, JSON export
    models/         packets, sessions, devices, GATT, protocol records
    hex/            hex codec
  features/
    device_scan/        device_connection/    capture/
    import/btsnoop/     protocol/
  presentation/
    screens/  widgets/
```

Two deliberate departures from the original plan's folder list: the spec's
`services/` and `characteristics/` are one screen (`gatt_explorer`), and
`watch_data/` does not exist, because there is no known way to read watch data
and the folder would imply otherwise.

---

## Engineering rules

These are enforced in code and in tests, not just asserted here.

1. **Do not hard-code unknown UUIDs.** The scan is unfiltered; a device becomes
   "the watch" only when you star it.
2. **Do not invent packet formats.** There is no encoder.
3. **Do not claim a characteristic's purpose without evidence.** An
   unidentified attribute shows its handle and a null UUID.
4. **Keep raw packets unchanged.** Payloads are stored as hex, byte for byte.
5. **Always preserve timestamps.** Every packet carries both UTC wall-clock
   time at microsecond precision and a monotonic offset from session start.
6. **Store packets in hexadecimal.**
7. **Separate transport from protocol interpretation.**
8. **Make every experiment reproducible.** Sessions record the device, the
   times, your own notes, and whether the evidence is ours or the official
   app's.
9. **Log errors instead of silently handling them.** A failed operation becomes
   a packet with the platform's verbatim error text.
10. **Keep the architecture extensible.** A protocol layer can sit on top of
    the transport without either one changing.

---

## Tests

```
flutter test
```

156 tests. The ones that matter most:

- **btsnoop parsing** against byte-level fixtures built to the spec, not mocks:
  header validation, epoch conversion, L2CAP reassembly across ACL fragments,
  interleaved traffic from two devices, and the rule that a handle stays
  unresolved unless the capture itself identified it.
- **Export schema**, pinned by a golden test, because captures recorded by an
  older build have to stay readable.
- **Connection state machine**, driven by a fake transport: backoff growth, the
  give-up path, and not retrying into a switched-off radio.

---

## Licensing note

`flutter_blue_plus` 2.x is **not** BSD licensed. It requires callers to declare
a licence tier, and for-profit use needs a paid commercial licence. This project
declares the nonprofit tier — see the comment in
`lib/core/bluetooth/flutter_blue_plus_transport.dart`. Anyone shipping a
commercial build from this code must change that and buy the commercial licence.

---

## Further reading

- [docs/CAPTURE_WORKFLOW.md](docs/CAPTURE_WORKFLOW.md) — how to capture what
  Oraimo Health actually sends, including the watch-face experiment.
- [docs/APK_ANALYSIS.md](docs/APK_ANALYSIS.md) — static analysis of the
  official app.
- [docs/PROTOCOL_STATUS.md](docs/PROTOCOL_STATUS.md) — the evidence ledger.

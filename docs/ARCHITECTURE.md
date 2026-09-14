# Architecture

The design problem this project has is not complexity — it is discipline.
The whole app exists to gather trustworthy evidence about an unknown protocol,
and the easiest way to ruin that is for a guess to end up looking like a fact.
Almost every structural decision below is aimed at that.

## The one boundary that matters

```
                    ┌──────────────────────────────┐
  presentation/ ───▶│  features/*  (controllers)   │
                    └──────────────┬───────────────┘
                                   │
        ┌──────────────────────────┴────────────────────┐
        ▼                                               ▼
┌───────────────────────┐                   ┌───────────────────────┐
│  core/bluetooth       │                   │  core/storage         │
│  moves bytes          │                   │  records evidence     │
│  interprets nothing   │                   │  never rewrites it    │
└───────────┬───────────┘                   └───────────────────────┘
            │                                           ▲
            │  every operation                          │
            └──────────▶ core/logging/BleEventBus ──────┘
```

`core/bluetooth/` contains no UUID constants, no packet construction, no
framing, and no reference to Oraimo or the Watch 6R. That is checkable, and it
is checked by reading it: if a protocol constant ever appears in that
directory, the boundary has been broken.

Interpretation has exactly one home: `ProtocolObservation` and
`ProtocolHypothesis`, which are data, cite their evidence, and carry a
confidence and a status. There is no code path that turns a hypothesis into
behaviour.

## Why instrumentation is a decorator

`InstrumentedBleTransport` wraps a `BleTransport` and publishes one event per
operation to `BleEventBus`.

The alternative — emitting events from the plugin adapter, or from the UI —
was rejected for two reasons. Emitting from call sites means a code path nobody
exercised is a code path that silently records nothing. And putting it inside
the plugin adapter would make recording untestable without a radio.

As a decorator it is neither: the fake transport used in tests goes through
exactly the same instrumentation the real one does, so the recording behaviour
is covered by tests that never touch Bluetooth.

## Why a read produces two packets

`readCharacteristic` emits a `read_request` going out and a `read_response`
coming back, even though the plugin exposes it as a single call returning a
value.

This is so that a session recorded live has the same shape as a session
imported from an HCI capture, where the request and the response genuinely are
two separate ATT packets. Comparing our own traffic against the official app's
is the core activity of this project, and it would be needlessly hard if the
two sources described the same exchange differently.

## Why failures are packets

A write the watch rejects is not an error to be handled and forgotten — it is
information about the protocol. `GATT_WRITE_NOT_PERMITTED` on a characteristic
tells you something real.

So every failure emits a packet carrying the platform's verbatim error text,
with the payload that failed, before the exception is rethrown to the caller.
The caller still sees the failure; so does the evidence record.

## Why every packet has two clocks

`timestamp` is UTC wall-clock at microsecond precision. `elapsedUs` is a
monotonic offset from the start of the session.

Wall-clock time can jump — an NTP correction or a timezone change mid-capture
would corrupt any measurement of inter-packet timing. And inter-packet timing
is exactly what you need when working out whether a transfer is acknowledged
per fragment, how large a window is, or where a timeout sits. Keeping both
means neither question is foreclosed.

## Why the btsnoop importer exists at all

Phase 7 of the original plan assumed this app could watch Oraimo Health work.
It cannot: Android does not let one app observe another's GATT traffic.

The phone's own Bluetooth stack can, and writes it to `btsnoop_hci.log`. So
the importer is not a convenience feature — it is the only route to the
official app's behaviour, and therefore the only route to the watch-face
protocol.

Two parts of it are load-bearing:

**L2CAP reassembly.** A watch-face image is far larger than the ATT MTU and
arrives as many ACL fragments. Treating each fragment as a packet would shred
payloads and manufacture boundaries that do not exist in the protocol —
precisely the kind of artefact that would send analysis down a wrong path for
days.

**Evidence-based handle resolution.** An attribute handle becomes a UUID only
if the same capture contains the discovery response that says so. If it does
not, the UUID stays null and the handle is reported as unresolved. The same
rule governs whether a descriptor write counts as "enable notifications": with
no discovered CCCD, it stays an ordinary descriptor write.

There is one deliberate deviation from correctness, documented at
`kBtsnoopEpochDeltaUs`: the epoch constant matches Android's and Wireshark's,
which is twelve days from the true interval since 0000-01-01. Interoperating
with the tools that produced the file matters more than agreeing with the
calendar.

## Storage

SQLite via `sqflite`. Packets are append-only: the only writes to the packets
table are inserts and whole-session deletes. Payloads are stored as hex text,
never as blobs that might be re-encoded on the way through.

The recorder batches inserts on a timer, because BLE events during a bulk
transfer arrive faster than individual inserts complete, and a dropped packet
during a watch-face transfer is exactly the evidence the capture existed to
collect. A failed batch is put back on the queue and logged rather than lost.

## Testing strategy

The fake transport covers the connection state machine, the instrumentation and
the recorder without hardware. The btsnoop layers are pure Dart with no Flutter
dependency, tested against fixtures assembled byte by byte to the specification
— a builder, not a mock, so a disagreement between builder and parser is a real
bug in one of them rather than a shared assumption.

The export schema has a golden test. Captures recorded by an older build must
stay readable, so the schema is append-only and a rename should fail loudly.

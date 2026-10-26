# Protocol status

**Last updated:** before the first contact with the real watch. Investigation
plans are in [INVESTIGATIONS.md](INVESTIGATIONS.md).

## What is known about the Oraimo Watch 6R (OSW-823) protocol

Nothing.

That is the honest state of this document and it should stay this way until
evidence changes it. Specifically, we do not know:

- [ ] Which BLE services the watch exposes
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

*(none yet)*

## Open hypotheses

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

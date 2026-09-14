/// Canonical handling of Bluetooth UUIDs.
///
/// The same characteristic can surface as `2a19`, `0x2A19` or
/// `00002a19-0000-1000-8000-00805f9b34fb` depending on whether it came from
/// flutter_blue_plus, an ATT discovery response in an HCI capture, or a human
/// typing into a filter box. Comparing evidence across those sources is the
/// whole point of this app, so every UUID is normalised to one form on the way
/// in and rendered in the shortest unambiguous form on the way out.
///
/// This is pure Bluetooth-spec plumbing. It encodes nothing about the Watch 6R.
library;

/// The Bluetooth Base UUID: 16- and 32-bit UUIDs are shorthand for a 128-bit
/// UUID built by substituting them into the first field of this value.
/// (Bluetooth Core Specification, Vol 3, Part B, section 2.5.1.)
const String bluetoothBaseUuidSuffix = '-0000-1000-8000-00805f9b34fb';

class BleUuid implements Comparable<BleUuid> {
  const BleUuid._(this.canonical);

  /// Full 128-bit lowercase dashed form, e.g.
  /// `00002a19-0000-1000-8000-00805f9b34fb`. Always this form, so that string
  /// equality on [canonical] is UUID equality.
  final String canonical;

  /// Parses any of the accepted spellings.
  ///
  /// Throws [FormatException] on input that is not a UUID. Returning a
  /// placeholder instead would let a malformed UUID travel into stored
  /// evidence, which rule 3 forbids.
  factory BleUuid.parse(String input) {
    final uuid = BleUuid.tryParse(input);
    if (uuid == null) {
      throw FormatException('not a Bluetooth UUID', input);
    }
    return uuid;
  }

  /// Like [BleUuid.parse] but returns null instead of throwing.
  static BleUuid? tryParse(String input) {
    var s = input.trim().toLowerCase();
    if (s.startsWith('0x')) s = s.substring(2);
    s = s.replaceAll('-', '');
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(s)) return null;

    switch (s.length) {
      case 4: // 16-bit short form
        return BleUuid._('0000$s$bluetoothBaseUuidSuffix');
      case 8: // 32-bit short form
        return BleUuid._('$s$bluetoothBaseUuidSuffix');
      case 32: // full 128-bit
        return BleUuid._(
          '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
          '-${s.substring(16, 20)}-${s.substring(20)}',
        );
      default:
        return null;
    }
  }

  /// Builds a UUID from a 16-bit assigned number as it appears on the wire.
  factory BleUuid.from16(int value) =>
      BleUuid._('0000${(value & 0xFFFF).toRadixString(16).padLeft(4, '0')}'
          '$bluetoothBaseUuidSuffix');

  /// Builds a UUID from a 32-bit assigned number as it appears on the wire.
  factory BleUuid.from32(int value) =>
      BleUuid._('${(value & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}'
          '$bluetoothBaseUuidSuffix');

  /// True when this UUID is inside the Bluetooth Base UUID range, i.e. it has
  /// a 16- or 32-bit short form. SIG-assigned UUIDs live here; the vendor
  /// UUIDs a proprietary watch uses typically do not.
  bool get isShortForm => canonical.endsWith(bluetoothBaseUuidSuffix);

  /// The shortest unambiguous spelling, for display only. Never store this —
  /// store [canonical].
  String get short {
    if (!isShortForm) return canonical;
    final first = canonical.substring(0, 8);
    if (first.startsWith('0000')) return first.substring(4);
    return first;
  }

  @override
  String toString() => canonical;

  @override
  bool operator ==(Object other) => other is BleUuid && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  int compareTo(BleUuid other) => canonical.compareTo(other.canonical);
}

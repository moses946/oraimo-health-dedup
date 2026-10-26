/// Names for Bluetooth SIG assigned numbers.
///
/// These come from the public Bluetooth SIG "Assigned Numbers" document, not
/// from anything about the Watch 6R. Naming `0x2A26` "Firmware Revision String"
/// is reading a published standard; it says nothing about what the watch does
/// with it. That is the line rule 3 draws, and this file stays on the right
/// side of it:
///
/// * Only SIG-defined services, characteristics and descriptors are named.
/// * Vendor (128-bit) UUIDs are never named — they return null.
/// * 16-bit UUIDs the SIG allocated to member *companies* are deliberately not
///   named either, even though the allocation list is public. Knowing which
///   company holds a UUID says nothing about what its bytes mean, and a
///   company name in the explorer would read like an identification.
///
/// Display only. Stored evidence always holds the canonical UUID.
library;

import 'ble_uuid.dart';

enum SigKind { service, characteristic, descriptor }

class SigName {
  const SigName(this.name, this.kind);

  final String name;
  final SigKind kind;
}

const Map<int, SigName> _sig = {
  // Services
  0x1800: SigName('Generic Access', SigKind.service),
  0x1801: SigName('Generic Attribute', SigKind.service),
  0x1802: SigName('Immediate Alert', SigKind.service),
  0x1803: SigName('Link Loss', SigKind.service),
  0x1804: SigName('Tx Power', SigKind.service),
  0x1805: SigName('Current Time', SigKind.service),
  0x180A: SigName('Device Information', SigKind.service),
  0x180D: SigName('Heart Rate', SigKind.service),
  0x180F: SigName('Battery', SigKind.service),
  0x1811: SigName('Alert Notification', SigKind.service),
  0x1812: SigName('Human Interface Device', SigKind.service),

  // Characteristics
  0x2A00: SigName('Device Name', SigKind.characteristic),
  0x2A01: SigName('Appearance', SigKind.characteristic),
  0x2A04: SigName('Peripheral Preferred Connection Parameters',
      SigKind.characteristic),
  0x2A05: SigName('Service Changed', SigKind.characteristic),
  0x2A06: SigName('Alert Level', SigKind.characteristic),
  0x2A07: SigName('Tx Power Level', SigKind.characteristic),
  0x2A08: SigName('Date Time', SigKind.characteristic),
  0x2A19: SigName('Battery Level', SigKind.characteristic),
  0x2A23: SigName('System ID', SigKind.characteristic),
  0x2A24: SigName('Model Number String', SigKind.characteristic),
  0x2A25: SigName('Serial Number String', SigKind.characteristic),
  0x2A26: SigName('Firmware Revision String', SigKind.characteristic),
  0x2A27: SigName('Hardware Revision String', SigKind.characteristic),
  0x2A28: SigName('Software Revision String', SigKind.characteristic),
  0x2A29: SigName('Manufacturer Name String', SigKind.characteristic),
  0x2A2B: SigName('Current Time', SigKind.characteristic),
  0x2A37: SigName('Heart Rate Measurement', SigKind.characteristic),
  0x2A38: SigName('Body Sensor Location', SigKind.characteristic),
  0x2A39: SigName('Heart Rate Control Point', SigKind.characteristic),
  0x2A50: SigName('PnP ID', SigKind.characteristic),

  // Descriptors
  0x2900: SigName('Characteristic Extended Properties', SigKind.descriptor),
  0x2901: SigName('Characteristic User Description', SigKind.descriptor),
  0x2902: SigName('Client Characteristic Configuration', SigKind.descriptor),
  0x2903: SigName('Server Characteristic Configuration', SigKind.descriptor),
  0x2904: SigName('Characteristic Presentation Format', SigKind.descriptor),
};

/// The SIG name for [uuid] in any spelling, or null when it is not a
/// SIG-defined attribute. Null is the honest answer for every vendor UUID.
SigName? sigNameFor(String uuid) {
  final parsed = BleUuid.tryParse(uuid);
  if (parsed == null || !parsed.isShortForm) return null;
  final first = parsed.canonical.substring(0, 8);
  // Only 16-bit values (0000xxxx) are SIG-defined attribute types here.
  if (!first.startsWith('0000')) return null;
  return _sig[int.parse(first.substring(4), radix: 16)];
}

/// A display label: the SIG name if there is one, otherwise a plain statement
/// that the attribute is not identified.
String sigLabelFor(String uuid) =>
    sigNameFor(uuid)?.name ?? 'unidentified (not a SIG attribute)';

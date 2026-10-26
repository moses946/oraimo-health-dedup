import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/sig_assigned_numbers.dart';

void main() {
  test('names a SIG characteristic in every spelling', () {
    for (final spelling in [
      '2a26',
      '0x2A26',
      '00002a26-0000-1000-8000-00805f9b34fb',
      '00002A26-0000-1000-8000-00805F9B34FB',
    ]) {
      expect(sigNameFor(spelling)?.name, 'Firmware Revision String',
          reason: spelling);
    }
  });

  test('classifies services, characteristics and descriptors', () {
    expect(sigNameFor('180a')!.kind, SigKind.service);
    expect(sigNameFor('2a19')!.kind, SigKind.characteristic);
    expect(sigNameFor('2902')!.kind, SigKind.descriptor);
    expect(sigNameFor('2902')!.name, 'Client Characteristic Configuration');
  });

  test('never names a vendor UUID', () {
    // The whole point: a 128-bit vendor UUID is unidentified, full stop.
    expect(sigNameFor('6e400001-b5a3-f393-e0a9-e50e24dcca9e'), isNull);
    expect(sigLabelFor('6e400001-b5a3-f393-e0a9-e50e24dcca9e'),
        startsWith('unidentified'));
  });

  test('does not name company-allocated 16-bit UUIDs', () {
    // 0xFExx values are allocated to SIG member companies. Who holds one says
    // nothing about what its bytes mean, so they are left unnamed.
    expect(sigNameFor('fee7'), isNull);
    expect(sigNameFor('fee0'), isNull);
  });

  test('does not name 32-bit short forms', () {
    expect(sigNameFor('12342a26'), isNull);
  });

  test('tolerates garbage without throwing', () {
    expect(sigNameFor('not a uuid'), isNull);
    expect(sigNameFor(''), isNull);
  });
}

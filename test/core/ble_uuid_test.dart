import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_uuid.dart';

void main() {
  group('BleUuid.parse', () {
    test('expands a 16-bit short form using the Bluetooth Base UUID', () {
      expect(BleUuid.parse('2a19').canonical,
          '00002a19-0000-1000-8000-00805f9b34fb');
    });

    test('expands a 32-bit short form', () {
      expect(BleUuid.parse('12345678').canonical,
          '12345678-0000-1000-8000-00805f9b34fb');
    });

    test('accepts a full 128-bit form with or without dashes', () {
      const dashed = '0000fee7-0000-1000-8000-00805f9b34fb';
      expect(BleUuid.parse(dashed).canonical, dashed);
      expect(BleUuid.parse(dashed.replaceAll('-', '')).canonical, dashed);
    });

    test('every spelling of the same UUID compares equal', () {
      final spellings = [
        '2a19',
        '0x2A19',
        '00002a19-0000-1000-8000-00805f9b34fb',
        '00002A19-0000-1000-8000-00805F9B34FB',
        '00002a190000100080000080 5f9b34fb'.replaceAll(' ', ''),
      ].map(BleUuid.parse).toSet();
      expect(spellings, hasLength(1));
    });

    test('throws on input that is not a UUID', () {
      for (final bad in ['', 'zz', '2a1', 'not-a-uuid', '00002a19-0000']) {
        expect(() => BleUuid.parse(bad), throwsFormatException,
            reason: 'input: $bad');
      }
    });
  });

  test('tryParse returns null instead of throwing', () {
    expect(BleUuid.tryParse('nope'), isNull);
    expect(BleUuid.tryParse('2a19'), isNotNull);
  });

  group('from16 / from32', () {
    test('build the same value as parsing the short form', () {
      expect(BleUuid.from16(0x2a19), BleUuid.parse('2a19'));
      expect(BleUuid.from32(0x12345678), BleUuid.parse('12345678'));
    });

    test('pad small values', () {
      expect(BleUuid.from16(0x1).canonical,
          '00000001-0000-1000-8000-00805f9b34fb');
    });
  });

  group('short form detection', () {
    test('a SIG UUID reports its short spelling', () {
      final uuid = BleUuid.parse('2a19');
      expect(uuid.isShortForm, isTrue);
      expect(uuid.short, '2a19');
    });

    test('a vendor UUID keeps its full spelling', () {
      final uuid = BleUuid.parse('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
      expect(uuid.isShortForm, isFalse);
      expect(uuid.short, '6e400001-b5a3-f393-e0a9-e50e24dcca9e');
    });
  });
}

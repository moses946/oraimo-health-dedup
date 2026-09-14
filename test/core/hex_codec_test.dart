import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/hex/hex_codec.dart';

void main() {
  group('bytesToHex', () {
    test('produces compact uppercase storage form', () {
      expect(bytesToHex([0xAA, 0x01, 0x04, 0x00, 0x7F]), 'AA0104007F');
    });

    test('pads single-digit bytes', () {
      expect(bytesToHex([0x00, 0x0F, 0xF0]), '000FF0');
    });

    test('empty input yields empty string', () {
      expect(bytesToHex([]), '');
    });
  });

  group('bytesToHexDisplay', () {
    test('groups bytes with spaces', () {
      expect(bytesToHexDisplay([0xAA, 0x01, 0x04, 0x00, 0x7F]),
          'AA 01 04 00 7F');
    });
  });

  group('hexToBytes', () {
    test('round-trips through the storage form', () {
      const original = [0x00, 0x42, 0xFF, 0xAA, 0x01];
      expect(hexToBytes(bytesToHex(original)), original);
    });

    test('accepts the spacing and casing a human would type', () {
      const expected = [0xAA, 0x01, 0x04];
      for (final input in [
        'AA0104',
        'aa0104',
        'AA 01 04',
        'aa:01:04',
        'AA-01-04',
        '0xAA 0x01 0x04',
        'AA,01,04',
        ' AA\n01\t04 ',
      ]) {
        expect(hexToBytes(input), expected, reason: 'input: $input');
      }
    });

    test('rejects an odd number of digits rather than guessing', () {
      expect(() => hexToBytes('AAB'), throwsA(isA<HexFormatException>()));
    });

    test('rejects non-hex characters and reports where', () {
      expect(
        () => hexToBytes('AAZZ'),
        throwsA(isA<HexFormatException>()
            .having((e) => e.offset, 'offset', 2)),
      );
    });

    test('empty input is an empty payload, not an error', () {
      expect(hexToBytes(''), isEmpty);
      expect(hexToBytes('   '), isEmpty);
    });
  });

  group('isValidHex', () {
    test('never throws', () {
      expect(isValidHex('AA01'), isTrue);
      expect(isValidHex('nonsense'), isFalse);
      expect(isValidHex('AAB'), isFalse);
    });
  });

  group('bytesToAscii', () {
    test('substitutes for non-printable bytes', () {
      expect(bytesToAscii([0x48, 0x69, 0x00, 0xFF, 0x21]), 'Hi..!');
    });

    test('keeps the full printable range', () {
      expect(bytesToAscii([0x20, 0x7E]), ' ~');
    });
  });

  group('hexDump', () {
    test('renders offset, hex columns and ascii sidebar', () {
      final dump = hexDump(List<int>.generate(18, (i) => 0x41 + i));
      final lines = dump.split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, startsWith('00000000  41 42 43'));
      expect(lines.first, endsWith('|ABCDEFGHIJKLMNOP|'));
      expect(lines.last, startsWith('00000010  51 52'));
      expect(lines.last, endsWith('|QR|'));
    });

    test('empty input yields empty output', () {
      expect(hexDump([]), '');
    });
  });
}

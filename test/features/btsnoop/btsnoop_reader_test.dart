import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/features/import/btsnoop/btsnoop_reader.dart';

import '../../support/btsnoop_builder.dart';

void main() {
  group('file header', () {
    test('rejects a file without the btsnoop identification pattern', () {
      final notBtsnoop = Uint8List.fromList(List.filled(64, 0x50));
      expect(
        () => BtsnoopReader(notBtsnoop),
        throwsA(isA<BtsnoopFormatException>().having(
          (e) => e.message,
          'message',
          contains('not a btsnoop file'),
        )),
      );
    });

    test('the rejection points at the bugreport mistake people actually make',
        () {
      // A zip starts "PK\x03\x04" — exactly what you get by grabbing the
      // bugreport archive instead of the log inside it.
      final zip = Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, ...List.filled(60, 0)]);
      expect(
        () => BtsnoopReader(zip),
        throwsA(isA<BtsnoopFormatException>()
            .having((e) => e.message, 'message', contains('bugreport'))),
      );
    });

    test('rejects a file too short to hold a header', () {
      expect(
        () => BtsnoopReader(Uint8List.fromList([0x62, 0x74])),
        throwsA(isA<BtsnoopFormatException>()
            .having((e) => e.message, 'message', contains('too short'))),
      );
    });

    test('rejects an unsupported version', () {
      final bytes = (BtsnoopBuilder(version: 2)).build();
      expect(
        () => BtsnoopReader(bytes),
        throwsA(isA<BtsnoopFormatException>()
            .having((e) => e.message, 'message', contains('version 2'))),
      );
    });

    test('rejects a datalink type whose framing we do not know', () {
      final bytes = BtsnoopBuilder(datalinkType: kDatalinkH5).build();
      expect(
        () => BtsnoopReader(bytes),
        throwsA(isA<BtsnoopFormatException>()
            .having((e) => e.message, 'message', contains('three-wire'))),
      );
    });

    test('accepts the H4 datalink Android writes', () {
      final reader = BtsnoopReader(BtsnoopBuilder().build());
      expect(reader.header.version, 1);
      expect(reader.header.datalinkType, kDatalinkH4);
      expect(reader.records(), isEmpty);
    });
  });

  group('timestamps', () {
    test('round-trip through the btsnoop epoch', () {
      final original = DateTime.utc(2026, 3, 1, 21, 43, 12, 241, 500);
      expect(timestampFromBtsnoop(btsnoopTimestampFrom(original)), original);
    });

    test('use the delta Android writes, not the arithmetically correct one', () {
      // Android's stack adds 0x00dcddb30f2f8000 and Wireshark subtracts it.
      // The true proleptic Gregorian interval is 62167219200000000 us, twelve
      // days less. Matching the ecosystem matters more than matching the
      // calendar: if this ever changes, imported captures stop lining up with
      // what Wireshark shows for the same file.
      expect(kBtsnoopEpochDeltaUs, 0x00dcddb30f2f8000);
      expect(kBtsnoopEpochDeltaUs - 62167219200000000,
          const Duration(days: 12).inMicroseconds);
    });

    test('a known raw value decodes to the expected wall-clock time', () {
      final when = DateTime.utc(2026, 3, 1, 21, 43, 12);
      final builder = BtsnoopBuilder()
        ..addRecord(data: Uint8List.fromList([0x04, 0x05]), timestamp: when);
      final record = BtsnoopReader(builder.build()).records().single;
      expect(record.timestamp, when);
      expect(record.timestamp.isUtc, isTrue);
    });

    test('microsecond precision survives', () {
      final when = DateTime.utc(2026, 3, 1, 21, 43, 12, 0, 7);
      final builder = BtsnoopBuilder()
        ..addRecord(data: Uint8List.fromList([0x04]), timestamp: when);
      expect(BtsnoopReader(builder.build()).records().single.timestamp, when);
    });
  });

  group('records', () {
    test('direction comes from the flags', () {
      final t = DateTime.utc(2026, 3, 1);
      final builder = BtsnoopBuilder()
        ..addRecord(data: Uint8List.fromList([0x02]), timestamp: t, sent: true)
        ..addRecord(data: Uint8List.fromList([0x02]), timestamp: t, sent: false);

      final records = BtsnoopReader(builder.build()).records().toList();
      expect(records[0].isReceived, isFalse, reason: 'phone -> watch');
      expect(records[1].isReceived, isTrue, reason: 'watch -> phone');
    });

    test('payload bytes come back exactly as written', () {
      final data = Uint8List.fromList([0x02, 0x40, 0x20, 0xFF, 0x00, 0x7F]);
      final builder = BtsnoopBuilder()
        ..addRecord(data: data, timestamp: DateTime.utc(2026, 3, 1));
      expect(BtsnoopReader(builder.build()).records().single.data, data);
    });

    test('a truncated record is flagged, not silently used', () {
      final builder = BtsnoopBuilder()
        ..addRecord(
          data: Uint8List.fromList([0x02, 0x40]),
          timestamp: DateTime.utc(2026, 3, 1),
          originalLengthOverride: 64,
        );
      final record = BtsnoopReader(builder.build()).records().single;
      expect(record.isTruncated, isTrue);
      expect(record.originalLength, 64);
      expect(record.includedLength, 2);
    });

    test('dropped-packet counts are preserved', () {
      final builder = BtsnoopBuilder()
        ..addRecord(
          data: Uint8List.fromList([0x02]),
          timestamp: DateTime.utc(2026, 3, 1),
          cumulativeDrops: 17,
        );
      expect(BtsnoopReader(builder.build()).records().single.cumulativeDrops, 17);
    });

    test('many records are read in order', () {
      final builder = BtsnoopBuilder();
      for (var i = 0; i < 100; i++) {
        builder.addRecord(
          data: Uint8List.fromList([0x02, i]),
          timestamp: DateTime.utc(2026, 3, 1).add(Duration(milliseconds: i)),
        );
      }
      final records = BtsnoopReader(builder.build()).records().toList();
      expect(records, hasLength(100));
      expect(records.map((r) => r.data[1]), List.generate(100, (i) => i));
    });

    test('a file cut off mid-record fails loudly rather than half-parsing', () {
      final builder = BtsnoopBuilder()
        ..addRecord(
          data: Uint8List.fromList(List.filled(32, 0xAB)),
          timestamp: DateTime.utc(2026, 3, 1),
        );
      final full = builder.build();
      final cut = Uint8List.sublistView(full, 0, full.length - 10);

      expect(
        () => BtsnoopReader(cut).records().toList(),
        throwsA(isA<BtsnoopFormatException>()
            .having((e) => e.message, 'message', contains('remain'))),
      );
    });
  });
}

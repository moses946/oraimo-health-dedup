import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/presentation/widgets/hex_view.dart';
import 'package:oraimo_lab/presentation/widgets/packet_tile.dart';

/// Widget-level checks on the two things the operator actually reads: the hex
/// view and a packet row. Both must show the bytes faithfully and must not
/// present an unknown attribute as if it were known.
void main() {
  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));

  group('HexView', () {
    testWidgets('renders bytes grouped, with an ASCII sidebar', (tester) async {
      await tester.pumpWidget(wrap(const HexView(payloadHex: '48690021')));
      expect(find.text('48 69 00 21'), findsOneWidget);
      expect(find.text('Hi.!'), findsOneWidget);
    });

    testWidgets('an empty payload says so rather than showing nothing',
        (tester) async {
      await tester.pumpWidget(wrap(const HexView(payloadHex: '')));
      expect(find.text('(no payload)'), findsOneWidget);
    });

    testWidgets('dump mode shows offsets', (tester) async {
      await tester.pumpWidget(
          wrap(const HexView(payloadHex: 'AA0104007F', showDump: true)));
      expect(find.textContaining('00000000'), findsOneWidget);
      expect(find.textContaining('AA 01 04 00 7F'), findsOneWidget);
    });
  });

  group('PacketTile', () {
    BlePacket packet({
      String? characteristic,
      int? handle,
      PacketStatus status = PacketStatus.ok,
      String? error,
      String payload = 'AA0104007F',
      PacketDirection direction = PacketDirection.phoneToWatch,
    }) =>
        BlePacket(
          sessionId: 's1',
          seq: 0,
          timestamp: DateTime.utc(2026, 3, 1, 21, 43, 12, 241),
          elapsedUs: 0,
          direction: direction,
          operation: PacketOperation.write,
          payloadHex: payload,
          characteristicUuid: characteristic,
          attHandle: handle,
          status: status,
          error: error,
        );

    testWidgets('shows time, operation, direction and payload', (tester) async {
      await tester.pumpWidget(wrap(PacketTile(
          packet: packet(characteristic: '0000fee1-0000-1000-8000-00805f9b34fb'))));

      expect(find.text('WRITE'), findsOneWidget);
      expect(find.textContaining('PHONE → WATCH'), findsOneWidget);
      expect(find.text('AA 01 04 00 7F'), findsOneWidget);
      expect(find.text('5 B'), findsOneWidget);
    });

    testWidgets('an unidentified attribute is labelled by handle, not guessed',
        (tester) async {
      await tester
          .pumpWidget(wrap(PacketTile(packet: packet(handle: 0x002b))));
      expect(find.textContaining('handle 0x002b'), findsOneWidget);
    });

    testWidgets('an attribute with neither uuid nor handle shows a dash',
        (tester) async {
      await tester.pumpWidget(wrap(PacketTile(packet: packet())));
      expect(find.textContaining('—'), findsOneWidget);
    });

    testWidgets('a failed packet shows its error text verbatim',
        (tester) async {
      await tester.pumpWidget(wrap(PacketTile(
        packet: packet(
          status: PacketStatus.failed,
          error: 'GATT_WRITE_NOT_PERMITTED (status 3)',
        ),
      )));
      expect(find.textContaining('GATT_WRITE_NOT_PERMITTED (status 3)'),
          findsOneWidget);
    });

    testWidgets('expanding reveals the full detail without interpretation',
        (tester) async {
      await tester.pumpWidget(wrap(PacketTile(packet: packet(handle: 0x002b))));
      await tester.tap(find.text('WRITE'));
      await tester.pumpAndSettle();

      expect(find.text('unknown'), findsNWidgets(2)); // service + characteristic
      expect(find.text('0x002b'), findsOneWidget);
      expect(find.text('5 bytes'), findsOneWidget);
    });
  });

  group('formatPacketTime', () {
    test('renders to millisecond resolution', () {
      final time = DateTime(2026, 3, 1, 21, 43, 12, 241);
      expect(formatPacketTime(time), '21:43:12.241');
    });

    test('pads single-digit components', () {
      expect(formatPacketTime(DateTime(2026, 3, 1, 9, 5, 3, 7)),
          '09:05:03.007');
    });
  });
}

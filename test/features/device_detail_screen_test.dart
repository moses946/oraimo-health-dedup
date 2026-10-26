import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/bluetooth/instrumented_ble_transport.dart';
import 'package:oraimo_lab/core/logging/ble_event_bus.dart';
import 'package:oraimo_lab/core/models/ble_device_record.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/gatt_models.dart';
import 'package:oraimo_lab/core/providers.dart';
import 'package:oraimo_lab/presentation/screens/device_detail_screen.dart';

import '../support/fake_ble_transport.dart';

const String deviceInfo = '0000180a-0000-1000-8000-00805f9b34fb';
const String firmware = '00002a26-0000-1000-8000-00805f9b34fb';
const String vendorSvc = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String vendorNotify = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

void main() {
  late FakeBleTransport fake;
  late BleEventBus bus;

  setUp(() {
    fake = FakeBleTransport()
      ..services = const [
        GattService(uuid: deviceInfo, characteristics: [
          GattCharacteristic(
            uuid: firmware,
            serviceUuid: deviceInfo,
            properties: GattProperties(read: true),
          ),
        ]),
        GattService(uuid: vendorSvc, characteristics: [
          GattCharacteristic(
            uuid: vendorNotify,
            serviceUuid: vendorSvc,
            properties: GattProperties(notify: true),
          ),
        ]),
      ]
      ..readValues[firmware] = Uint8List.fromList('V1.0.8'.codeUnits);
    bus = BleEventBus();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        eventBusProvider.overrideWithValue(bus),
        transportProvider.overrideWithValue(InstrumentedBleTransport(fake, bus)),
      ],
      child: MaterialApp(
        home: DeviceDetailScreen(
          device: BleDeviceRecord(
            address: 'AA:BB:CC:DD:EE:FF',
            name: 'Watch 6R',
            firstSeenAt: DateTime.utc(2026),
            lastSeenAt: DateTime.utc(2026),
            lastRssi: -60,
          ),
        ),
      ),
    ));
  }

  Future<void> connectAndDiscover(WidgetTester tester) async {
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();
  }

  testWidgets('sweep buttons appear only once services are discovered',
      (tester) async {
    await pumpScreen(tester);
    expect(find.text('Read all'), findsNothing);

    await connectAndDiscover(tester);
    expect(find.text('Read all'), findsOneWidget);
    expect(find.text('Subscribe all'), findsOneWidget);
  });

  testWidgets('SIG attributes are named and vendor ones are not',
      (tester) async {
    await pumpScreen(tester);
    await connectAndDiscover(tester);

    expect(find.textContaining('Device Information'), findsOneWidget);
    expect(find.text('Firmware Revision String'), findsOneWidget);
    expect(find.textContaining('unidentified'), findsWidgets,
        reason: 'the vendor service and characteristic stay unidentified');
  });

  testWidgets('Read all reads the firmware revision and reports it',
      (tester) async {
    await pumpScreen(tester);
    await connectAndDiscover(tester);

    await tester.tap(find.text('Read all'));
    await tester.pumpAndSettle();

    expect(find.text('Read 1 of 1'), findsOneWidget);
    final response = bus.recent
        .lastWhere((p) => p.operation == PacketOperation.readResponse);
    expect(response.characteristicUuid, firmware);
    expect(response.payloadAscii, 'V1.0.8');
  });

  testWidgets('Subscribe all subscribes and a refusal is shown verbatim',
      (tester) async {
    await pumpScreen(tester);
    await connectAndDiscover(tester);

    fake.operationError = BleOperationException(
      'subscribe failed',
      detail: 'GATT_INSUFFICIENT_AUTHENTICATION (status 5)',
    );
    await tester.tap(find.text('Subscribe all'));
    await tester.pumpAndSettle();

    expect(find.text('Subscribed 0 of 1'), findsOneWidget);
    expect(find.textContaining('GATT_INSUFFICIENT_AUTHENTICATION (status 5)'),
        findsOneWidget);
  });

  testWidgets('the discovery packet carries the tree the screen shows',
      (tester) async {
    await pumpScreen(tester);
    await connectAndDiscover(tester);

    final discovery = bus.recent
        .lastWhere((p) => p.operation == PacketOperation.discoverServices);
    final services = (discovery.detail!['services'] as List)
        .map((s) => (s as Map)['uuid'])
        .toList();
    expect(services, [deviceInfo, vendorSvc]);
    expect(fake.currentConnectionState, BleConnectionState.connected);
  });
}

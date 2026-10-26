import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/models/gatt_models.dart';
import 'package:oraimo_lab/features/gatt_explorer/gatt_sweep.dart';

import '../support/fake_ble_transport.dart';

const String svc = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

GattCharacteristic chr(String uuid, GattProperties properties) =>
    GattCharacteristic(uuid: uuid, serviceUuid: svc, properties: properties);

/// A transport whose reads and subscriptions fail on chosen characteristics,
/// so the sweep's handling of partial failure can be checked precisely.
class _SelectiveFailTransport extends FakeBleTransport {
  final Map<String, Object> failOn = {};
  final List<String> attempted = [];

  @override
  Future<Uint8List> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    attempted.add(characteristicUuid);
    final error = failOn[characteristicUuid];
    if (error != null) throw error;
    return super.readCharacteristic(
        serviceUuid: serviceUuid, characteristicUuid: characteristicUuid);
  }

  @override
  Future<void> subscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    attempted.add(characteristicUuid);
    final error = failOn[characteristicUuid];
    if (error != null) throw error;
    return super.subscribe(
        serviceUuid: serviceUuid, characteristicUuid: characteristicUuid);
  }
}

void main() {
  late _SelectiveFailTransport transport;
  late GattSweep sweep;

  final services = [
    GattService(uuid: svc, characteristics: [
      chr('c-read-a', const GattProperties(read: true)),
      chr('c-write-only', const GattProperties(write: true)),
      chr('c-read-b', const GattProperties(read: true, notify: true)),
      chr('c-notify', const GattProperties(notify: true)),
      chr('c-indicate', const GattProperties(indicate: true)),
    ]),
  ];

  setUp(() async {
    transport = _SelectiveFailTransport();
    transport.readValues['c-read-a'] = Uint8List.fromList([1, 2, 3]);
    await transport.connect('AA:BB:CC:DD:EE:FF');
    sweep = GattSweep(transport);
  });

  group('readAll', () {
    test('reads exactly the characteristics that declare READ', () async {
      final report = await sweep.readAll(services);
      expect(transport.attempted, ['c-read-a', 'c-read-b']);
      expect(report.succeeded, 2);
      expect(report.outcomes.first.valueLength, 3);
      expect(report.stoppedReason, isNull);
    });

    test('a refused read is reported verbatim and the sweep carries on',
        () async {
      transport.failOn['c-read-a'] = BleOperationException(
        'read failed',
        detail: 'GATT_READ_NOT_PERMITTED (status 2)',
      );

      final report = await sweep.readAll(services);

      expect(transport.attempted, ['c-read-a', 'c-read-b'],
          reason: 'one refusal must not hide the rest of the device');
      expect(report.succeeded, 1);
      expect(report.failures.single.characteristicUuid, 'c-read-a');
      expect(report.failures.single.error,
          contains('GATT_READ_NOT_PERMITTED (status 2)'));
    });

    test('a lost connection stops the sweep and says so', () async {
      transport.failOn['c-read-a'] =
          BleConnectionException('not connected to any device');

      final report = await sweep.readAll(services);

      expect(transport.attempted, ['c-read-a'],
          reason: 'every further attempt would fail the same way');
      expect(report.stoppedReason, contains('connection lost'));
      expect(report.notAttempted, 1);
    });

    test('a device with nothing readable produces an empty report', () async {
      final report = await sweep.readAll([
        GattService(uuid: svc, characteristics: [
          chr('w', const GattProperties(write: true)),
        ]),
      ]);
      expect(report.outcomes, isEmpty);
      expect(report.stoppedReason, isNull);
    });
  });

  group('subscribeAll', () {
    test('subscribes to every NOTIFY and INDICATE characteristic', () async {
      final report = await sweep.subscribeAll(services);
      expect(transport.attempted, ['c-read-b', 'c-notify', 'c-indicate']);
      expect(report.succeeded, 3);
      expect(transport.subscribedCharacteristics,
          {'c-read-b', 'c-notify', 'c-indicate'});
    });

    test('skips characteristics that are already subscribed', () async {
      await transport.subscribe(serviceUuid: svc, characteristicUuid: 'c-notify');
      transport.attempted.clear();

      await sweep.subscribeAll(services);
      expect(transport.attempted, ['c-read-b', 'c-indicate']);
    });

    test('a refused subscription is reported and the rest still happen',
        () async {
      transport.failOn['c-notify'] = BleOperationException(
        'subscribe failed',
        detail: 'GATT_INSUFFICIENT_AUTHENTICATION (status 5)',
      );

      final report = await sweep.subscribeAll(services);

      expect(report.succeeded, 2);
      expect(report.failures.single.error,
          contains('GATT_INSUFFICIENT_AUTHENTICATION'));
      expect(transport.subscribedCharacteristics, {'c-read-b', 'c-indicate'});
    });
  });
}

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/bluetooth/instrumented_ble_transport.dart';
import 'package:oraimo_lab/core/logging/ble_event_bus.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/gatt_models.dart';

import '../support/fake_ble_transport.dart';

const String svc = '0000fee7-0000-1000-8000-00805f9b34fb';
const String chr = '0000fee1-0000-1000-8000-00805f9b34fb';

void main() {
  late FakeBleTransport fake;
  late BleEventBus bus;
  late InstrumentedBleTransport transport;

  setUp(() async {
    fake = FakeBleTransport();
    bus = BleEventBus();
    transport = InstrumentedBleTransport(fake, bus);
    await transport.connect('AA:BB:CC:DD:EE:FF');
    // Let the connection-state listener drain before each test's assertions.
    await Future<void>.delayed(Duration.zero);
    bus.clearBuffer();
  });

  tearDown(() async {
    await transport.dispose();
    await bus.dispose();
  });

  group('writes', () {
    test('a write is recorded with its payload, before the response', () async {
      await transport.writeCharacteristic(
        serviceUuid: svc,
        characteristicUuid: chr,
        value: Uint8List.fromList([0xAA, 0x01, 0x04, 0x00, 0x7F]),
        withoutResponse: false,
      );

      final ops = bus.recent.map((p) => p.operation).toList();
      expect(ops, [PacketOperation.write, PacketOperation.writeResponse]);

      final write = bus.recent.first;
      expect(write.direction, PacketDirection.phoneToWatch);
      expect(write.payloadHex, 'AA0104007F');
      expect(write.payloadLength, 5);
      expect(write.characteristicUuid, chr);
      expect(write.serviceUuid, svc);
      expect(write.status, PacketStatus.ok);
    });

    test('write-without-response records no response packet', () async {
      await transport.writeCharacteristic(
        serviceUuid: svc,
        characteristicUuid: chr,
        value: Uint8List.fromList([0x01]),
        withoutResponse: true,
      );
      expect(bus.recent.map((p) => p.operation),
          [PacketOperation.writeNoResponse]);
    });

    test('a rejected write is recorded with the error, then rethrown',
        () async {
      fake.operationError = BleOperationException(
        'write failed',
        detail: 'GATT_WRITE_NOT_PERMITTED (status 3)',
      );

      await expectLater(
        transport.writeCharacteristic(
          serviceUuid: svc,
          characteristicUuid: chr,
          value: Uint8List.fromList([0xAA]),
          withoutResponse: false,
        ),
        throwsA(isA<BleOperationException>()),
      );

      // The attempt and the failure are both evidence.
      expect(bus.recent, hasLength(2));
      final failure = bus.recent.last;
      expect(failure.operation, PacketOperation.error);
      expect(failure.status, PacketStatus.failed);
      expect(failure.error, contains('GATT_WRITE_NOT_PERMITTED (status 3)'));
      expect(failure.payloadHex, 'AA',
          reason: 'the payload that failed must be kept');
    });

    test('the payload reaches the transport unaltered', () async {
      final value = Uint8List.fromList([0x00, 0xFF, 0x7F, 0x80]);
      await transport.writeCharacteristic(
        serviceUuid: svc,
        characteristicUuid: chr,
        value: value,
        withoutResponse: false,
      );
      expect(fake.writes.single.value, value);
    });
  });

  group('reads', () {
    test('a read produces a request and a response packet', () async {
      fake.readValues[chr] = Uint8List.fromList([0xAA, 0x81, 0x00, 0x01]);

      final value = await transport.readCharacteristic(
        serviceUuid: svc,
        characteristicUuid: chr,
      );
      expect(value, [0xAA, 0x81, 0x00, 0x01]);

      expect(bus.recent.map((p) => p.operation),
          [PacketOperation.readRequest, PacketOperation.readResponse]);
      expect(bus.recent.first.direction, PacketDirection.phoneToWatch);
      expect(bus.recent.first.payloadHex, isEmpty);
      expect(bus.recent.last.direction, PacketDirection.watchToPhone);
      expect(bus.recent.last.payloadHex, 'AA810001');
    });

    test('a failed read still records the request that was sent', () async {
      fake.operationError = BleOperationException('read failed');
      await expectLater(
        transport.readCharacteristic(serviceUuid: svc, characteristicUuid: chr),
        throwsA(isA<BleOperationException>()),
      );
      expect(bus.recent.first.operation, PacketOperation.readRequest);
      expect(bus.recent.last.status, PacketStatus.failed);
    });
  });

  group('notifications', () {
    test('a value from the watch is recorded as an inbound notify', () async {
      await transport.subscribe(serviceUuid: svc, characteristicUuid: chr);
      bus.clearBuffer();

      fake.emitNotification(svc, chr, [0xAA, 0x81, 0x00, 0x01]);
      await Future<void>.delayed(Duration.zero);

      final notify = bus.recent.single;
      expect(notify.operation, PacketOperation.notify);
      expect(notify.direction, PacketDirection.watchToPhone);
      expect(notify.payloadHex, 'AA810001');
      expect(notify.characteristicUuid, chr);
    });

    test('subscribing is itself recorded', () async {
      await transport.subscribe(serviceUuid: svc, characteristicUuid: chr);
      expect(bus.recent.single.operation, PacketOperation.subscribe);
      expect(fake.subscribedCharacteristics, contains(chr));
    });
  });

  group('service discovery', () {
    test('records the whole attribute database, not just a count', () async {
      fake.services = const [
        GattService(
          uuid: svc,
          characteristics: [
            GattCharacteristic(
              uuid: chr,
              serviceUuid: svc,
              properties: GattProperties(write: true, notify: true),
              descriptors: [
                GattDescriptor(uuid: '00002902-0000-1000-8000-00805f9b34fb'),
              ],
            ),
          ],
        ),
      ];

      await transport.discoverServices();

      final packet = bus.recent.single;
      expect(packet.operation, PacketOperation.discoverServices);
      expect(packet.note, '1 services, 1 characteristics');
      expect(packet.payloadHex, isEmpty,
          reason: 'the tree is not wire bytes and must not pose as a payload');

      final services = packet.detail!['services'] as List;
      final characteristic =
          (services.single['characteristics'] as List).single as Map;
      expect(services.single['uuid'], svc);
      expect(characteristic['uuid'], chr);
      expect(characteristic['propertyLabels'], ['WRITE', 'NOTIFY']);
      expect((characteristic['descriptors'] as List).single['uuid'],
          '00002902-0000-1000-8000-00805f9b34fb');
    });

    test('a failed discovery carries no detail', () async {
      await fake.disconnect();
      await expectLater(
          transport.discoverServices(), throwsA(isA<BleConnectionException>()));
      final failure = bus.recent.last;
      expect(failure.status, PacketStatus.failed);
      expect(failure.detail, isNull);
    });
  });

  group('event bus', () {
    test('sequence numbers increase monotonically', () async {
      for (var i = 0; i < 5; i++) {
        await transport.writeCharacteristic(
          serviceUuid: svc,
          characteristicUuid: chr,
          value: Uint8List.fromList([i]),
          withoutResponse: true,
        );
      }
      final seqs = bus.recent.map((p) => p.seq).toList();
      expect(seqs, equals(List.generate(seqs.length, (i) => seqs.first + i)));
    });

    test('elapsed microseconds never go backwards', () async {
      for (var i = 0; i < 5; i++) {
        await transport.writeCharacteristic(
          serviceUuid: svc,
          characteristicUuid: chr,
          value: Uint8List.fromList([i]),
          withoutResponse: true,
        );
      }
      final elapsed = bus.recent.map((p) => p.elapsedUs).toList();
      for (var i = 1; i < elapsed.length; i++) {
        expect(elapsed[i], greaterThanOrEqualTo(elapsed[i - 1]));
      }
    });

    test('the buffer is bounded and drops oldest first', () async {
      final smallBus = BleEventBus(bufferSize: 3);
      for (var i = 0; i < 10; i++) {
        smallBus.emit(
          direction: PacketDirection.phoneToWatch,
          operation: PacketOperation.write,
          payloadHex: '0$i',
        );
      }
      expect(smallBus.recent, hasLength(3));
      expect(smallBus.recent.map((p) => p.payloadHex), ['07', '08', '09']);
      await smallBus.dispose();
    });

    test('packets emitted by the bus carry no session until recorded', () {
      final packet = bus.emit(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.write,
        payloadHex: 'AA',
      );
      expect(packet.sessionId, isNull);
    });
  });
}

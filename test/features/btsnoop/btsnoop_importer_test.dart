import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/capture_session.dart';
import 'package:oraimo_lab/features/import/btsnoop/btsnoop_importer.dart';
import 'package:oraimo_lab/features/import/btsnoop/hci_parser.dart';

import '../../support/btsnoop_builder.dart';

const int watchHandle = 0x0040;
const int otherHandle = 0x0041;
const String watchAddress = 'AA:BB:CC:DD:EE:FF';
const String headphonesAddress = '11:22:33:44:55:66';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

final DateTime t0 = DateTime.utc(2026, 3, 1, 21, 43, 12);

/// A capture in which the phone discovers the watch's GATT database and then
/// exchanges a few packets with it — the shape of a real Oraimo Health session.
Uint8List buildCapture({bool withDiscovery = true, bool withOtherDevice = false}) {
  final b = BtsnoopBuilder();
  var clock = t0;
  DateTime tick([int ms = 40]) => clock = clock.add(Duration(milliseconds: ms));

  b.addRecord(
    data: leConnectionComplete(handle: watchHandle, address: watchAddress),
    timestamp: clock,
    sent: false,
    isCommandOrEvent: true,
  );

  if (withOtherDevice) {
    b.addRecord(
      data: leConnectionComplete(handle: otherHandle, address: headphonesAddress),
      timestamp: tick(),
      sent: false,
      isCommandOrEvent: true,
    );
  }

  if (withDiscovery) {
    b.addRecord(
      data: aclAtt(
        handle: watchHandle,
        attPdu: attReadByGroupTypeResponseServices([
          (start: 0x0028, end: 0x0030, uuid16: null, uuid128: serviceUuid),
        ]),
      ),
      timestamp: tick(),
      sent: false,
    );
    b.addRecord(
      data: aclAtt(
          handle: watchHandle,
          attPdu: attReadByTypeRequestForCharacteristics()),
      timestamp: tick(),
    );
    b.addRecord(
      data: aclAtt(
        handle: watchHandle,
        attPdu: attReadByTypeResponseCharacteristics([
          (
            declarationHandle: 0x002A,
            properties: 0x0C,
            valueHandle: 0x002B,
            uuid16: null,
            uuid128: charUuid,
          ),
        ]),
      ),
      timestamp: tick(),
      sent: false,
    );
    b.addRecord(
      data: aclAtt(
        handle: watchHandle,
        attPdu: attFindInformationResponse16([
          (handle: 0x002F, uuid16: kUuidClientCharacteristicConfiguration),
        ]),
      ),
      timestamp: tick(),
      sent: false,
    );
  }

  // Enable notifications, then a write and the reply.
  b.addRecord(
    data: aclAtt(handle: watchHandle, attPdu: attWriteRequest(0x002F, [0x01, 0x00])),
    timestamp: tick(),
  );
  b.addRecord(
    data: aclAtt(
        handle: watchHandle,
        attPdu: attWriteRequest(0x002B, [0xAA, 0x01, 0x04, 0x00, 0x7F])),
    timestamp: tick(),
  );
  b.addRecord(
    data: aclAtt(handle: watchHandle, attPdu: attWriteResponse()),
    timestamp: tick(),
    sent: false,
  );
  b.addRecord(
    data: aclAtt(
        handle: watchHandle, attPdu: attNotification(0x002B, [0xAA, 0x81, 0x00, 0x01])),
    timestamp: tick(),
    sent: false,
  );

  if (withOtherDevice) {
    b.addRecord(
      data: aclAtt(
          handle: otherHandle, attPdu: attWriteRequest(0x0005, [0xFF, 0xEE])),
      timestamp: tick(),
    );
  }

  return b.build();
}

void main() {
  final importer = BtsnoopImporter();

  group('preview', () {
    test('lists the devices in the capture without importing anything', () {
      final preview = importer.preview(buildCapture(withOtherDevice: true));
      expect(preview.peers.map((p) => p.address),
          containsAll([watchAddress, headphonesAddress]));
      expect(preview.summary.attPackets, greaterThan(0));
    });

    test('orders peers by traffic so the busy device is easy to spot', () {
      final preview = importer.preview(buildCapture(withOtherDevice: true));
      expect(preview.peers.first.address, watchAddress);
      expect(preview.peers.first.attPacketCount,
          greaterThan(preview.peers.last.attPacketCount));
    });
  });

  group('import', () {
    test('produces a session marked as imported, never as live', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'watchface-A',
        peerAddress: watchAddress,
        sourceFileName: 'btsnoop_hci.log',
      );

      expect(result.session.source, CaptureSource.btsnoopImport);
      expect(result.session.name, 'watchface-A');
      expect(result.session.deviceAddress, watchAddress);
      expect(result.session.sourceFileName, 'btsnoop_hci.log');
    });

    test('only the chosen device is imported', () {
      final result = importer.import(
        bytes: buildCapture(withOtherDevice: true),
        sessionId: 's1',
        sessionName: 'watch only',
        peerAddress: watchAddress,
      );
      // The headphones' write to handle 0x0005 must not appear.
      expect(result.packets.map((p) => p.attHandle), isNot(contains(0x0005)));
    });

    test('payloads survive the whole pipeline byte for byte', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );

      final write = result.packets.firstWhere((p) => p.attHandle == 0x002B &&
          p.direction == PacketDirection.phoneToWatch);
      expect(write.payloadHex, 'AA0104007F');
      expect(write.payloadDisplay, 'AA 01 04 00 7F');

      final notify = result.packets.firstWhere(
          (p) => p.operation == PacketOperation.notify);
      expect(notify.payloadHex, 'AA810001');
      expect(notify.direction, PacketDirection.watchToPhone);
    });

    test('a write to a discovered CCCD is recognised as a subscribe', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      final cccd = result.packets.firstWhere((p) => p.attHandle == 0x002F);
      expect(cccd.operation, PacketOperation.subscribe);
      expect(cccd.descriptorUuid, '00002902-0000-1000-8000-00805f9b34fb');
    });

    test('without discovery, the same write stays an ordinary write', () {
      final result = importer.import(
        bytes: buildCapture(withDiscovery: false),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      final cccd = result.packets.firstWhere((p) => p.attHandle == 0x002F);
      expect(cccd.operation, PacketOperation.write,
          reason: 'calling it a subscribe would claim knowledge we lack');
      expect(cccd.descriptorUuid, isNull);
    });

    test('handles are resolved when the capture contains the discovery', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );

      final write = result.packets.firstWhere((p) =>
          p.attHandle == 0x002B && p.direction == PacketDirection.phoneToWatch);
      expect(write.characteristicUuid, charUuid);
      expect(write.serviceUuid, serviceUuid);
      expect(result.resolvedCharacteristics[0x002B], charUuid);
      expect(result.hasUnresolvedHandles, isFalse);
    });

    test('handles stay null and are reported when discovery is missing', () {
      final result = importer.import(
        bytes: buildCapture(withDiscovery: false),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );

      final write = result.packets.firstWhere((p) =>
          p.attHandle == 0x002B && p.direction == PacketDirection.phoneToWatch);
      expect(write.characteristicUuid, isNull);
      expect(write.serviceUuid, isNull);
      expect(write.attributeLabel, 'handle 0x002b');
      expect(result.hasUnresolvedHandles, isTrue);
      expect(result.unresolvedHandles, contains(0x002B));
    });

    test('timestamps and elapsed offsets are both preserved', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );

      expect(result.packets.first.elapsedUs, 0);
      for (var i = 1; i < result.packets.length; i++) {
        expect(result.packets[i].elapsedUs,
            greaterThanOrEqualTo(result.packets[i - 1].elapsedUs));
        expect(result.packets[i].timestamp.isAfter(t0.subtract(const Duration(seconds: 1))),
            isTrue);
      }
      expect(result.session.startedAt, result.packets.first.timestamp);
      expect(result.session.endedAt, result.packets.last.timestamp);
    });

    test('sequence numbers are dense and start at zero', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      expect(result.packets.map((p) => p.seq),
          List.generate(result.packets.length, (i) => i));
    });

    test('every packet is attributed to the session', () {
      final result = importer.import(
        bytes: buildCapture(),
        sessionId: 'ses-42',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      expect(result.packets.every((p) => p.sessionId == 'ses-42'), isTrue);
    });

    test('a large fragmented payload arrives as one packet', () {
      final value = List<int>.generate(512, (i) => i & 0xFF);
      final b = BtsnoopBuilder()
        ..addRecord(
          data: leConnectionComplete(handle: watchHandle, address: watchAddress),
          timestamp: t0,
          sent: false,
          isCommandOrEvent: true,
        );
      var clock = t0;
      for (final fragment in aclAttFragmented(
        handle: watchHandle,
        attPdu: attWriteCommand(0x002B, value),
        fragmentSize: 27,
      )) {
        b.addRecord(
            data: fragment, timestamp: clock = clock.add(const Duration(milliseconds: 5)));
      }

      final result = importer.import(
        bytes: b.build(),
        sessionId: 's1',
        sessionName: 'watchface transfer',
        peerAddress: watchAddress,
      );

      final writes = result.packets
          .where((p) => p.operation == PacketOperation.writeNoResponse)
          .toList();
      expect(writes, hasLength(1),
          reason: 'fragments must be rejoined, not counted separately');
      expect(writes.single.payloadLength, 512);
      expect(writes.single.payloadBytes, value);
    });

    test('an ATT error response becomes a failed packet with the spec name', () {
      final b = BtsnoopBuilder()
        ..addRecord(
          data: leConnectionComplete(handle: watchHandle, address: watchAddress),
          timestamp: t0,
          sent: false,
          isCommandOrEvent: true,
        )
        ..addRecord(
          data: aclAtt(
            handle: watchHandle,
            attPdu: attErrorResponse(
                requestOpcode: 0x12, handle: 0x002B, errorCode: 0x03),
          ),
          timestamp: t0.add(const Duration(milliseconds: 10)),
          sent: false,
        );

      final result = importer.import(
        bytes: b.build(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      final error = result.packets.single;
      expect(error.status, PacketStatus.failed);
      expect(error.error, contains('Write Not Permitted'));
      expect(error.error, contains('0x002b'));
    });

    test('a truncated packet is annotated so it cannot be trusted later', () {
      final b = BtsnoopBuilder()
        ..addRecord(
          data: leConnectionComplete(handle: watchHandle, address: watchAddress),
          timestamp: t0,
          sent: false,
          isCommandOrEvent: true,
        )
        ..addRecord(
          data: aclAtt(
              handle: watchHandle, attPdu: attWriteCommand(0x002B, [0xAA, 0xBB])),
          timestamp: t0.add(const Duration(milliseconds: 10)),
          originalLengthOverride: 200,
        );

      final result = importer.import(
        bytes: b.build(),
        sessionId: 's1',
        sessionName: 'x',
        peerAddress: watchAddress,
      );
      expect(result.hasTruncatedRecords, isTrue);
      expect(result.packets.single.note, contains('incomplete'));
    });

    test('an empty capture imports cleanly rather than crashing', () {
      final result = importer.import(
        bytes: BtsnoopBuilder().build(),
        sessionId: 's1',
        sessionName: 'empty',
      );
      expect(result.packets, isEmpty);
      expect(result.session.packetCount, 0);
    });
  });
}

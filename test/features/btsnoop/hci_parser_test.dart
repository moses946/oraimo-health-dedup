import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/features/import/btsnoop/hci_parser.dart';

import '../../support/btsnoop_builder.dart';

const int connHandle = 0x0040;
const String watchAddress = 'AA:BB:CC:DD:EE:FF';
const String vendorCharUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const String vendorServiceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';

final DateTime t0 = DateTime.utc(2026, 3, 1, 21, 43, 12);

void main() {
  late HciParser parser;

  setUp(() => parser = HciParser());

  List<AttPacket> feed(Uint8List data, {bool sent = true, DateTime? at}) =>
      parser.addPacket(
        data: data,
        timestamp: at ?? t0,
        isReceived: !sent,
        cumulativeDrops: 0,
      );

  void openConnection({int handle = connHandle, String address = watchAddress}) {
    feed(leConnectionComplete(handle: handle, address: address), sent: false);
  }

  group('connection tracking', () {
    test('an LE Connection Complete maps a handle to a peer address', () {
      openConnection();
      final connection = parser.connections.single;
      expect(connection.handle, connHandle);
      expect(connection.peerAddress, watchAddress);
    });

    test('the address is byte-reversed from the wire order', () {
      openConnection(address: '01:02:03:04:05:06');
      expect(parser.connections.single.peerAddress, '01:02:03:04:05:06');
    });

    test('a failed connection attempt is not recorded', () {
      feed(
        leConnectionComplete(handle: connHandle, address: watchAddress, status: 0x02),
        sent: false,
      );
      expect(parser.connections, isEmpty);
    });

    test('several devices are tracked separately', () {
      openConnection(handle: 0x0040, address: 'AA:AA:AA:AA:AA:AA');
      openConnection(handle: 0x0041, address: 'BB:BB:BB:BB:BB:BB');
      expect(parser.connections.map((c) => c.peerAddress),
          containsAll(['AA:AA:AA:AA:AA:AA', 'BB:BB:BB:BB:BB:BB']));
    });

    test('a disconnection is timestamped', () {
      openConnection();
      final later = t0.add(const Duration(minutes: 2));
      feed(disconnectionComplete(handle: connHandle), sent: false, at: later);
      expect(parser.connections.single.closedAt, later);
    });
  });

  group('ATT decoding', () {
    setUp(openConnection);

    test('a write request yields the handle and the value, opcode stripped', () {
      final packets = feed(aclAtt(
        handle: connHandle,
        attPdu: attWriteRequest(0x002B, [0xAA, 0x01, 0x04, 0x00, 0x7F]),
      ));

      final packet = packets.single;
      expect(packet.operation, AttOperation.writeRequest);
      expect(packet.attributeHandle, 0x002B);
      expect(packet.payload, [0xAA, 0x01, 0x04, 0x00, 0x7F]);
      expect(packet.fromRemote, isFalse);
    });

    test('a write command is distinguished from a write request', () {
      final packets = feed(aclAtt(
        handle: connHandle,
        attPdu: attWriteCommand(0x002B, [0x01]),
      ));
      expect(packets.single.operation, AttOperation.writeCommand);
    });

    test('a notification from the watch is marked as inbound', () {
      final packets = feed(
        aclAtt(
          handle: connHandle,
          attPdu: attNotification(0x002E, [0xAA, 0x81, 0x00, 0x01]),
        ),
        sent: false,
      );

      final packet = packets.single;
      expect(packet.operation, AttOperation.notification);
      expect(packet.fromRemote, isTrue);
      expect(packet.attributeHandle, 0x002E);
      expect(packet.payload, [0xAA, 0x81, 0x00, 0x01]);
    });

    test('a read request carries a handle and no value', () {
      final packets =
          feed(aclAtt(handle: connHandle, attPdu: attReadRequest(0x0016)));
      expect(packets.single.operation, AttOperation.readRequest);
      expect(packets.single.attributeHandle, 0x0016);
      expect(packets.single.payload, isEmpty);
    });

    test('a read response carries a value and no handle', () {
      final packets = feed(
        aclAtt(handle: connHandle, attPdu: attReadResponse([0x64])),
        sent: false,
      );
      expect(packets.single.operation, AttOperation.readResponse);
      expect(packets.single.attributeHandle, isNull);
      expect(packets.single.payload, [0x64]);
    });

    test('an error response is surfaced as such', () {
      final packets = feed(
        aclAtt(
          handle: connHandle,
          attPdu: attErrorResponse(
              requestOpcode: kAttWriteRequest, handle: 0x002B, errorCode: 0x03),
        ),
        sent: false,
      );
      expect(packets.single.operation, AttOperation.errorResponse);
    });

    test('a zero-length write value is kept as an empty payload', () {
      final packets = feed(
          aclAtt(handle: connHandle, attPdu: attWriteRequest(0x002B, [])));
      expect(packets.single.payload, isEmpty);
      expect(packets.single.attributeHandle, 0x002B);
    });

    test('non-ATT L2CAP traffic is ignored', () {
      // A signalling-channel packet (CID 0x0005) must not be decoded as ATT.
      final acl = Uint8List.fromList([
        kH4AclData,
        connHandle & 0xFF,
        0x20, // pb = 0b10
        0x08, 0x00,
        0x04, 0x00, // L2CAP length
        0x05, 0x00, // CID 0x0005, not ATT
        0x12, 0x34, 0x56, 0x78,
      ]);
      expect(feed(acl), isEmpty);
    });

    test('HCI commands are ignored', () {
      expect(feed(Uint8List.fromList([kH4Command, 0x0D, 0x20, 0x00])), isEmpty);
    });
  });

  group('L2CAP reassembly', () {
    setUp(openConnection);

    test('a PDU split across fragments is rejoined into one payload', () {
      // 180 bytes is far larger than a default 23-byte ATT MTU — the shape a
      // watch-face transfer will take.
      final value = List<int>.generate(180, (i) => i & 0xFF);
      final fragments = aclAttFragmented(
        handle: connHandle,
        attPdu: attWriteCommand(0x002B, value),
        fragmentSize: 27,
      );
      expect(fragments.length, greaterThan(1),
          reason: 'the fixture must actually fragment');

      final produced = <AttPacket>[];
      for (final fragment in fragments) {
        produced.addAll(feed(fragment));
      }

      expect(produced, hasLength(1),
          reason: 'fragments must not each become a packet');
      expect(produced.single.payload, value);
      expect(produced.single.attributeHandle, 0x002B);
    });

    test('nothing is emitted until the last fragment arrives', () {
      final fragments = aclAttFragmented(
        handle: connHandle,
        attPdu: attWriteCommand(0x002B, List.filled(100, 0xAB)),
        fragmentSize: 20,
      );

      for (var i = 0; i < fragments.length - 1; i++) {
        expect(feed(fragments[i]), isEmpty, reason: 'fragment $i');
      }
      expect(feed(fragments.last), hasLength(1));
    });

    test('fragments from two connections do not contaminate each other', () {
      openConnection(handle: 0x0041, address: 'BB:BB:BB:BB:BB:BB');

      final a = aclAttFragmented(
        handle: connHandle,
        attPdu: attWriteCommand(0x0010, List.filled(60, 0xAA)),
        fragmentSize: 20,
      );
      final b = aclAttFragmented(
        handle: 0x0041,
        attPdu: attWriteCommand(0x0020, List.filled(60, 0xBB)),
        fragmentSize: 20,
      );

      final produced = <AttPacket>[];
      // Interleave them, as a phone talking to two devices really would.
      for (var i = 0; i < a.length; i++) {
        produced.addAll(feed(a[i]));
        if (i < b.length) produced.addAll(feed(b[i]));
      }

      expect(produced, hasLength(2));
      final byHandle = {for (final p in produced) p.attributeHandle: p};
      expect(byHandle[0x0010]!.payload, everyElement(0xAA));
      expect(byHandle[0x0020]!.payload, everyElement(0xBB));
    });

    test('a capture starting mid-transfer discards the orphan continuation '
        'rather than inventing a head', () {
      final fragments = aclAttFragmented(
        handle: connHandle,
        attPdu: attWriteCommand(0x002B, List.filled(100, 0x5A)),
        fragmentSize: 20,
      );
      // Skip the first fragment, as if the log started late.
      final produced = <AttPacket>[];
      for (final fragment in fragments.skip(1)) {
        produced.addAll(feed(fragment));
      }
      expect(produced, isEmpty);
    });

    test('a fragmented non-ATT PDU is still not decoded as ATT', () {
      // Build a long PDU on CID 0x0005 and fragment it by hand.
      final body = List<int>.generate(60, (i) => i);
      final l2cap = <int>[
        body.length & 0xFF, (body.length >> 8) & 0xFF,
        0x05, 0x00, // CID 0x0005
        ...body,
      ];
      final produced = <AttPacket>[];
      var offset = 0;
      var first = true;
      while (offset < l2cap.length) {
        final end = (offset + 20).clamp(0, l2cap.length);
        final chunk = l2cap.sublist(offset, end);
        final pb = first ? 0x02 : kPbContinuingFragment;
        final hf = (connHandle & 0x0FFF) | (pb << 12);
        produced.addAll(feed(Uint8List.fromList([
          kH4AclData, hf & 0xFF, (hf >> 8) & 0xFF,
          chunk.length & 0xFF, (chunk.length >> 8) & 0xFF,
          ...chunk,
        ])));
        offset = end;
        first = false;
      }
      expect(produced, isEmpty);
    });
  });

  group('handle resolution is evidence-based', () {
    setUp(openConnection);

    test('a handle stays unresolved when the capture never discovered it', () {
      feed(aclAtt(handle: connHandle, attPdu: attWriteRequest(0x002B, [0xAA])));

      final map = parser.attributeMapFor(connHandle);
      expect(map.characteristicFor(0x002B), isNull);
      expect(map.isEmpty, isTrue);
      expect(parser.summary.unresolvedHandles, contains(0x002B));
    });

    test('a characteristic declaration in the capture resolves its value '
        'handle', () {
      feed(aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeRequestForCharacteristics()));
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeResponseCharacteristics([
            (
              declarationHandle: 0x002A,
              properties: 0x0C,
              valueHandle: 0x002B,
              uuid16: null,
              uuid128: vendorCharUuid,
            ),
          ]),
        ),
        sent: false,
      );

      expect(parser.attributeMapFor(connHandle).characteristicFor(0x002B),
          vendorCharUuid);
    });

    test('a 128-bit vendor UUID survives the little-endian wire order', () {
      feed(aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeRequestForCharacteristics()));
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeResponseCharacteristics([
            (
              declarationHandle: 0x0010,
              properties: 0x10,
              valueHandle: 0x0011,
              uuid16: null,
              uuid128: vendorCharUuid,
            ),
          ]),
        ),
        sent: false,
      );
      expect(parser.attributeMapFor(connHandle).characteristicFor(0x0011),
          vendorCharUuid);
    });

    test('a Read By Type Response for some other type resolves nothing', () {
      // Asking for Appearance (0x2A01), not characteristic declarations. The
      // response must not be misread as a declaration list.
      feed(aclAtt(
        handle: connHandle,
        attPdu: Uint8List.fromList([
          kAttReadByTypeRequest, 0x01, 0x00, 0xFF, 0xFF, 0x01, 0x2A,
        ]),
      ));
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeResponseCharacteristics([
            (
              declarationHandle: 0x002A,
              properties: 0x0C,
              valueHandle: 0x002B,
              uuid16: 0x2A19,
              uuid128: null,
            ),
          ]),
        ),
        sent: false,
      );
      expect(parser.attributeMapFor(connHandle).characteristicFor(0x002B), isNull);
    });

    test('service ranges attribute a characteristic to its service', () {
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attReadByGroupTypeResponseServices([
            (start: 0x0028, end: 0x0030, uuid16: null, uuid128: vendorServiceUuid),
          ]),
        ),
        sent: false,
      );

      final map = parser.attributeMapFor(connHandle);
      expect(map.serviceFor(0x002B), vendorServiceUuid);
      expect(map.serviceFor(0x0027), isNull, reason: 'outside the range');
      expect(map.serviceFor(0x0031), isNull, reason: 'outside the range');
    });

    test('a Find Information Response identifies descriptors such as the CCCD',
        () {
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attFindInformationResponse16([
            (handle: 0x002F, uuid16: kUuidClientCharacteristicConfiguration),
          ]),
        ),
        sent: false,
      );
      expect(parser.attributeMapFor(connHandle).descriptorFor(0x002F),
          '00002902-0000-1000-8000-00805f9b34fb');
    });

    test('knowledge from one connection does not leak into another', () {
      openConnection(handle: 0x0041, address: 'BB:BB:BB:BB:BB:BB');
      feed(aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeRequestForCharacteristics()));
      feed(
        aclAtt(
          handle: connHandle,
          attPdu: attReadByTypeResponseCharacteristics([
            (
              declarationHandle: 0x002A,
              properties: 0x0C,
              valueHandle: 0x002B,
              uuid16: null,
              uuid128: vendorCharUuid,
            ),
          ]),
        ),
        sent: false,
      );

      expect(parser.attributeMapFor(connHandle).characteristicFor(0x002B),
          vendorCharUuid);
      expect(parser.attributeMapFor(0x0041).characteristicFor(0x002B), isNull,
          reason: 'handles are only meaningful within their own connection');
    });
  });

  group('summary', () {
    test('counts what was seen and what was lost', () {
      openConnection();
      feed(aclAtt(handle: connHandle, attPdu: attWriteRequest(0x002B, [0x01])));
      parser.addPacket(
        data: aclAtt(handle: connHandle, attPdu: attWriteRequest(0x002B, [0x02])),
        timestamp: t0.add(const Duration(seconds: 1)),
        isReceived: false,
        cumulativeDrops: 3,
        truncated: true,
      );

      final summary = parser.summary;
      expect(summary.attPackets, 2);
      expect(summary.aclRecords, 2);
      expect(summary.truncatedRecords, 1);
      expect(summary.droppedRecords, 3);
      expect(summary.firstTimestamp, t0);
      expect(summary.lastTimestamp, t0.add(const Duration(seconds: 1)));
      expect(summary.connections.single.attPacketCount, 2);
    });
  });
}

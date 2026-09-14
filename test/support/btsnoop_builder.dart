/// Builds synthetic btsnoop files for tests.
///
/// Writing the bytes by hand keeps the tests honest: they exercise the real
/// file format and the real HCI framing rather than a mock of the parser's own
/// assumptions. Every helper here encodes the format as specified, so a
/// disagreement between builder and parser is a genuine bug in one of them.
library;

import 'dart:typed_data';

import 'package:oraimo_lab/features/import/btsnoop/btsnoop_reader.dart';
import 'package:oraimo_lab/features/import/btsnoop/hci_parser.dart';

class BtsnoopBuilder {
  BtsnoopBuilder({this.datalinkType = kDatalinkH4, this.version = 1});

  final int datalinkType;
  final int version;
  final List<Uint8List> _records = [];

  /// Appends one record. [sent] true means host → controller (phone → watch).
  void addRecord({
    required Uint8List data,
    required DateTime timestamp,
    bool sent = true,
    bool isCommandOrEvent = false,
    int cumulativeDrops = 0,
    int? originalLengthOverride,
  }) {
    var flags = 0;
    if (!sent) flags |= 0x01;
    if (isCommandOrEvent) flags |= 0x02;

    final header = ByteData(24);
    header.setUint32(0, originalLengthOverride ?? data.length);
    header.setUint32(4, data.length);
    header.setUint32(8, flags);
    header.setUint32(12, cumulativeDrops);
    header.setInt64(16, btsnoopTimestampFrom(timestamp));

    final record = BytesBuilder(copy: true)
      ..add(header.buffer.asUint8List())
      ..add(data);
    _records.add(record.takeBytes());
  }

  Uint8List build() {
    final header = ByteData(16);
    for (var i = 0; i < kBtsnoopMagic.length; i++) {
      header.setUint8(i, kBtsnoopMagic[i]);
    }
    header.setUint32(8, version);
    header.setUint32(12, datalinkType);

    final out = BytesBuilder(copy: true)..add(header.buffer.asUint8List());
    for (final record in _records) {
      out.add(record);
    }
    return out.takeBytes();
  }
}

// ------------------------------------------------------------- HCI builders

/// An HCI LE Connection Complete event announcing [address] on [handle].
Uint8List leConnectionComplete({
  required int handle,
  required String address,
  int status = 0x00,
}) {
  final addressBytes = _addressToLeBytes(address);
  final params = BytesBuilder(copy: true)
    ..addByte(status)
    ..addByte(handle & 0xFF)
    ..addByte((handle >> 8) & 0xFF)
    ..addByte(0x00) // role: central
    ..addByte(0x00) // peer address type: public
    ..add(addressBytes)
    ..add(Uint8List(7)); // interval, latency, timeout, accuracy
  final body = params.takeBytes();

  final subevent = BytesBuilder(copy: true)
    ..addByte(0x01) // LE Connection Complete
    ..add(body);
  final subeventBytes = subevent.takeBytes();

  return Uint8List.fromList([
    kH4Event,
    0x3E, // LE Meta Event
    subeventBytes.length,
    ...subeventBytes,
  ]);
}

Uint8List disconnectionComplete({required int handle}) => Uint8List.fromList([
      kH4Event,
      0x05,
      0x04,
      0x00, // status
      handle & 0xFF,
      (handle >> 8) & 0xFF,
      0x16, // reason: connection terminated by local host
    ]);

/// Wraps an ATT PDU into one complete, unfragmented ACL packet.
Uint8List aclAtt({required int handle, required Uint8List attPdu}) {
  final l2cap = BytesBuilder(copy: true)
    ..addByte(attPdu.length & 0xFF)
    ..addByte((attPdu.length >> 8) & 0xFF)
    ..addByte(kCidAtt & 0xFF)
    ..addByte((kCidAtt >> 8) & 0xFF)
    ..add(attPdu);
  final l2capBytes = l2cap.takeBytes();

  // pbFlag 0b10 = first automatically-flushable packet of a higher layer message
  final handleAndFlags = (handle & 0x0FFF) | (0x02 << 12);

  return Uint8List.fromList([
    kH4AclData,
    handleAndFlags & 0xFF,
    (handleAndFlags >> 8) & 0xFF,
    l2capBytes.length & 0xFF,
    (l2capBytes.length >> 8) & 0xFF,
    ...l2capBytes,
  ]);
}

/// Splits one ATT PDU across several ACL fragments of at most [fragmentSize]
/// payload bytes each, as a real controller does when the PDU exceeds the MTU.
List<Uint8List> aclAttFragmented({
  required int handle,
  required Uint8List attPdu,
  required int fragmentSize,
}) {
  final l2cap = BytesBuilder(copy: true)
    ..addByte(attPdu.length & 0xFF)
    ..addByte((attPdu.length >> 8) & 0xFF)
    ..addByte(kCidAtt & 0xFF)
    ..addByte((kCidAtt >> 8) & 0xFF)
    ..add(attPdu);
  final full = l2cap.takeBytes();

  final fragments = <Uint8List>[];
  var offset = 0;
  var first = true;
  while (offset < full.length) {
    final end = (offset + fragmentSize).clamp(0, full.length);
    final chunk = Uint8List.sublistView(full, offset, end);
    final pb = first ? 0x02 : kPbContinuingFragment;
    final handleAndFlags = (handle & 0x0FFF) | (pb << 12);

    fragments.add(Uint8List.fromList([
      kH4AclData,
      handleAndFlags & 0xFF,
      (handleAndFlags >> 8) & 0xFF,
      chunk.length & 0xFF,
      (chunk.length >> 8) & 0xFF,
      ...chunk,
    ]));
    offset = end;
    first = false;
  }
  return fragments;
}

// ------------------------------------------------------------- ATT builders

Uint8List attWriteRequest(int handle, List<int> value) => Uint8List.fromList([
      kAttWriteRequest,
      handle & 0xFF,
      (handle >> 8) & 0xFF,
      ...value,
    ]);

Uint8List attWriteCommand(int handle, List<int> value) => Uint8List.fromList([
      kAttWriteCommand,
      handle & 0xFF,
      (handle >> 8) & 0xFF,
      ...value,
    ]);

Uint8List attWriteResponse() => Uint8List.fromList([kAttWriteResponse]);

Uint8List attNotification(int handle, List<int> value) => Uint8List.fromList([
      kAttHandleValueNotification,
      handle & 0xFF,
      (handle >> 8) & 0xFF,
      ...value,
    ]);

Uint8List attReadRequest(int handle) => Uint8List.fromList([
      kAttReadRequest,
      handle & 0xFF,
      (handle >> 8) & 0xFF,
    ]);

Uint8List attReadResponse(List<int> value) =>
    Uint8List.fromList([kAttReadResponse, ...value]);

Uint8List attErrorResponse({
  required int requestOpcode,
  required int handle,
  required int errorCode,
}) =>
    Uint8List.fromList([
      kAttErrorResponse,
      requestOpcode,
      handle & 0xFF,
      (handle >> 8) & 0xFF,
      errorCode,
    ]);

/// A Read By Type Request asking for characteristic declarations.
Uint8List attReadByTypeRequestForCharacteristics({
  int start = 0x0001,
  int end = 0xFFFF,
}) =>
    Uint8List.fromList([
      kAttReadByTypeRequest,
      start & 0xFF,
      (start >> 8) & 0xFF,
      end & 0xFF,
      (end >> 8) & 0xFF,
      kUuidCharacteristicDeclaration & 0xFF,
      (kUuidCharacteristicDeclaration >> 8) & 0xFF,
    ]);

/// A Read By Type Response listing characteristic declarations.
///
/// Each entry is (declaration handle, properties, value handle, UUID). The
/// UUID is 16-bit when [uuid16] is given, 128-bit when [uuid128] is.
Uint8List attReadByTypeResponseCharacteristics(
  List<
          ({
            int declarationHandle,
            int properties,
            int valueHandle,
            int? uuid16,
            String? uuid128
          })>
      entries,
) {
  final is128 = entries.first.uuid128 != null;
  final itemLength = is128 ? 21 : 7;
  final out = BytesBuilder(copy: true)..addByte(itemLength);

  for (final e in entries) {
    out
      ..addByte(e.declarationHandle & 0xFF)
      ..addByte((e.declarationHandle >> 8) & 0xFF)
      ..addByte(e.properties)
      ..addByte(e.valueHandle & 0xFF)
      ..addByte((e.valueHandle >> 8) & 0xFF);
    if (is128) {
      out.add(_uuid128ToLeBytes(e.uuid128!));
    } else {
      out
        ..addByte(e.uuid16! & 0xFF)
        ..addByte((e.uuid16! >> 8) & 0xFF);
    }
  }
  return Uint8List.fromList([kAttReadByTypeResponse, ...out.takeBytes()]);
}

/// A Read By Group Type Response listing primary services.
Uint8List attReadByGroupTypeResponseServices(
  List<({int start, int end, int? uuid16, String? uuid128})> entries,
) {
  final is128 = entries.first.uuid128 != null;
  final itemLength = is128 ? 20 : 6;
  final out = BytesBuilder(copy: true)..addByte(itemLength);

  for (final e in entries) {
    out
      ..addByte(e.start & 0xFF)
      ..addByte((e.start >> 8) & 0xFF)
      ..addByte(e.end & 0xFF)
      ..addByte((e.end >> 8) & 0xFF);
    if (is128) {
      out.add(_uuid128ToLeBytes(e.uuid128!));
    } else {
      out
        ..addByte(e.uuid16! & 0xFF)
        ..addByte((e.uuid16! >> 8) & 0xFF);
    }
  }
  return Uint8List.fromList([kAttReadByGroupTypeResponse, ...out.takeBytes()]);
}

/// A Find Information Response listing 16-bit attribute types.
Uint8List attFindInformationResponse16(List<({int handle, int uuid16})> entries) {
  final out = BytesBuilder(copy: true)..addByte(0x01); // 16-bit UUID format
  for (final e in entries) {
    out
      ..addByte(e.handle & 0xFF)
      ..addByte((e.handle >> 8) & 0xFF)
      ..addByte(e.uuid16 & 0xFF)
      ..addByte((e.uuid16 >> 8) & 0xFF);
  }
  return Uint8List.fromList([kAttFindInformationResponse, ...out.takeBytes()]);
}

// -------------------------------------------------------------------- utils

Uint8List _addressToLeBytes(String address) {
  final parts = address.split(':').map((p) => int.parse(p, radix: 16)).toList();
  return Uint8List.fromList(parts.reversed.toList());
}

Uint8List _uuid128ToLeBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  final be = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    be.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(be.reversed.toList());
}

/// HCI → L2CAP → ATT decoding.
///
/// Turns the raw HCI packets in a snoop log into attribute-level operations.
/// The important word is *attribute*: this parser identifies which handle was
/// written, read or notified, and how large the payload was. It does not
/// interpret the payload. Whatever the Watch 6R's bytes mean, they come out of
/// here exactly as they went in (rule 4).
///
/// Two parts of this are not optional for our purpose:
///
/// * **L2CAP reassembly.** A watch-face image is far larger than the ATT MTU,
///   so it arrives as many ACL fragments. Reading fragments individually would
///   show shredded payloads and invent packet boundaries that do not exist.
/// * **Evidence-based handle resolution.** A handle only becomes a UUID if
///   this same capture contains the discovery response that says so. Handles
///   we never saw discovered stay unresolved (rules 1 and 3).
library;

import 'dart:typed_data';

// ---------------------------------------------------------------- constants

/// H4 packet type indicators, the first byte of each HCI UART packet.
const int kH4Command = 0x01;
const int kH4AclData = 0x02;
const int kH4SyncData = 0x03;
const int kH4Event = 0x04;
const int kH4IsoData = 0x05;

/// L2CAP channel identifier for the Attribute Protocol.
const int kCidAtt = 0x0004;

/// ATT protocol opcodes (Core Spec Vol 3, Part F, 3.4.8).
const int kAttErrorResponse = 0x01;
const int kAttExchangeMtuRequest = 0x02;
const int kAttExchangeMtuResponse = 0x03;
const int kAttFindInformationRequest = 0x04;
const int kAttFindInformationResponse = 0x05;
const int kAttFindByTypeValueRequest = 0x06;
const int kAttFindByTypeValueResponse = 0x07;
const int kAttReadByTypeRequest = 0x08;
const int kAttReadByTypeResponse = 0x09;
const int kAttReadRequest = 0x0A;
const int kAttReadResponse = 0x0B;
const int kAttReadBlobRequest = 0x0C;
const int kAttReadBlobResponse = 0x0D;
const int kAttReadMultipleRequest = 0x0E;
const int kAttReadMultipleResponse = 0x0F;
const int kAttReadByGroupTypeRequest = 0x10;
const int kAttReadByGroupTypeResponse = 0x11;
const int kAttWriteRequest = 0x12;
const int kAttWriteResponse = 0x13;
const int kAttPrepareWriteRequest = 0x16;
const int kAttPrepareWriteResponse = 0x17;
const int kAttExecuteWriteRequest = 0x18;
const int kAttExecuteWriteResponse = 0x19;
const int kAttHandleValueNotification = 0x1B;
const int kAttHandleValueIndication = 0x1D;
const int kAttHandleValueConfirmation = 0x1E;
const int kAttWriteCommand = 0x52;
const int kAttSignedWriteCommand = 0xD2;

/// GATT declaration UUIDs, as 16-bit assigned numbers.
const int kUuidPrimaryService = 0x2800;
const int kUuidSecondaryService = 0x2801;
const int kUuidCharacteristicDeclaration = 0x2803;
const int kUuidClientCharacteristicConfiguration = 0x2902;

/// ACL packet-boundary flag meaning "continuing fragment of a higher layer
/// message". Every other value starts a new L2CAP PDU.
const int kPbContinuingFragment = 0x01;

// -------------------------------------------------------------------- types

/// What an ATT packet did, in terms this app records.
enum AttOperation {
  writeRequest,
  writeCommand,
  writeResponse,
  readRequest,
  readResponse,
  notification,
  indication,
  confirmation,
  errorResponse,
  mtuExchange,
  discovery,
  other,
}

/// One decoded ATT packet.
class AttPacket {
  const AttPacket({
    required this.timestamp,
    required this.connectionHandle,
    required this.fromRemote,
    required this.opcode,
    required this.operation,
    required this.payload,
    this.attributeHandle,
    this.truncated = false,
  });

  final DateTime timestamp;
  final int connectionHandle;

  /// True when the watch sent it, false when the phone did.
  final bool fromRemote;

  final int opcode;
  final AttOperation operation;

  /// The attribute value only — ATT opcode and handle stripped off. Empty for
  /// operations that carry no value.
  final Uint8List payload;

  /// Attribute handle, when the opcode carries one.
  final int? attributeHandle;

  /// True when the underlying capture had bytes cut out of this packet.
  final bool truncated;
}

/// A connection observed in the capture.
class HciConnection {
  HciConnection({
    required this.handle,
    required this.peerAddress,
    required this.openedAt,
  });

  final int handle;

  /// Peer BD_ADDR in the usual display order (most significant byte first).
  final String peerAddress;

  final DateTime openedAt;
  DateTime? closedAt;
  int attPacketCount = 0;
}

/// What a capture contained, so the operator can choose what to import.
class HciParseSummary {
  HciParseSummary({
    required this.totalRecords,
    required this.aclRecords,
    required this.attPackets,
    required this.truncatedRecords,
    required this.droppedRecords,
    required this.connections,
    required this.firstTimestamp,
    required this.lastTimestamp,
    required this.unresolvedHandles,
  });

  final int totalRecords;
  final int aclRecords;
  final int attPackets;

  /// Records the capture itself truncated. Any conclusion drawn from these is
  /// unsafe, so they are counted and reported rather than quietly used.
  final int truncatedRecords;

  /// Packets the phone's stack dropped before they reached the log.
  final int droppedRecords;

  final List<HciConnection> connections;
  final DateTime? firstTimestamp;
  final DateTime? lastTimestamp;

  /// Attribute handles seen in traffic that this capture never identified.
  final Set<int> unresolvedHandles;
}

/// Handle → UUID knowledge built *only* from discovery seen in this capture.
class AttributeMap {
  final Map<int, String> _handleToCharacteristic = {};
  final Map<int, String> _handleToDescriptor = {};
  final List<({int start, int end, String uuid})> _serviceRanges = [];

  /// Characteristic UUID for a value handle, or null if this capture never
  /// told us. Null is a real answer, not a gap to be filled with a guess.
  String? characteristicFor(int handle) => _handleToCharacteristic[handle];

  String? descriptorFor(int handle) => _handleToDescriptor[handle];

  /// Service UUID whose discovered handle range contains [handle].
  String? serviceFor(int handle) {
    for (final range in _serviceRanges) {
      if (handle >= range.start && handle <= range.end) return range.uuid;
    }
    return null;
  }

  bool get isEmpty =>
      _handleToCharacteristic.isEmpty &&
      _handleToDescriptor.isEmpty &&
      _serviceRanges.isEmpty;

  int get knownCharacteristics => _handleToCharacteristic.length;
  int get knownServices => _serviceRanges.length;

  void recordCharacteristic(int valueHandle, String uuid) =>
      _handleToCharacteristic[valueHandle] = uuid;

  void recordDescriptor(int handle, String uuid) =>
      _handleToDescriptor[handle] = uuid;

  void recordService(int start, int end, String uuid) =>
      _serviceRanges.add((start: start, end: end, uuid: uuid));
}

// ------------------------------------------------------------------- parser

/// Decodes a stream of HCI packets into ATT operations.
///
/// Stateful by necessity: ACL fragments have to be reassembled across records,
/// a Read By Type Response can only be interpreted against the request that
/// preceded it, and connection handles only map to addresses because an
/// earlier event said so.
class HciParser {
  final Map<int, HciConnection> _connections = {};
  final Map<int, _Reassembly> _reassembly = {};
  final Map<int, int> _pendingReadByType = {};
  final Map<int, AttributeMap> _attributeMaps = {};
  final Set<int> _unresolvedHandles = {};

  int _totalRecords = 0;
  int _aclRecords = 0;
  int _attPackets = 0;
  int _truncatedRecords = 0;
  int _droppedRecords = 0;
  DateTime? _firstTimestamp;
  DateTime? _lastTimestamp;

  /// Connections seen so far.
  List<HciConnection> get connections => _connections.values.toList();

  /// Attribute knowledge for a connection, built from its own discovery.
  AttributeMap attributeMapFor(int connectionHandle) =>
      _attributeMaps.putIfAbsent(connectionHandle, AttributeMap.new);

  HciParseSummary get summary => HciParseSummary(
        totalRecords: _totalRecords,
        aclRecords: _aclRecords,
        attPackets: _attPackets,
        truncatedRecords: _truncatedRecords,
        droppedRecords: _droppedRecords,
        connections: connections,
        firstTimestamp: _firstTimestamp,
        lastTimestamp: _lastTimestamp,
        unresolvedHandles: Set.unmodifiable(_unresolvedHandles),
      );

  /// Feeds one H4 packet in. Returns the ATT packets it completed — usually
  /// zero or one, and zero for every fragment but the last of a reassembly.
  List<AttPacket> addPacket({
    required Uint8List data,
    required DateTime timestamp,
    required bool isReceived,
    required int cumulativeDrops,
    bool truncated = false,
  }) {
    _totalRecords++;
    _firstTimestamp ??= timestamp;
    _lastTimestamp = timestamp;
    if (truncated) _truncatedRecords++;
    if (cumulativeDrops > _droppedRecords) _droppedRecords = cumulativeDrops;

    if (data.isEmpty) return const [];

    switch (data[0]) {
      case kH4Event:
        _handleEvent(data, timestamp);
        return const [];
      case kH4AclData:
        _aclRecords++;
        return _handleAcl(data, timestamp, isReceived, truncated);
      default:
        // Commands, SCO and ISO carry nothing we need for GATT work.
        return const [];
    }
  }

  // ------------------------------------------------------------------ events

  void _handleEvent(Uint8List data, DateTime timestamp) {
    if (data.length < 3) return;
    final eventCode = data[1];
    final params = Uint8List.sublistView(data, 3);

    switch (eventCode) {
      case 0x05: // Disconnection Complete
        if (params.length < 4) return;
        final handle = _u16(params, 1) & 0x0FFF;
        _connections[handle]?.closedAt = timestamp;
        _reassembly.remove(handle);
      case 0x3E: // LE Meta Event
        if (params.isEmpty) return;
        // The first parameter byte is the subevent code; everything after it
        // is the subevent's own parameter list.
        final subParams = Uint8List.sublistView(params, 1);
        switch (params[0]) {
          case 0x01: // LE Connection Complete
          case 0x0A: // LE Enhanced Connection Complete
            // Both lay out status(1) handle(2) role(1) peer_address_type(1)
            // peer_address(6); the enhanced form only adds fields after that.
            _onLeConnectionComplete(subParams, timestamp, addressOffset: 5);
        }
    }
  }

  void _onLeConnectionComplete(
    Uint8List params,
    DateTime timestamp, {
    required int addressOffset,
  }) {
    // status(1) handle(2) role(1) peer_address_type(1) peer_address(6) ...
    if (params.length < addressOffset + 6) return;
    // A non-zero status means the connection was never established.
    if (params[0] != 0x00) return;

    final handle = _u16(params, 1) & 0x0FFF;
    final address = _formatAddress(
        Uint8List.sublistView(params, addressOffset, addressOffset + 6));
    _connections[handle] = HciConnection(
      handle: handle,
      peerAddress: address,
      openedAt: timestamp,
    );
  }

  // --------------------------------------------------------------------- acl

  List<AttPacket> _handleAcl(
    Uint8List data,
    DateTime timestamp,
    bool isReceived,
    bool truncated,
  ) {
    // type(1) handle+flags(2 LE) data_total_length(2 LE) payload
    if (data.length < 5) return const [];

    final handleAndFlags = _u16(data, 1);
    final connectionHandle = handleAndFlags & 0x0FFF;
    final pbFlag = (handleAndFlags >> 12) & 0x03;
    final declaredLength = _u16(data, 3);

    final payload = Uint8List.sublistView(data, 5);
    // Trust what is actually present over what the header claims: a truncated
    // capture will declare more than it stored.
    final fragment = payload.length > declaredLength
        ? Uint8List.sublistView(payload, 0, declaredLength)
        : payload;

    if (pbFlag == kPbContinuingFragment) {
      final pending = _reassembly[connectionHandle];
      if (pending == null) {
        // A continuation with no start: the capture began part-way through a
        // transfer. The missing head cannot be reconstructed, and inventing
        // one would be a fabrication, so the fragment is discarded.
        return const [];
      }
      pending.add(fragment);
      if (!pending.isComplete) return const [];

      _reassembly.remove(connectionHandle);
      // The CID belongs to the PDU that started the reassembly, so it has to
      // be read before the pending entry is dropped.
      if (pending.cid != kCidAtt) return const [];
      return _decodeAll(
          [pending.take()], connectionHandle, timestamp, isReceived, truncated);
    }

    // Start of a new L2CAP PDU: length(2 LE) cid(2 LE) payload
    if (fragment.length < 4) return const [];
    final pduLength = _u16(fragment, 0);
    final cid = _u16(fragment, 2);
    final body = Uint8List.sublistView(fragment, 4);

    if (body.length < pduLength) {
      // Fragmented. Hold it open regardless of CID so that a later
      // continuation is matched against the right PDU.
      _reassembly[connectionHandle] =
          _Reassembly(cid: cid, expectedLength: pduLength)..add(body);
      return const [];
    }

    if (cid != kCidAtt) return const [];
    return _decodeAll(
      [Uint8List.sublistView(body, 0, pduLength)],
      connectionHandle,
      timestamp,
      isReceived,
      truncated,
    );
  }

  List<AttPacket> _decodeAll(
    List<Uint8List> pdus,
    int connectionHandle,
    DateTime timestamp,
    bool isReceived,
    bool truncated,
  ) {
    final out = <AttPacket>[];
    for (final pdu in pdus) {
      final packet =
          _decodeAtt(pdu, connectionHandle, timestamp, isReceived, truncated);
      if (packet != null) out.add(packet);
    }
    return out;
  }

  // --------------------------------------------------------------------- att

  AttPacket? _decodeAtt(
    Uint8List pdu,
    int connectionHandle,
    DateTime timestamp,
    bool isReceived,
    bool truncated,
  ) {
    if (pdu.isEmpty) return null;
    final opcode = pdu[0];
    final body = Uint8List.sublistView(pdu, 1);
    final map = attributeMapFor(connectionHandle);

    int? attributeHandle;
    Uint8List payload = Uint8List(0);
    AttOperation operation;

    switch (opcode) {
      case kAttWriteRequest:
      case kAttWriteCommand:
      case kAttSignedWriteCommand:
        if (body.length < 2) return null;
        attributeHandle = _u16(body, 0);
        payload = Uint8List.sublistView(body, 2);
        operation = opcode == kAttWriteRequest
            ? AttOperation.writeRequest
            : AttOperation.writeCommand;

      case kAttWriteResponse:
        operation = AttOperation.writeResponse;

      case kAttReadRequest:
        if (body.length < 2) return null;
        attributeHandle = _u16(body, 0);
        operation = AttOperation.readRequest;

      case kAttReadResponse:
      case kAttReadBlobResponse:
        payload = body;
        operation = AttOperation.readResponse;

      case kAttHandleValueNotification:
      case kAttHandleValueIndication:
        if (body.length < 2) return null;
        attributeHandle = _u16(body, 0);
        payload = Uint8List.sublistView(body, 2);
        operation = opcode == kAttHandleValueNotification
            ? AttOperation.notification
            : AttOperation.indication;

      case kAttHandleValueConfirmation:
        operation = AttOperation.confirmation;

      case kAttErrorResponse:
        payload = body;
        operation = AttOperation.errorResponse;

      case kAttExchangeMtuRequest:
      case kAttExchangeMtuResponse:
        payload = body;
        operation = AttOperation.mtuExchange;

      case kAttReadByTypeRequest:
        // Remember which type was asked for: the response does not repeat it,
        // and without it the response cannot be interpreted.
        if (body.length >= 6) {
          _pendingReadByType[connectionHandle] = _u16(body, 4);
        }
        operation = AttOperation.discovery;

      case kAttReadByTypeResponse:
        _absorbReadByTypeResponse(connectionHandle, body, map);
        operation = AttOperation.discovery;

      case kAttReadByGroupTypeResponse:
        _absorbReadByGroupTypeResponse(body, map);
        operation = AttOperation.discovery;

      case kAttFindInformationResponse:
        _absorbFindInformationResponse(body, map);
        operation = AttOperation.discovery;

      case kAttFindInformationRequest:
      case kAttFindByTypeValueRequest:
      case kAttFindByTypeValueResponse:
      case kAttReadByGroupTypeRequest:
        operation = AttOperation.discovery;

      default:
        payload = body;
        operation = AttOperation.other;
    }

    _attPackets++;
    _connections[connectionHandle]?.attPacketCount++;

    if (attributeHandle != null &&
        map.characteristicFor(attributeHandle) == null &&
        map.descriptorFor(attributeHandle) == null) {
      _unresolvedHandles.add(attributeHandle);
    }

    return AttPacket(
      timestamp: timestamp,
      connectionHandle: connectionHandle,
      fromRemote: isReceived,
      opcode: opcode,
      operation: operation,
      payload: payload,
      attributeHandle: attributeHandle,
      truncated: truncated,
    );
  }

  /// Read By Type Response carrying characteristic declarations gives us the
  /// single most useful mapping: value handle → characteristic UUID.
  void _absorbReadByTypeResponse(
    int connectionHandle,
    Uint8List body,
    AttributeMap map,
  ) {
    final requestedType = _pendingReadByType[connectionHandle];
    if (requestedType != kUuidCharacteristicDeclaration) return;
    if (body.isEmpty) return;

    final itemLength = body[0];
    if (itemLength < 7) return;

    var offset = 1;
    while (offset + itemLength <= body.length) {
      final item = Uint8List.sublistView(body, offset, offset + itemLength);
      // declaration handle(2) properties(1) value handle(2) uuid(2 or 16)
      final valueHandle = _u16(item, 3);
      final uuidBytes = Uint8List.sublistView(item, 5);
      final uuid = _uuidFromLeBytes(uuidBytes);
      if (uuid != null) map.recordCharacteristic(valueHandle, uuid);
      offset += itemLength;
    }
  }

  /// Read By Group Type Response carrying service declarations gives handle
  /// ranges, which is how a characteristic gets attributed to a service.
  void _absorbReadByGroupTypeResponse(Uint8List body, AttributeMap map) {
    if (body.isEmpty) return;
    final itemLength = body[0];
    if (itemLength < 6) return;

    var offset = 1;
    while (offset + itemLength <= body.length) {
      final item = Uint8List.sublistView(body, offset, offset + itemLength);
      final start = _u16(item, 0);
      final end = _u16(item, 2);
      final uuid = _uuidFromLeBytes(Uint8List.sublistView(item, 4));
      if (uuid != null) map.recordService(start, end, uuid);
      offset += itemLength;
    }
  }

  /// Find Information Response enumerates handle → attribute type, which is
  /// how descriptors (notably the CCCD at 0x2902) become identifiable.
  void _absorbFindInformationResponse(Uint8List body, AttributeMap map) {
    if (body.isEmpty) return;
    final format = body[0];
    final uuidLength = switch (format) { 0x01 => 2, 0x02 => 16, _ => 0 };
    if (uuidLength == 0) return;

    final itemLength = 2 + uuidLength;
    var offset = 1;
    while (offset + itemLength <= body.length) {
      final handle = _u16(body, offset);
      final uuid = _uuidFromLeBytes(
          Uint8List.sublistView(body, offset + 2, offset + itemLength));
      if (uuid != null) map.recordDescriptor(handle, uuid);
      offset += itemLength;
    }
  }
}

// ------------------------------------------------------------------ helpers

class _Reassembly {
  _Reassembly({required this.cid, required this.expectedLength});

  final int cid;
  final int expectedLength;
  final BytesBuilder _builder = BytesBuilder(copy: true);

  void add(Uint8List fragment) => _builder.add(fragment);

  bool get isComplete => _builder.length >= expectedLength;

  Uint8List take() {
    final all = _builder.takeBytes();
    return all.length > expectedLength
        ? Uint8List.sublistView(all, 0, expectedLength)
        : all;
  }
}

int _u16(Uint8List bytes, int offset) =>
    bytes[offset] | (bytes[offset + 1] << 8);

/// Formats a BD_ADDR, which is transmitted least significant byte first.
String _formatAddress(Uint8List littleEndian) {
  final reversed = littleEndian.reversed
      .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'));
  return reversed.join(':');
}

/// Reads a UUID transmitted little-endian, as ATT does, into the canonical
/// big-endian dashed form.
String? _uuidFromLeBytes(Uint8List le) {
  if (le.length == 2) {
    final value = le[0] | (le[1] << 8);
    return '0000${value.toRadixString(16).padLeft(4, '0')}'
        '-0000-1000-8000-00805f9b34fb';
  }
  if (le.length == 16) {
    final be = Uint8List.fromList(le.reversed.toList());
    final hex = be.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
  return null;
}

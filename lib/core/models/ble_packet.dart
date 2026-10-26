/// The unit of evidence.
///
/// Every BLE operation this app performs or imports becomes exactly one
/// [BlePacket]. Packets are append-only, immutable and never rewritten
/// (rule 4), payloads are kept as hexadecimal (rule 6), and timestamps are
/// always preserved (rule 5).
///
/// A packet deliberately carries no interpretation of its payload. There are
/// no "command" or "opcode" fields, because we do not know that the Watch 6R
/// has such things. Interpretation lives in ProtocolObservation and
/// ProtocolHypothesis, where it must cite the packets that support it.
library;

import '../hex/hex_codec.dart';

/// Who sent the bytes.
enum PacketDirection {
  /// Phone → watch. Writes, read requests, subscribe/unsubscribe.
  phoneToWatch('phone_to_watch', 'PHONE → WATCH'),

  /// Watch → phone. Notifications, indications, read responses, advertisements.
  watchToPhone('watch_to_phone', 'WATCH → PHONE'),

  /// Neither: an event raised by the phone's own Bluetooth stack or by this
  /// app, such as a connection state change or a failed operation. Not part of
  /// the spec's two-direction model, but collapsing these into one of the
  /// other two would misattribute local events to the watch.
  local('local', 'LOCAL');

  const PacketDirection(this.wireName, this.label);

  /// Value used in stored and exported JSON. Stable; do not change.
  final String wireName;

  /// Human-readable form for the packet monitor.
  final String label;

  static PacketDirection fromWire(String wire) => values.firstWhere(
        (d) => d.wireName == wire,
        orElse: () => throw FormatException('unknown packet direction', wire),
      );
}

/// What was done.
///
/// Read and write are split into request/response where both halves are
/// observable, so that a live capture and an imported HCI capture describe the
/// same exchange the same way.
enum PacketOperation {
  scanResult('scan_result'),
  connect('connect'),
  disconnect('disconnect'),
  connectionStateChange('connection_state_change'),
  discoverServices('discover_services'),
  mtuChange('mtu_change'),
  readRequest('read_request'),
  readResponse('read_response'),
  write('write'),
  writeNoResponse('write_no_response'),
  writeResponse('write_response'),
  notify('notify'),
  indicate('indicate'),
  subscribe('subscribe'),
  unsubscribe('unsubscribe'),
  descriptorRead('descriptor_read'),
  descriptorWrite('descriptor_write'),
  error('error');

  const PacketOperation(this.wireName);

  final String wireName;

  static PacketOperation fromWire(String wire) => values.firstWhere(
        (o) => o.wireName == wire,
        orElse: () => throw FormatException('unknown packet operation', wire),
      );
}

/// Whether the operation succeeded. Failures are recorded as packets rather
/// than swallowed (rule 9) — a write that the watch rejected is evidence.
enum PacketStatus {
  ok('ok'),
  failed('failed');

  const PacketStatus(this.wireName);

  final String wireName;

  static PacketStatus fromWire(String wire) => values.firstWhere(
        (s) => s.wireName == wire,
        orElse: () => throw FormatException('unknown packet status', wire),
      );
}

class BlePacket {
  const BlePacket({
    this.id,
    required this.sessionId,
    required this.seq,
    required this.timestamp,
    required this.elapsedUs,
    required this.direction,
    required this.operation,
    required this.payloadHex,
    this.serviceUuid,
    this.characteristicUuid,
    this.descriptorUuid,
    this.attHandle,
    this.status = PacketStatus.ok,
    this.error,
    this.note,
    this.detail,
  });

  /// Database row id. Null until stored.
  final int? id;

  /// Owning capture session, or null for packets seen outside a session (the
  /// live monitor always runs; recording is what attaches them to a session).
  final String? sessionId;

  /// Position within the session. Preserves ordering when two packets share a
  /// timestamp, which happens readily at BLE speeds.
  final int seq;

  /// Wall-clock time, UTC, microsecond precision (rule 5).
  final DateTime timestamp;

  /// Microseconds since the session started, from a monotonic clock.
  ///
  /// Kept alongside [timestamp] on purpose: wall-clock time can jump (NTP
  /// correction, timezone change) and inter-packet timing is exactly the kind
  /// of thing we will want to measure when working out framing and ACKs.
  final int elapsedUs;

  final PacketDirection direction;
  final PacketOperation operation;

  /// Payload in compact uppercase hex, e.g. `AA0104007F`. Empty string for
  /// operations that carry no payload. Stored verbatim (rule 4).
  final String payloadHex;

  /// Canonical service UUID, when known. Null is meaningful: it records that
  /// we could not attribute the packet to a service, which is common for
  /// imported HCI captures where discovery was not part of the capture. We do
  /// not guess (rule 1, rule 3).
  final String? serviceUuid;
  final String? characteristicUuid;
  final String? descriptorUuid;

  /// ATT attribute handle, when the packet came from an HCI capture. Present
  /// even when the UUID is unknown, because the handle is the only identity
  /// such a packet has.
  final int? attHandle;

  final PacketStatus status;

  /// Verbatim error text when [status] is failed. Never summarised away.
  final String? error;

  /// Free-text operator annotation, e.g. "tapped Sync in Oraimo Health here".
  final String? note;

  /// Structured result of a local operation, for things that are not wire
  /// bytes and so must never go in [payloadHex] (rule 4). Today: the full
  /// attribute database returned by service discovery, so that the most
  /// important result of reconnaissance is part of the exported evidence
  /// rather than something read off the screen and transcribed by hand.
  final Map<String, dynamic>? detail;

  /// Payload length in bytes.
  int get payloadLength => payloadHex.length ~/ 2;

  /// Payload as bytes. Derived on demand; the hex string stays authoritative.
  List<int> get payloadBytes => hexToBytes(payloadHex);

  /// Space-grouped payload for display: `AA 01 04 00 7F`.
  String get payloadDisplay => hexToDisplay(payloadHex);

  /// ASCII rendering of the payload, for eyeballing text in unknown data.
  String get payloadAscii => bytesToAscii(payloadBytes);

  /// The best identifier available for the attribute this packet touched.
  String get attributeLabel {
    if (characteristicUuid != null) return characteristicUuid!;
    if (attHandle != null) {
      return 'handle 0x${attHandle!.toRadixString(16).padLeft(4, '0')}';
    }
    return '—';
  }

  BlePacket copyWith({int? id, String? sessionId, int? seq, int? elapsedUs}) =>
      BlePacket(
        id: id ?? this.id,
        sessionId: sessionId ?? this.sessionId,
        seq: seq ?? this.seq,
        timestamp: timestamp,
        elapsedUs: elapsedUs ?? this.elapsedUs,
        direction: direction,
        operation: operation,
        payloadHex: payloadHex,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
        attHandle: attHandle,
        status: status,
        error: error,
        note: note,
        detail: detail,
      );

  /// Export form. This shape is the project's most important artefact: later
  /// protocol analysis reads these files, so keys are additive-only.
  Map<String, dynamic> toJson() => {
        'seq': seq,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'elapsedUs': elapsedUs,
        'direction': direction.wireName,
        'operation': operation.wireName,
        'service': serviceUuid,
        'characteristic': characteristicUuid,
        'descriptor': descriptorUuid,
        'handle': attHandle == null
            ? null
            : '0x${attHandle!.toRadixString(16).padLeft(4, '0')}',
        'payload': payloadHex,
        'payloadLength': payloadLength,
        'status': status.wireName,
        'error': error,
        'note': note,
        // Added in export schema v2. Absent-or-null means "no structured
        // detail", which is every packet except service discovery.
        'detail': detail,
      };

  factory BlePacket.fromJson(Map<String, dynamic> json) => BlePacket(
        sessionId: json['sessionId'] as String?,
        seq: json['seq'] as int,
        timestamp: DateTime.parse(json['timestamp'] as String),
        elapsedUs: json['elapsedUs'] as int? ?? 0,
        direction: PacketDirection.fromWire(json['direction'] as String),
        operation: PacketOperation.fromWire(json['operation'] as String),
        payloadHex: json['payload'] as String? ?? '',
        serviceUuid: json['service'] as String?,
        characteristicUuid: json['characteristic'] as String?,
        descriptorUuid: json['descriptor'] as String?,
        attHandle: _parseHandle(json['handle']),
        status: json['status'] == null
            ? PacketStatus.ok
            : PacketStatus.fromWire(json['status'] as String),
        error: json['error'] as String?,
        note: json['note'] as String?,
        detail: (json['detail'] as Map?)?.cast<String, dynamic>(),
      );

  static int? _parseHandle(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw;
    final s = (raw as String).toLowerCase();
    return int.parse(s.startsWith('0x') ? s.substring(2) : s, radix: 16);
  }
}

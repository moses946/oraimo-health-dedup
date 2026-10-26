/// The single stream every BLE operation flows through.
///
/// Phase 4 requires that every BLE operation generate an event. Rather than
/// dotting emit calls through the UI — where an unexercised code path would
/// silently stop recording — operations are observed at one point: the
/// InstrumentedBleTransport decorator publishes here, and both the live packet
/// monitor and the capture recorder subscribe.
///
/// Events are emitted for failures as well as successes (rule 9).
library;

import 'dart:async';
import 'dart:collection';

import '../models/ble_packet.dart';

class BleEventBus {
  BleEventBus({this.bufferSize = 2000}) : _clock = Stopwatch()..start();

  /// How many recent packets the live monitor can show without a session.
  /// Bounded so a long-running scan cannot exhaust memory; anything that must
  /// be kept belongs in a capture session, which is stored.
  final int bufferSize;

  final Stopwatch _clock;
  final ListQueue<BlePacket> _recent = ListQueue<BlePacket>();
  final StreamController<BlePacket> _controller =
      StreamController<BlePacket>.broadcast();

  int _seq = 0;

  /// Every packet, live.
  Stream<BlePacket> get stream => _controller.stream;

  /// The recent buffer, oldest first.
  List<BlePacket> get recent => List.unmodifiable(_recent);

  /// Microseconds since the bus started. Monotonic: unaffected by clock
  /// changes, which matters for measuring inter-packet timing.
  int get elapsedUs => _clock.elapsedMicroseconds;

  /// Publishes one event.
  ///
  /// [sessionId] is left null here on purpose — attaching a packet to a session
  /// is the recorder's job, and the monitor runs whether or not anything is
  /// being recorded.
  BlePacket emit({
    required PacketDirection direction,
    required PacketOperation operation,
    String payloadHex = '',
    String? serviceUuid,
    String? characteristicUuid,
    String? descriptorUuid,
    int? attHandle,
    PacketStatus status = PacketStatus.ok,
    String? error,
    String? note,
    Map<String, dynamic>? detail,
  }) {
    final packet = BlePacket(
      sessionId: null,
      seq: _seq++,
      timestamp: DateTime.now().toUtc(),
      elapsedUs: _clock.elapsedMicroseconds,
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

    _recent.addLast(packet);
    while (_recent.length > bufferSize) {
      _recent.removeFirst();
    }
    if (!_controller.isClosed) _controller.add(packet);
    return packet;
  }

  /// Clears the live buffer. Does not touch anything already recorded into a
  /// session — stored evidence is never deleted as a side effect of a UI
  /// action.
  void clearBuffer() => _recent.clear();

  Future<void> dispose() => _controller.close();
}

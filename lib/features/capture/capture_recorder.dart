/// Attaches live BLE events to a capture session.
///
/// The packet monitor always runs; recording is what makes those packets
/// durable evidence. Keeping the two separate means you can watch traffic
/// while deciding whether it is worth recording, and it means starting a
/// recording never has to reconfigure the BLE layer.
library;

import 'dart:async';

import '../../core/logging/app_logger.dart';
import '../../core/logging/ble_event_bus.dart';
import '../../core/models/ble_packet.dart';
import '../../core/models/capture_session.dart';
import '../../core/storage/research_repository.dart';

const String _tag = 'capture';

class CaptureRecorder {
  CaptureRecorder(this._bus, this._repository, this._logger);

  final BleEventBus _bus;
  final ResearchRepository _repository;
  final AppLogger _logger;

  StreamSubscription<BlePacket>? _subscription;
  CaptureSession? _session;
  int _seq = 0;

  /// Bus-relative elapsed time when recording began, so each session's
  /// elapsed offsets start at zero while staying monotonic.
  int _baseElapsedUs = 0;

  /// Packets that arrived but have not been written yet.
  ///
  /// Buffered because BLE events arrive faster than individual SQLite inserts
  /// complete during a bulk transfer; dropping them would lose exactly the
  /// evidence a transfer capture exists to collect.
  final List<BlePacket> _pending = [];
  Timer? _flushTimer;
  bool _flushing = false;

  CaptureSession? get session => _session;

  bool get isRecording => _session != null;

  /// Starts recording into a new session.
  Future<CaptureSession> start({
    required String id,
    required String name,
    String? deviceAddress,
    String? deviceName,
    String? notes,
  }) async {
    if (_session != null) {
      throw StateError('already recording into "${_session!.name}"');
    }

    final session = CaptureSession(
      id: id,
      name: name,
      source: CaptureSource.live,
      startedAt: DateTime.now().toUtc(),
      deviceAddress: deviceAddress,
      deviceName: deviceName,
      notes: notes,
    );
    await _repository.insertSession(session);

    _session = session;
    _seq = 0;
    _baseElapsedUs = _bus.elapsedUs;
    _subscription = _bus.stream.listen(_onPacket);
    _flushTimer =
        Timer.periodic(const Duration(milliseconds: 250), (_) => _flush());

    _logger.info(_tag, 'recording started: "$name" ($id)');
    return session;
  }

  /// Stops recording and flushes anything still buffered.
  Future<CaptureSession?> stop() async {
    final session = _session;
    if (session == null) return null;

    // Let events already queued on the bus reach the listener before it is
    // torn down. The bus is an asynchronous broadcast stream, so an operation
    // that completed just before stop() may still be in flight, and cancelling
    // straight away would silently drop it.
    await Future<void>.delayed(Duration.zero);

    await _subscription?.cancel();
    _subscription = null;
    _flushTimer?.cancel();
    _flushTimer = null;

    await _flush();

    final ended = session.copyWith(
      endedAt: DateTime.now().toUtc(),
      packetCount: await _repository.countPackets(session.id),
    );
    await _repository.updateSession(ended);

    _session = null;
    _logger.info(
      _tag,
      'recording stopped: "${ended.name}" (${ended.packetCount} packets)',
    );
    return ended;
  }

  /// Annotates the session with what the operator was doing.
  ///
  /// The single most useful thing in a capture six weeks later.
  Future<void> addNote(String note) async {
    final session = _session;
    if (session == null) return;
    final existing = session.notes;
    final stamped = '${DateTime.now().toUtc().toIso8601String()}  $note';
    final updated = session.copyWith(
      notes: existing == null || existing.isEmpty
          ? stamped
          : '$existing\n$stamped',
    );
    _session = updated;
    await _repository.updateSession(updated);
  }

  void _onPacket(BlePacket packet) {
    final session = _session;
    if (session == null) return;
    _pending.add(packet.copyWith(
      sessionId: session.id,
      seq: _seq++,
    ));
  }

  Future<void> _flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    final batch = List<BlePacket>.from(_pending);
    _pending.clear();
    try {
      // copyWith rather than rebuilding the packet field by field: a rebuild
      // silently drops any field added to BlePacket later.
      await _repository.insertPackets(batch.map(
          (p) => p.copyWith(elapsedUs: p.elapsedUs - _baseElapsedUs)));
    } catch (e, s) {
      // Put them back rather than losing them; a failed write is reported, not
      // swallowed (rule 9).
      _pending.insertAll(0, batch);
      _logger.error(_tag, 'failed to persist ${batch.length} packets', e, s);
    } finally {
      _flushing = false;
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _flushTimer?.cancel();
    await _flush();
  }
}

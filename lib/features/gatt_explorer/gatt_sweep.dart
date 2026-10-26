/// Read every readable characteristic, or subscribe to every notifying one.
///
/// The first look at an unknown device should miss nothing. A watch may push
/// events on characteristics nobody thought to subscribe to, and a value that
/// nobody read is evidence nobody has. Doing this one characteristic at a time
/// by hand invites gaps.
///
/// Every operation goes through the transport the caller supplies — in the
/// app, the instrumented one — so each read, subscription and failure is
/// recorded in the packet log and in any running capture session.
library;

import '../../core/bluetooth/ble_transport.dart';
import '../../core/models/gatt_models.dart';

enum SweepAction { read, subscribe }

class SweepOutcome {
  const SweepOutcome({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.action,
    this.error,
    this.valueLength,
  });

  final String serviceUuid;
  final String characteristicUuid;
  final SweepAction action;

  /// The platform's error text, verbatim, when the operation failed.
  final String? error;

  /// Bytes returned, for a successful read.
  final int? valueLength;

  bool get ok => error == null;
}

class SweepReport {
  const SweepReport({
    required this.action,
    required this.outcomes,
    this.notAttempted = 0,
    this.stoppedReason,
  });

  final SweepAction action;
  final List<SweepOutcome> outcomes;

  /// Characteristics left untouched because the sweep stopped early.
  final int notAttempted;

  /// Why the sweep stopped early, or null if it ran to the end.
  final String? stoppedReason;

  int get succeeded => outcomes.where((o) => o.ok).length;
  List<SweepOutcome> get failures => outcomes.where((o) => !o.ok).toList();
}

class GattSweep {
  GattSweep(this._transport);

  final BleTransport _transport;

  /// Reads every characteristic that declares READ.
  Future<SweepReport> readAll(List<GattService> services) => _sweep(
        SweepAction.read,
        _characteristics(services).where((c) => c.properties.read),
        (c) async {
          final value = await _transport.readCharacteristic(
            serviceUuid: c.serviceUuid,
            characteristicUuid: c.uuid,
          );
          return value.length;
        },
      );

  /// Subscribes to every characteristic that declares NOTIFY or INDICATE and
  /// is not already subscribed.
  Future<SweepReport> subscribeAll(List<GattService> services) {
    final already = _transport.subscribedCharacteristics;
    return _sweep(
      SweepAction.subscribe,
      _characteristics(services).where(
          (c) => c.properties.isSubscribable && !already.contains(c.uuid)),
      (c) async {
        await _transport.subscribe(
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.uuid,
        );
        return null;
      },
    );
  }

  Future<SweepReport> _sweep(
    SweepAction action,
    Iterable<GattCharacteristic> targets,
    Future<int?> Function(GattCharacteristic) operate,
  ) async {
    final list = targets.toList();
    final outcomes = <SweepOutcome>[];

    // Sequential on purpose: BLE allows one outstanding GATT operation at a
    // time, and firing them concurrently only moves the queueing into the
    // platform where its failures are harder to attribute.
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      try {
        final length = await operate(c);
        outcomes.add(SweepOutcome(
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.uuid,
          action: action,
          valueLength: length,
        ));
      } on BleConnectionException catch (e) {
        // The link is gone. Every remaining attempt would fail the same way
        // and bury the one error that matters, so stop and say so.
        outcomes.add(SweepOutcome(
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.uuid,
          action: action,
          error: e.toString(),
        ));
        return SweepReport(
          action: action,
          outcomes: outcomes,
          notAttempted: list.length - i - 1,
          stoppedReason: 'connection lost: $e',
        );
      } on BleTransportException catch (e) {
        // A refusal on one characteristic is evidence about that
        // characteristic, not a reason to skip the rest.
        outcomes.add(SweepOutcome(
          serviceUuid: c.serviceUuid,
          characteristicUuid: c.uuid,
          action: action,
          error: e.toString(),
        ));
      }
    }
    return SweepReport(action: action, outcomes: outcomes);
  }

  static Iterable<GattCharacteristic> _characteristics(
          List<GattService> services) =>
      services.expand((s) => s.characteristics);
}

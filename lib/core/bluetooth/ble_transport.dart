/// The BLE transport interface.
///
/// Rule 7: transport is separated from protocol interpretation. Everything in
/// this file moves bytes to and from a GATT attribute. Nothing here knows what
/// any byte means, and nothing here is specific to the Watch 6R — there are no
/// hard-coded UUIDs (rule 1), no packet construction and no framing.
///
/// The interface exists so the connection logic can be exercised in tests
/// without a radio, and so a different BLE plugin could be substituted without
/// touching anything above it.
library;

import 'dart:typed_data';

import '../models/ble_device_record.dart';
import '../models/gatt_models.dart';

/// Connection states surfaced to the UI. Every one of these is shown to the
/// user verbatim; none of them is hidden or collapsed (Phase 2 requirement).
enum BleConnectionState {
  disconnected('Disconnected'),
  connecting('Connecting'),
  connected('Connected'),
  reconnecting('Reconnecting'),
  disconnecting('Disconnecting'),
  error('Error');

  const BleConnectionState(this.label);

  final String label;
}

/// State of the phone's own Bluetooth radio.
enum BleAdapterState {
  unknown('Unknown'),
  unavailable('Not supported on this device'),
  unauthorized('Permission not granted'),
  off('Bluetooth is off'),
  turningOn('Turning on'),
  turningOff('Turning off'),
  on('Ready');

  const BleAdapterState(this.label);

  final String label;

  bool get isReady => this == BleAdapterState.on;
}

/// Base class for transport failures.
///
/// These are surfaced, never swallowed (rule 9). [detail] carries the
/// platform's own message unaltered, because the exact GATT status code is
/// frequently the most informative thing about a failed operation.
class BleTransportException implements Exception {
  BleTransportException(this.message, {this.detail, this.cause});

  final String message;
  final String? detail;
  final Object? cause;

  @override
  String toString() =>
      detail == null ? message : '$message: $detail';
}

class BlePermissionException extends BleTransportException {
  BlePermissionException(super.message, {super.detail, super.cause});
}

class BleAdapterOffException extends BleTransportException {
  BleAdapterOffException(super.message, {super.detail, super.cause});
}

class BleConnectionException extends BleTransportException {
  BleConnectionException(super.message, {super.detail, super.cause});
}

class BleOperationException extends BleTransportException {
  BleOperationException(
    super.message, {
    super.detail,
    super.cause,
    this.serviceUuid,
    this.characteristicUuid,
  });

  final String? serviceUuid;
  final String? characteristicUuid;
}

/// A value arriving from a subscribed characteristic.
class CharacteristicValue {
  const CharacteristicValue({
    required this.serviceUuid,
    required this.characteristicUuid,
    required this.value,
    required this.receivedAt,
  });

  final String serviceUuid;
  final String characteristicUuid;
  final Uint8List value;
  final DateTime receivedAt;
}

/// Moves bytes. Knows nothing about what they mean.
abstract class BleTransport {
  /// Current adapter state, and changes to it.
  Stream<BleAdapterState> get adapterState;

  Future<BleAdapterState> currentAdapterState();

  /// Requests the runtime permissions scanning and connecting need.
  ///
  /// Returns true only when every required permission was granted. Never
  /// throws for a plain denial — a refused permission is a normal outcome the
  /// UI has to render, not an error.
  Future<bool> requestPermissions();

  /// Devices seen while scanning. Emits repeatedly for the same device as
  /// fresh advertisements arrive, so RSSI can be tracked live.
  Stream<BleDeviceRecord> get scanResults;

  /// Whether a scan is currently running.
  Stream<bool> get isScanning;

  /// Starts scanning. [timeout] bounds the scan so a forgotten scan cannot
  /// drain the battery.
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)});

  Future<void> stopScan();

  /// Connection state of the currently selected device.
  Stream<BleConnectionState> get connectionState;

  BleConnectionState get currentConnectionState;

  /// The device currently connected or being connected to.
  String? get connectedDeviceAddress;

  Future<void> connect(
    String deviceAddress, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  });

  Future<void> disconnect();

  /// Discovers the full attribute database.
  Future<List<GattService>> discoverServices();

  /// Negotiated ATT MTU, if the platform reports it.
  ///
  /// Worth surfacing: the MTU sets the largest payload a single write can
  /// carry, which bounds any fragmentation scheme the watch uses.
  Future<int?> requestMtu(int desiredMtu);

  Stream<int> get mtu;

  Future<Uint8List> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  });

  Future<void> writeCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List value,
    required bool withoutResponse,
  });

  Future<Uint8List> readDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
  });

  Future<void> writeDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
    required Uint8List value,
  });

  /// Values arriving from every subscribed characteristic.
  Stream<CharacteristicValue> get characteristicValues;

  Future<void> subscribe({
    required String serviceUuid,
    required String characteristicUuid,
  });

  Future<void> unsubscribe({
    required String serviceUuid,
    required String characteristicUuid,
  });

  /// Characteristics currently subscribed, as canonical UUID strings.
  Set<String> get subscribedCharacteristics;

  Future<void> dispose();
}

/// Observation layer.
///
/// Wraps any [BleTransport] and publishes one event per operation to the
/// [BleEventBus] — successes and failures alike. Keeping this in a decorator
/// rather than inside the plugin adapter means the recording behaviour is
/// testable against a fake radio, and that no future edit to the transport can
/// quietly stop an operation being recorded.
///
/// This layer still interprets nothing. It records that bytes moved, not what
/// they meant.
library;

import 'dart:async';
import 'dart:typed_data';

import '../hex/hex_codec.dart';
import '../logging/ble_event_bus.dart';
import '../models/ble_device_record.dart';
import '../models/ble_packet.dart';
import '../models/gatt_models.dart';
import 'ble_transport.dart';

class InstrumentedBleTransport implements BleTransport {
  InstrumentedBleTransport(this._inner, this._bus) {
    // Notifications and indications originate at the watch, so they are
    // recorded here rather than at a call site — nothing on the phone asks
    // for them.
    _valueSub = _inner.characteristicValues.listen((value) {
      _bus.emit(
        direction: PacketDirection.watchToPhone,
        operation: PacketOperation.notify,
        serviceUuid: value.serviceUuid,
        characteristicUuid: value.characteristicUuid,
        payloadHex: bytesToHex(value.value),
      );
    });

    _stateSub = _inner.connectionState.listen((state) {
      _bus.emit(
        direction: PacketDirection.local,
        operation: PacketOperation.connectionStateChange,
        note: state.label,
      );
    });

    _mtuSub = _inner.mtu.listen((mtu) {
      _bus.emit(
        direction: PacketDirection.local,
        operation: PacketOperation.mtuChange,
        note: 'MTU $mtu',
      );
    });
  }

  final BleTransport _inner;
  final BleEventBus _bus;

  StreamSubscription<CharacteristicValue>? _valueSub;
  StreamSubscription<BleConnectionState>? _stateSub;
  StreamSubscription<int>? _mtuSub;

  // ------------------------------------------------------- passthrough only

  @override
  Stream<BleAdapterState> get adapterState => _inner.adapterState;

  @override
  Future<BleAdapterState> currentAdapterState() => _inner.currentAdapterState();

  @override
  Future<bool> requestPermissions() => _inner.requestPermissions();

  @override
  Stream<bool> get isScanning => _inner.isScanning;

  @override
  Stream<BleConnectionState> get connectionState => _inner.connectionState;

  @override
  BleConnectionState get currentConnectionState => _inner.currentConnectionState;

  @override
  String? get connectedDeviceAddress => _inner.connectedDeviceAddress;

  @override
  Stream<int> get mtu => _inner.mtu;

  @override
  Stream<CharacteristicValue> get characteristicValues =>
      _inner.characteristicValues;

  @override
  Set<String> get subscribedCharacteristics => _inner.subscribedCharacteristics;

  // --------------------------------------------------------------- observed

  @override
  Stream<BleDeviceRecord> get scanResults => _inner.scanResults;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) =>
      _observe(
        direction: PacketDirection.local,
        operation: PacketOperation.scanResult,
        note: 'scan started',
        action: () => _inner.startScan(timeout: timeout),
      );

  @override
  Future<void> stopScan() => _observe(
        direction: PacketDirection.local,
        operation: PacketOperation.scanResult,
        note: 'scan stopped',
        action: _inner.stopScan,
      );

  @override
  Future<void> connect(
    String deviceAddress, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) =>
      _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.connect,
        note: deviceAddress,
        action: () => _inner.connect(
          deviceAddress,
          timeout: timeout,
          autoConnect: autoConnect,
        ),
      );

  @override
  Future<void> disconnect() => _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.disconnect,
        note: _inner.connectedDeviceAddress,
        action: _inner.disconnect,
      );

  @override
  Future<List<GattService>> discoverServices() => _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.discoverServices,
        action: _inner.discoverServices,
        describeResult: (services) {
          final characteristics = services.fold<int>(
              0, (sum, s) => sum + s.characteristics.length);
          return '${services.length} services, $characteristics characteristics';
        },
      );

  @override
  Future<int?> requestMtu(int desiredMtu) => _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.mtuChange,
        note: 'requested $desiredMtu',
        action: () => _inner.requestMtu(desiredMtu),
      );

  @override
  Future<Uint8List> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    // A read is two observable events: the request we send and the value that
    // comes back. Recording both keeps a live capture shaped like the HCI
    // capture of the same exchange.
    _bus.emit(
      direction: PacketDirection.phoneToWatch,
      operation: PacketOperation.readRequest,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
    );
    try {
      final value = await _inner.readCharacteristic(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
      _bus.emit(
        direction: PacketDirection.watchToPhone,
        operation: PacketOperation.readResponse,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        payloadHex: bytesToHex(value),
      );
      return value;
    } catch (e) {
      _emitFailure(
        operation: PacketOperation.readResponse,
        error: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
      rethrow;
    }
  }

  @override
  Future<void> writeCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List value,
    required bool withoutResponse,
  }) async {
    final operation = withoutResponse
        ? PacketOperation.writeNoResponse
        : PacketOperation.write;
    _bus.emit(
      direction: PacketDirection.phoneToWatch,
      operation: operation,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      payloadHex: bytesToHex(value),
    );
    try {
      await _inner.writeCharacteristic(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        value: value,
        withoutResponse: withoutResponse,
      );
      if (!withoutResponse) {
        _bus.emit(
          direction: PacketDirection.watchToPhone,
          operation: PacketOperation.writeResponse,
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
        );
      }
    } catch (e) {
      _emitFailure(
        operation: operation,
        error: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        payloadHex: bytesToHex(value),
      );
      rethrow;
    }
  }

  @override
  Future<Uint8List> readDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
  }) async {
    try {
      final value = await _inner.readDescriptor(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
      );
      _bus.emit(
        direction: PacketDirection.watchToPhone,
        operation: PacketOperation.descriptorRead,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
        payloadHex: bytesToHex(value),
      );
      return value;
    } catch (e) {
      _emitFailure(
        operation: PacketOperation.descriptorRead,
        error: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
      );
      rethrow;
    }
  }

  @override
  Future<void> writeDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
    required Uint8List value,
  }) async {
    _bus.emit(
      direction: PacketDirection.phoneToWatch,
      operation: PacketOperation.descriptorWrite,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      descriptorUuid: descriptorUuid,
      payloadHex: bytesToHex(value),
    );
    try {
      await _inner.writeDescriptor(
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
        value: value,
      );
    } catch (e) {
      _emitFailure(
        operation: PacketOperation.descriptorWrite,
        error: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        descriptorUuid: descriptorUuid,
        payloadHex: bytesToHex(value),
      );
      rethrow;
    }
  }

  @override
  Future<void> subscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) =>
      _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.subscribe,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        action: () => _inner.subscribe(
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
        ),
      );

  @override
  Future<void> unsubscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) =>
      _observe(
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.unsubscribe,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        action: () => _inner.unsubscribe(
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
        ),
      );

  @override
  Future<void> dispose() async {
    await _valueSub?.cancel();
    await _stateSub?.cancel();
    await _mtuSub?.cancel();
    await _inner.dispose();
  }

  // --------------------------------------------------------------- helpers

  /// Runs [action], emitting one event for the outcome. A thrown exception is
  /// recorded and then rethrown: the caller still sees the failure, and so
  /// does the packet log (rule 9).
  Future<T> _observe<T>({
    required PacketDirection direction,
    required PacketOperation operation,
    required Future<T> Function() action,
    String? serviceUuid,
    String? characteristicUuid,
    String? note,
    String Function(T result)? describeResult,
  }) async {
    try {
      final result = await action();
      _bus.emit(
        direction: direction,
        operation: operation,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        note: describeResult != null ? describeResult(result) : note,
      );
      return result;
    } catch (e) {
      _emitFailure(
        operation: operation,
        error: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
        note: note,
      );
      rethrow;
    }
  }

  void _emitFailure({
    required PacketOperation operation,
    required Object error,
    String? serviceUuid,
    String? characteristicUuid,
    String? descriptorUuid,
    String? payloadHex,
    String? note,
  }) {
    _bus.emit(
      direction: PacketDirection.local,
      operation: PacketOperation.error,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      descriptorUuid: descriptorUuid,
      payloadHex: payloadHex ?? '',
      status: PacketStatus.failed,
      // The platform's own wording, unaltered: the GATT status code in it is
      // often the most informative part of a failure.
      error: '${operation.wireName} failed: $error',
      note: note,
    );
  }
}

/// A BleTransport with no radio behind it.
///
/// Lets the connection state machine, the recorder and the instrumentation be
/// tested for real — including failure paths that are awkward to provoke with
/// actual hardware, like a connect timeout or a rejected write.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/models/ble_device_record.dart';
import 'package:oraimo_lab/core/models/gatt_models.dart';

class FakeBleTransport implements BleTransport {
  FakeBleTransport({
    this.adapter = BleAdapterState.on,
    this.permissionsGranted = true,
  });

  BleAdapterState adapter;
  bool permissionsGranted;

  /// Set to make the next [connect] fail.
  Object? connectError;

  /// Set to make the next characteristic operation fail.
  Object? operationError;

  /// Number of connect attempts, for asserting on retry behaviour.
  int connectAttempts = 0;

  /// Values [readCharacteristic] returns, keyed by characteristic UUID.
  final Map<String, Uint8List> readValues = {};

  /// Every write that reached the transport, in order.
  final List<({String characteristicUuid, Uint8List value, bool withoutResponse})>
      writes = [];

  List<GattService> services = const [];

  final _adapterController = StreamController<BleAdapterState>.broadcast();
  final _scanController = StreamController<BleDeviceRecord>.broadcast();
  final _isScanningController = StreamController<bool>.broadcast();
  final _connectionController =
      StreamController<BleConnectionState>.broadcast();
  final _valueController = StreamController<CharacteristicValue>.broadcast();
  final _mtuController = StreamController<int>.broadcast();

  BleConnectionState _state = BleConnectionState.disconnected;
  String? _address;
  final Set<String> _subscribed = {};
  bool disposed = false;

  // -------------------------------------------------------- test affordances

  void emitScanResult(BleDeviceRecord device) => _scanController.add(device);

  void emitAdapterState(BleAdapterState state) {
    adapter = state;
    _adapterController.add(state);
  }

  /// Simulates the watch dropping the link.
  void dropConnection() => _setState(BleConnectionState.disconnected);

  /// Simulates a notification arriving from the watch.
  void emitNotification(String serviceUuid, String characteristicUuid, List<int> value) {
    _valueController.add(CharacteristicValue(
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
      value: Uint8List.fromList(value),
      receivedAt: DateTime.now().toUtc(),
    ));
  }

  // ------------------------------------------------------------- transport

  @override
  Stream<BleAdapterState> get adapterState => _adapterController.stream;

  @override
  Future<BleAdapterState> currentAdapterState() async => adapter;

  @override
  Future<bool> requestPermissions() async => permissionsGranted;

  @override
  Stream<BleDeviceRecord> get scanResults => _scanController.stream;

  @override
  Stream<bool> get isScanning => _isScanningController.stream;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    if (!adapter.isReady) {
      throw BleAdapterOffException('cannot scan', detail: adapter.label);
    }
    _isScanningController.add(true);
  }

  @override
  Future<void> stopScan() async => _isScanningController.add(false);

  @override
  Stream<BleConnectionState> get connectionState => _connectionController.stream;

  @override
  BleConnectionState get currentConnectionState => _state;

  @override
  String? get connectedDeviceAddress => _address;

  @override
  Future<void> connect(
    String deviceAddress, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    connectAttempts++;
    if (!adapter.isReady) {
      _setState(BleConnectionState.error);
      throw BleAdapterOffException('cannot connect', detail: adapter.label);
    }
    _setState(BleConnectionState.connecting);
    final error = connectError;
    if (error != null) {
      _setState(BleConnectionState.error);
      throw error;
    }
    _address = deviceAddress;
    _setState(BleConnectionState.connected);
  }

  @override
  Future<void> disconnect() async {
    _subscribed.clear();
    _address = null;
    _setState(BleConnectionState.disconnected);
  }

  @override
  Future<List<GattService>> discoverServices() async {
    _requireConnected();
    return services;
  }

  @override
  Stream<int> get mtu => _mtuController.stream;

  @override
  Future<int?> requestMtu(int desiredMtu) async {
    _mtuController.add(desiredMtu);
    return desiredMtu;
  }

  @override
  Future<Uint8List> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
    return readValues[characteristicUuid] ?? Uint8List(0);
  }

  @override
  Future<void> writeCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List value,
    required bool withoutResponse,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
    writes.add((
      characteristicUuid: characteristicUuid,
      value: value,
      withoutResponse: withoutResponse,
    ));
  }

  @override
  Future<Uint8List> readDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
    return Uint8List(0);
  }

  @override
  Future<void> writeDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
    required Uint8List value,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
  }

  @override
  Stream<CharacteristicValue> get characteristicValues => _valueController.stream;

  @override
  Set<String> get subscribedCharacteristics => Set.unmodifiable(_subscribed);

  @override
  Future<void> subscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
    _subscribed.add(characteristicUuid);
  }

  @override
  Future<void> unsubscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    _requireConnected();
    _maybeFail(serviceUuid, characteristicUuid);
    _subscribed.remove(characteristicUuid);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _adapterController.close();
    await _scanController.close();
    await _isScanningController.close();
    await _connectionController.close();
    await _valueController.close();
    await _mtuController.close();
  }

  void _setState(BleConnectionState state) {
    if (_state == state) return;
    _state = state;
    _connectionController.add(state);
  }

  void _requireConnected() {
    if (_state != BleConnectionState.connected) {
      throw BleConnectionException('not connected to any device');
    }
  }

  void _maybeFail(String serviceUuid, String characteristicUuid) {
    final error = operationError;
    if (error != null) {
      operationError = null;
      throw error;
    }
  }
}

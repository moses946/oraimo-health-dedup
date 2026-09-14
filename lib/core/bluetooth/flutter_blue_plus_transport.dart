/// The real BLE transport, backed by flutter_blue_plus.
///
/// This is the only file in the project that talks to the BLE plugin. It
/// translates the plugin's types into the app's own and raises typed
/// exceptions carrying the platform's verbatim error text; it interprets no
/// payload bytes and hard-codes no UUIDs.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;

import '../logging/app_logger.dart';
import '../models/ble_device_record.dart';
import '../models/ble_uuid.dart';
import '../models/gatt_models.dart';
import '../hex/hex_codec.dart';
import 'ble_transport.dart';

const String _tag = 'ble';

/// flutter_blue_plus 2.x is no longer BSD licensed: it requires callers to
/// declare a licence tier, and for-profit use needs a paid commercial one.
/// This project is a personal research tool for a watch its author owns, which
/// is what [fbp.License.nonprofit] covers. Anyone commercialising a build of
/// this app has to change this and buy the commercial licence.
const fbp.License _fbpLicense = fbp.License.nonprofit;

class FlutterBluePlusTransport implements BleTransport {
  FlutterBluePlusTransport(this._logger, [this._permissionRequester]) {
    _adapterSub = fbp.FlutterBluePlus.adapterState.listen((state) {
      final mapped = _mapAdapterState(state);
      _logger.info(_tag, 'adapter state: ${mapped.label}');
      _adapterController.add(mapped);
    });
    _scanSub = fbp.FlutterBluePlus.scanResults.listen(
      (results) {
        for (final result in results) {
          _scanController.add(_toDeviceRecord(result));
        }
      },
      onError: (Object e, StackTrace s) {
        _logger.error(_tag, 'scan stream failed', e, s);
        _scanController.addError(
          BleTransportException('scan failed', detail: e.toString(), cause: e),
        );
      },
    );
    _isScanningSub =
        fbp.FlutterBluePlus.isScanning.listen(_isScanningController.add);
  }

  final AppLogger _logger;
  final Future<bool> Function()? _permissionRequester;

  final _adapterController = StreamController<BleAdapterState>.broadcast();
  final _scanController = StreamController<BleDeviceRecord>.broadcast();
  final _isScanningController = StreamController<bool>.broadcast();
  final _connectionController =
      StreamController<BleConnectionState>.broadcast();
  final _valueController = StreamController<CharacteristicValue>.broadcast();
  final _mtuController = StreamController<int>.broadcast();

  StreamSubscription<fbp.BluetoothAdapterState>? _adapterSub;
  StreamSubscription<List<fbp.ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanningSub;
  StreamSubscription<fbp.BluetoothConnectionState>? _deviceStateSub;
  StreamSubscription<int>? _mtuSub;

  final Map<String, DateTime> _firstSeen = {};
  final Map<String, StreamSubscription<List<int>>> _valueSubs = {};
  final Map<String, fbp.BluetoothCharacteristic> _characteristicCache = {};

  fbp.BluetoothDevice? _device;
  List<GattService> _services = const [];
  BleConnectionState _connectionState = BleConnectionState.disconnected;

  // ---------------------------------------------------------------- adapter

  @override
  Stream<BleAdapterState> get adapterState => _adapterController.stream;

  @override
  Future<BleAdapterState> currentAdapterState() async {
    if (!await fbp.FlutterBluePlus.isSupported) {
      return BleAdapterState.unavailable;
    }
    return _mapAdapterState(fbp.FlutterBluePlus.adapterStateNow);
  }

  @override
  Future<bool> requestPermissions() async {
    if (_permissionRequester == null) return true;
    final granted = await _permissionRequester();
    _logger.info(_tag, 'permission request result: $granted');
    return granted;
  }

  // ------------------------------------------------------------------ scan

  @override
  Stream<BleDeviceRecord> get scanResults => _scanController.stream;

  @override
  Stream<bool> get isScanning => _isScanningController.stream;

  @override
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    final adapter = await currentAdapterState();
    if (!adapter.isReady) {
      throw BleAdapterOffException('cannot scan', detail: adapter.label);
    }
    _logger.info(_tag, 'scan started (timeout ${timeout.inSeconds}s)');
    try {
      // No service filter: we do not know which services the watch advertises
      // and filtering on a guess would hide the very device we are looking for
      // (rule 1).
      await fbp.FlutterBluePlus.startScan(timeout: timeout);
    } catch (e, s) {
      _logger.error(_tag, 'startScan failed', e, s);
      throw BleTransportException('startScan failed',
          detail: e.toString(), cause: e);
    }
  }

  @override
  Future<void> stopScan() async {
    try {
      await fbp.FlutterBluePlus.stopScan();
      _logger.info(_tag, 'scan stopped');
    } catch (e, s) {
      _logger.error(_tag, 'stopScan failed', e, s);
      throw BleTransportException('stopScan failed',
          detail: e.toString(), cause: e);
    }
  }

  // ------------------------------------------------------------- connection

  @override
  Stream<BleConnectionState> get connectionState => _connectionController.stream;

  @override
  BleConnectionState get currentConnectionState => _connectionState;

  @override
  String? get connectedDeviceAddress => _device?.remoteId.str;

  @override
  Future<void> connect(
    String deviceAddress, {
    Duration timeout = const Duration(seconds: 20),
    bool autoConnect = false,
  }) async {
    final adapter = await currentAdapterState();
    if (!adapter.isReady) {
      _setState(BleConnectionState.error);
      throw BleAdapterOffException('cannot connect', detail: adapter.label);
    }

    final device = fbp.BluetoothDevice.fromId(deviceAddress);
    _device = device;
    _setState(BleConnectionState.connecting);
    _logger.info(_tag, 'connecting to $deviceAddress');

    await _deviceStateSub?.cancel();
    _deviceStateSub = device.connectionState.listen((state) {
      switch (state) {
        case fbp.BluetoothConnectionState.connected:
          _setState(BleConnectionState.connected);
        case fbp.BluetoothConnectionState.disconnected:
          _characteristicCache.clear();
          _services = const [];
          _setState(BleConnectionState.disconnected);
          final reason = device.disconnectReason;
          if (reason != null && reason.code != null && reason.code != 0) {
            _logger.warning(
              _tag,
              'disconnected: code ${reason.code} ${reason.description ?? ''}',
            );
          }
      }
    });

    await _mtuSub?.cancel();
    _mtuSub = device.mtu.listen(_mtuController.add);

    try {
      await device.connect(
        license: _fbpLicense,
        timeout: timeout,
        autoConnect: autoConnect,
        // mtu must be null when autoConnect is set; the plugin asserts on it.
        // We request the MTU ourselves afterwards either way, so that the
        // negotiated value is observed and recorded rather than assumed.
        mtu: null,
      );
    } catch (e, s) {
      _setState(BleConnectionState.error);
      _logger.error(_tag, 'connect to $deviceAddress failed', e, s);
      throw BleConnectionException('connect failed',
          detail: e.toString(), cause: e);
    }
  }

  @override
  Future<void> disconnect() async {
    final device = _device;
    if (device == null) return;
    _setState(BleConnectionState.disconnecting);
    try {
      for (final sub in _valueSubs.values) {
        await sub.cancel();
      }
      _valueSubs.clear();
      await device.disconnect();
      _logger.info(_tag, 'disconnected from ${device.remoteId.str}');
    } catch (e, s) {
      _logger.error(_tag, 'disconnect failed', e, s);
      throw BleConnectionException('disconnect failed',
          detail: e.toString(), cause: e);
    } finally {
      _setState(BleConnectionState.disconnected);
    }
  }

  // ------------------------------------------------------------------ gatt

  @override
  Future<List<GattService>> discoverServices() async {
    final device = _requireDevice();
    try {
      final discovered = await device.discoverServices();
      _characteristicCache.clear();
      _services = discovered.map(_toGattService).toList();
      for (final service in discovered) {
        for (final characteristic in service.characteristics) {
          _characteristicCache[_key(
            service.serviceUuid.str128,
            characteristic.characteristicUuid.str128,
          )] = characteristic;
        }
      }
      _logger.info(
        _tag,
        'discovered ${_services.length} services, '
        '${_characteristicCache.length} characteristics',
      );
      return _services;
    } catch (e, s) {
      _logger.error(_tag, 'discoverServices failed', e, s);
      throw BleOperationException('discoverServices failed',
          detail: e.toString(), cause: e);
    }
  }

  @override
  Stream<int> get mtu => _mtuController.stream;

  @override
  Future<int?> requestMtu(int desiredMtu) async {
    final device = _requireDevice();
    try {
      final negotiated = await device.requestMtu(desiredMtu);
      _logger.info(_tag, 'MTU negotiated: $negotiated (asked $desiredMtu)');
      return negotiated;
    } catch (e) {
      // iOS does not allow an app to request an MTU, so this failing is not
      // necessarily a problem. Logged rather than thrown.
      _logger.warning(_tag, 'requestMtu($desiredMtu) failed', e);
      return null;
    }
  }

  @override
  Future<Uint8List> readCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    final characteristic = _requireCharacteristic(serviceUuid, characteristicUuid);
    try {
      final value = await characteristic.read();
      return Uint8List.fromList(value);
    } catch (e, s) {
      _logger.error(_tag, 'read $characteristicUuid failed', e, s);
      throw BleOperationException(
        'read failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  @override
  Future<void> writeCharacteristic({
    required String serviceUuid,
    required String characteristicUuid,
    required Uint8List value,
    required bool withoutResponse,
  }) async {
    final characteristic = _requireCharacteristic(serviceUuid, characteristicUuid);
    try {
      await characteristic.write(value, withoutResponse: withoutResponse);
    } catch (e, s) {
      _logger.error(
        _tag,
        'write ${bytesToHex(value)} to $characteristicUuid failed',
        e,
        s,
      );
      throw BleOperationException(
        'write failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  @override
  Future<Uint8List> readDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
  }) async {
    final descriptor =
        _requireDescriptor(serviceUuid, characteristicUuid, descriptorUuid);
    try {
      return Uint8List.fromList(await descriptor.read());
    } catch (e, s) {
      _logger.error(_tag, 'read descriptor $descriptorUuid failed', e, s);
      throw BleOperationException(
        'descriptor read failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  @override
  Future<void> writeDescriptor({
    required String serviceUuid,
    required String characteristicUuid,
    required String descriptorUuid,
    required Uint8List value,
  }) async {
    final descriptor =
        _requireDescriptor(serviceUuid, characteristicUuid, descriptorUuid);
    try {
      await descriptor.write(value);
    } catch (e, s) {
      _logger.error(_tag, 'write descriptor $descriptorUuid failed', e, s);
      throw BleOperationException(
        'descriptor write failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  // --------------------------------------------------------- notifications

  @override
  Stream<CharacteristicValue> get characteristicValues =>
      _valueController.stream;

  @override
  Set<String> get subscribedCharacteristics => _valueSubs.keys
      .map((k) => k.split('|').last)
      .toSet();

  @override
  Future<void> subscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    final characteristic = _requireCharacteristic(serviceUuid, characteristicUuid);
    final key = _key(serviceUuid, characteristicUuid);
    if (_valueSubs.containsKey(key)) return;

    try {
      _valueSubs[key] = characteristic.onValueReceived.listen((value) {
        _valueController.add(CharacteristicValue(
          serviceUuid: serviceUuid,
          characteristicUuid: characteristicUuid,
          value: Uint8List.fromList(value),
          receivedAt: DateTime.now().toUtc(),
        ));
      });
      await characteristic.setNotifyValue(true);
      _logger.info(_tag, 'subscribed to $characteristicUuid');
    } catch (e, s) {
      await _valueSubs.remove(key)?.cancel();
      _logger.error(_tag, 'subscribe to $characteristicUuid failed', e, s);
      throw BleOperationException(
        'subscribe failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  @override
  Future<void> unsubscribe({
    required String serviceUuid,
    required String characteristicUuid,
  }) async {
    final key = _key(serviceUuid, characteristicUuid);
    final characteristic = _requireCharacteristic(serviceUuid, characteristicUuid);
    try {
      await characteristic.setNotifyValue(false);
      await _valueSubs.remove(key)?.cancel();
      _logger.info(_tag, 'unsubscribed from $characteristicUuid');
    } catch (e, s) {
      _logger.error(_tag, 'unsubscribe from $characteristicUuid failed', e, s);
      throw BleOperationException(
        'unsubscribe failed',
        detail: e.toString(),
        cause: e,
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _adapterSub?.cancel();
    await _scanSub?.cancel();
    await _isScanningSub?.cancel();
    await _deviceStateSub?.cancel();
    await _mtuSub?.cancel();
    for (final sub in _valueSubs.values) {
      await sub.cancel();
    }
    _valueSubs.clear();
    await _adapterController.close();
    await _scanController.close();
    await _isScanningController.close();
    await _connectionController.close();
    await _valueController.close();
    await _mtuController.close();
  }

  // --------------------------------------------------------------- helpers

  void _setState(BleConnectionState state) {
    if (_connectionState == state) return;
    _connectionState = state;
    _logger.info(_tag, 'connection state: ${state.label}');
    if (!_connectionController.isClosed) _connectionController.add(state);
  }

  fbp.BluetoothDevice _requireDevice() {
    final device = _device;
    if (device == null) {
      throw BleConnectionException('not connected to any device');
    }
    return device;
  }

  fbp.BluetoothCharacteristic _requireCharacteristic(
    String serviceUuid,
    String characteristicUuid,
  ) {
    final characteristic = _characteristicCache[_key(serviceUuid, characteristicUuid)];
    if (characteristic == null) {
      throw BleOperationException(
        'characteristic not found — discover services first',
        serviceUuid: serviceUuid,
        characteristicUuid: characteristicUuid,
      );
    }
    return characteristic;
  }

  fbp.BluetoothDescriptor _requireDescriptor(
    String serviceUuid,
    String characteristicUuid,
    String descriptorUuid,
  ) {
    final characteristic = _requireCharacteristic(serviceUuid, characteristicUuid);
    final wanted = BleUuid.parse(descriptorUuid);
    for (final descriptor in characteristic.descriptors) {
      if (BleUuid.parse(descriptor.descriptorUuid.str128) == wanted) {
        return descriptor;
      }
    }
    throw BleOperationException(
      'descriptor not found',
      detail: descriptorUuid,
      serviceUuid: serviceUuid,
      characteristicUuid: characteristicUuid,
    );
  }

  static String _key(String serviceUuid, String characteristicUuid) =>
      '${BleUuid.parse(serviceUuid).canonical}|'
      '${BleUuid.parse(characteristicUuid).canonical}';

  BleAdapterState _mapAdapterState(fbp.BluetoothAdapterState state) =>
      switch (state) {
        fbp.BluetoothAdapterState.on => BleAdapterState.on,
        fbp.BluetoothAdapterState.off => BleAdapterState.off,
        fbp.BluetoothAdapterState.turningOn => BleAdapterState.turningOn,
        fbp.BluetoothAdapterState.turningOff => BleAdapterState.turningOff,
        fbp.BluetoothAdapterState.unauthorized => BleAdapterState.unauthorized,
        fbp.BluetoothAdapterState.unavailable => BleAdapterState.unavailable,
        fbp.BluetoothAdapterState.unknown => BleAdapterState.unknown,
      };

  BleDeviceRecord _toDeviceRecord(fbp.ScanResult result) {
    final address = result.device.remoteId.str;
    final now = DateTime.now().toUtc();
    final firstSeen = _firstSeen.putIfAbsent(address, () => now);
    final adv = result.advertisementData;

    return BleDeviceRecord(
      address: address,
      name: adv.advName.isNotEmpty ? adv.advName : result.device.platformName,
      firstSeenAt: firstSeen,
      lastSeenAt: now,
      lastRssi: result.rssi,
      advertisedServiceUuids:
          adv.serviceUuids.map((g) => BleUuid.parse(g.str128).canonical).toList(),
      // Advertisement payloads are kept as hex exactly as received: the
      // manufacturer-specific field of a proprietary wearable often encodes
      // model and state, and reinterpreting it here would be a guess.
      manufacturerDataHex:
          adv.manufacturerData.map((id, bytes) => MapEntry(id, bytesToHex(bytes))),
      serviceDataHex: adv.serviceData.map(
        (guid, bytes) =>
            MapEntry(BleUuid.parse(guid.str128).canonical, bytesToHex(bytes)),
      ),
      connectable: adv.connectable,
      txPowerLevel: adv.txPowerLevel,
    );
  }

  GattService _toGattService(fbp.BluetoothService service) => GattService(
        uuid: BleUuid.parse(service.serviceUuid.str128).canonical,
        isPrimary: service.isPrimary,
        includedServiceUuids: service.includedServices
            .map((s) => BleUuid.parse(s.serviceUuid.str128).canonical)
            .toList(),
        characteristics: service.characteristics
            .map((c) => GattCharacteristic(
                  uuid: BleUuid.parse(c.characteristicUuid.str128).canonical,
                  serviceUuid:
                      BleUuid.parse(service.serviceUuid.str128).canonical,
                  properties: GattProperties(
                    broadcast: c.properties.broadcast,
                    read: c.properties.read,
                    writeWithoutResponse: c.properties.writeWithoutResponse,
                    write: c.properties.write,
                    notify: c.properties.notify,
                    indicate: c.properties.indicate,
                    authenticatedSignedWrites:
                        c.properties.authenticatedSignedWrites,
                    extendedProperties: c.properties.extendedProperties,
                  ),
                  descriptors: c.descriptors
                      .map((d) => GattDescriptor(
                          uuid: BleUuid.parse(d.descriptorUuid.str128).canonical))
                      .toList(),
                ))
            .toList(),
      );
}

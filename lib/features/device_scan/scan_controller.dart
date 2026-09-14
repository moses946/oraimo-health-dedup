/// Scanning state.
///
/// Holds the devices seen so far, the filter the operator is applying, and
/// whatever went wrong. Devices accumulate rather than being replaced on each
/// advertisement, so a watch that advertises intermittently does not flicker
/// in and out of the list.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bluetooth/ble_transport.dart';
import '../../core/models/ble_device_record.dart';
import '../../core/providers.dart';
import '../../core/storage/research_repository.dart';

class ScanState {
  const ScanState({
    this.devices = const [],
    this.isScanning = false,
    this.query = '',
    this.minRssi,
    this.namedOnly = false,
    this.error,
    this.permissionDenied = false,
  });

  final List<BleDeviceRecord> devices;
  final bool isScanning;

  /// Free-text filter across name, address and advertised UUIDs.
  final String query;

  /// Hide anything weaker than this, for finding the device on your wrist
  /// among the neighbours' devices.
  final int? minRssi;

  final bool namedOnly;
  final String? error;
  final bool permissionDenied;

  /// Devices after filtering, strongest signal first.
  List<BleDeviceRecord> get visibleDevices {
    final needle = query.trim().toLowerCase();
    final filtered = devices.where((d) {
      if (namedOnly && d.name.isEmpty) return false;
      if (minRssi != null && d.lastRssi < minRssi!) return false;
      if (needle.isEmpty) return true;
      return d.name.toLowerCase().contains(needle) ||
          d.address.toLowerCase().contains(needle) ||
          d.advertisedServiceUuids.any((u) => u.toLowerCase().contains(needle)) ||
          d.manufacturerDataHex.values
              .any((v) => v.toLowerCase().contains(needle)) ||
          d.manufacturerDataHex.keys.any((k) => '$k'.contains(needle));
    }).toList()
      ..sort((a, b) {
        // Favourites first: that is how the operator marks the watch.
        if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
        return b.lastRssi.compareTo(a.lastRssi);
      });
    return filtered;
  }

  ScanState copyWith({
    List<BleDeviceRecord>? devices,
    bool? isScanning,
    String? query,
    int? minRssi,
    bool clearMinRssi = false,
    bool? namedOnly,
    String? error,
    bool clearError = false,
    bool? permissionDenied,
  }) =>
      ScanState(
        devices: devices ?? this.devices,
        isScanning: isScanning ?? this.isScanning,
        query: query ?? this.query,
        minRssi: clearMinRssi ? null : (minRssi ?? this.minRssi),
        namedOnly: namedOnly ?? this.namedOnly,
        error: clearError ? null : (error ?? this.error),
        permissionDenied: permissionDenied ?? this.permissionDenied,
      );
}

class ScanController extends Notifier<ScanState> {
  late BleTransport _transport;
  ResearchRepository? _repository;

  StreamSubscription<BleDeviceRecord>? _resultSub;
  StreamSubscription<bool>? _scanningSub;

  @override
  ScanState build() {
    _transport = ref.watch(transportProvider);
    _repository = ref.watch(repositoryProvider).value;

    _resultSub = _transport.scanResults.listen(
      _onDevice,
      onError: (Object e) => state = state.copyWith(error: e.toString()),
    );
    _scanningSub = _transport.isScanning.listen(
      (scanning) => state = state.copyWith(isScanning: scanning),
    );

    ref.onDispose(() {
      _resultSub?.cancel();
      _scanningSub?.cancel();
    });

    _loadStoredDevices();
    return const ScanState();
  }

  Future<void> _loadStoredDevices() async {
    final repository = _repository;
    if (repository == null) return;
    try {
      final stored = await repository.listDevices();
      // Seed from storage so previously seen devices are visible before the
      // first advertisement of this session arrives.
      final merged = {for (final d in stored) d.address: d};
      for (final d in state.devices) {
        merged[d.address] = d;
      }
      state = state.copyWith(devices: merged.values.toList());
    } catch (e) {
      state = state.copyWith(error: 'could not load saved devices: $e');
    }
  }

  Future<void> startScan() async {
    state = state.copyWith(clearError: true, permissionDenied: false);

    final granted = await _transport.requestPermissions();
    if (!granted) {
      state = state.copyWith(
        permissionDenied: true,
        error: 'Bluetooth permissions were not granted, so scanning is not '
            'possible. Grant them in Android settings and try again.',
      );
      return;
    }

    try {
      await _transport.startScan();
    } on BleTransportException catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> stopScan() async {
    try {
      await _transport.stopScan();
    } on BleTransportException catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  void setQuery(String query) => state = state.copyWith(query: query);

  void setMinRssi(int? rssi) => state = rssi == null
      ? state.copyWith(clearMinRssi: true)
      : state.copyWith(minRssi: rssi);

  void setNamedOnly(bool value) => state = state.copyWith(namedOnly: value);

  void clearDevices() => state = state.copyWith(devices: const []);

  /// Marks a device as one of interest.
  ///
  /// This is the only way the Watch 6R becomes special to this app: the
  /// operator says so. No name or UUID is matched against a hard-coded list
  /// (rule 1).
  Future<void> toggleFavourite(BleDeviceRecord device) async {
    final updated = device.copyWith(isFavourite: !device.isFavourite);
    _replace(updated);
    await _repository?.setDeviceFavourite(updated.address, updated.isFavourite);
  }

  void _onDevice(BleDeviceRecord device) {
    final existing =
        state.devices.where((d) => d.address == device.address).firstOrNull;
    final merged = existing == null
        ? device
        : existing.copyWith(
            // Keep a name we have already seen if this advertisement omits it:
            // BLE devices routinely alternate between advertisement packets
            // that carry a name and ones that do not.
            name: device.name.isNotEmpty ? device.name : existing.name,
            lastSeenAt: device.lastSeenAt,
            lastRssi: device.lastRssi,
            advertisedServiceUuids: device.advertisedServiceUuids.isNotEmpty
                ? device.advertisedServiceUuids
                : existing.advertisedServiceUuids,
            manufacturerDataHex: device.manufacturerDataHex.isNotEmpty
                ? device.manufacturerDataHex
                : existing.manufacturerDataHex,
            serviceDataHex: device.serviceDataHex.isNotEmpty
                ? device.serviceDataHex
                : existing.serviceDataHex,
            connectable: device.connectable,
            txPowerLevel: device.txPowerLevel ?? existing.txPowerLevel,
          );

    _replace(merged);
    _repository?.upsertDevice(merged);
  }

  void _replace(BleDeviceRecord device) {
    final devices = List<BleDeviceRecord>.from(state.devices);
    final index = devices.indexWhere((d) => d.address == device.address);
    if (index == -1) {
      devices.add(device);
    } else {
      devices[index] = device;
    }
    state = state.copyWith(devices: devices);
  }

}

final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);

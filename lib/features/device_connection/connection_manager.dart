/// Connection lifecycle.
///
/// Phase 2: owns connect/disconnect, surfaces every state the UI must show,
/// and handles the link dropping. It does not hide BLE errors — the last
/// failure stays on [ConnectionStatus] until the next attempt supersedes it.
library;

import 'dart:async';

import '../../core/bluetooth/ble_transport.dart';
import '../../core/logging/app_logger.dart';
import '../../core/models/gatt_models.dart';

const String _tag = 'connection';

/// Everything the connection banner needs, in one immutable value.
class ConnectionStatus {
  const ConnectionStatus({
    this.state = BleConnectionState.disconnected,
    this.deviceAddress,
    this.deviceName,
    this.error,
    this.reconnectAttempt = 0,
    this.nextRetryIn,
    this.mtu,
    this.services = const [],
    this.servicesDiscovered = false,
  });

  final BleConnectionState state;
  final String? deviceAddress;
  final String? deviceName;

  /// The last failure, verbatim. Cleared only when a new attempt starts, so a
  /// transient error cannot flash past before the user reads it.
  final String? error;

  final int reconnectAttempt;
  final Duration? nextRetryIn;
  final int? mtu;
  final List<GattService> services;
  final bool servicesDiscovered;

  bool get isConnected => state == BleConnectionState.connected;

  bool get isBusy =>
      state == BleConnectionState.connecting ||
      state == BleConnectionState.reconnecting ||
      state == BleConnectionState.disconnecting;

  ConnectionStatus copyWith({
    BleConnectionState? state,
    String? deviceAddress,
    String? deviceName,
    String? error,
    bool clearError = false,
    int? reconnectAttempt,
    Duration? nextRetryIn,
    bool clearRetry = false,
    int? mtu,
    List<GattService>? services,
    bool? servicesDiscovered,
  }) =>
      ConnectionStatus(
        state: state ?? this.state,
        deviceAddress: deviceAddress ?? this.deviceAddress,
        deviceName: deviceName ?? this.deviceName,
        error: clearError ? null : (error ?? this.error),
        reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
        nextRetryIn: clearRetry ? null : (nextRetryIn ?? this.nextRetryIn),
        mtu: mtu ?? this.mtu,
        services: services ?? this.services,
        servicesDiscovered: servicesDiscovered ?? this.servicesDiscovered,
      );
}

class ConnectionManager {
  ConnectionManager(
    this._transport,
    this._logger, {
    this.maxReconnectAttempts = 5,
    this.baseRetryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
  }) {
    _stateSub = _transport.connectionState.listen(_onTransportState);
    _mtuSub = _transport.mtu.listen((mtu) => _update(_status.copyWith(mtu: mtu)));
    _adapterSub = _transport.adapterState.listen(_onAdapterState);
  }

  final BleTransport _transport;
  final AppLogger _logger;

  /// How many times to retry before giving up and showing an error. Bounded so
  /// a watch that is simply out of range does not retry forever.
  final int maxReconnectAttempts;
  final Duration baseRetryDelay;
  final Duration maxRetryDelay;

  final _controller = StreamController<ConnectionStatus>.broadcast();
  StreamSubscription<BleConnectionState>? _stateSub;
  StreamSubscription<int>? _mtuSub;
  StreamSubscription<BleAdapterState>? _adapterSub;
  Timer? _retryTimer;

  ConnectionStatus _status = const ConnectionStatus();

  /// True while the user wants to stay connected. Distinguishes a drop the app
  /// should recover from and a disconnect the user asked for.
  bool _userWantsConnection = false;

  Stream<ConnectionStatus> get statusStream => _controller.stream;

  ConnectionStatus get status => _status;

  Future<void> connect(String address, {String? name}) async {
    _userWantsConnection = true;
    _cancelRetry();
    _update(ConnectionStatus(
      state: BleConnectionState.connecting,
      deviceAddress: address,
      deviceName: name,
    ));

    try {
      await _transport.connect(address);
      // Ask for a large MTU so that, if the watch does fragment large
      // payloads, we see its real fragment size rather than one forced by a
      // 23-byte default.
      await _transport.requestMtu(512);
    } on BleTransportException catch (e) {
      _logger.error(_tag, 'connect to $address failed', e);
      _update(_status.copyWith(
        state: BleConnectionState.error,
        error: e.toString(),
      ));
      if (_isRetryable(e)) {
        _scheduleReconnect();
      } else {
        // A radio that is off, or a permission that was refused, is not fixed
        // by retrying — it needs the user to do something. Retrying would only
        // bury the message telling them what.
        _userWantsConnection = false;
      }
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _userWantsConnection = false;
    _cancelRetry();
    try {
      await _transport.disconnect();
    } on BleTransportException catch (e) {
      _logger.error(_tag, 'disconnect failed', e);
      _update(_status.copyWith(
        state: BleConnectionState.error,
        error: e.toString(),
      ));
      rethrow;
    }
  }

  /// Discovers services and caches them on the status.
  Future<List<GattService>> discoverServices() async {
    try {
      final services = await _transport.discoverServices();
      _update(_status.copyWith(services: services, servicesDiscovered: true));
      return services;
    } on BleTransportException catch (e) {
      _logger.error(_tag, 'service discovery failed', e);
      _update(_status.copyWith(error: e.toString()));
      rethrow;
    }
  }

  void _onTransportState(BleConnectionState state) {
    switch (state) {
      case BleConnectionState.connected:
        _update(_status.copyWith(
          state: state,
          clearError: true,
          clearRetry: true,
          reconnectAttempt: 0,
        ));
      case BleConnectionState.disconnected:
        _update(_status.copyWith(
          state: state,
          services: const [],
          servicesDiscovered: false,
        ));
        if (_userWantsConnection) _scheduleReconnect();
      default:
        _update(_status.copyWith(state: state));
    }
  }

  void _onAdapterState(BleAdapterState adapter) {
    if (adapter.isReady) return;
    // The radio going away is not a connection error to retry through; say so
    // plainly instead of retrying into a turned-off adapter.
    _cancelRetry();
    _update(_status.copyWith(
      state: BleConnectionState.error,
      error: 'Bluetooth unavailable: ${adapter.label}',
      clearRetry: true,
    ));
  }

  void _scheduleReconnect() {
    final address = _status.deviceAddress;
    if (!_userWantsConnection || address == null) return;

    if (_status.reconnectAttempt >= maxReconnectAttempts) {
      _logger.warning(
        _tag,
        'giving up after $maxReconnectAttempts reconnect attempts to $address',
      );
      _update(_status.copyWith(
        state: BleConnectionState.error,
        error: 'gave up after $maxReconnectAttempts reconnect attempts',
        clearRetry: true,
      ));
      _userWantsConnection = false;
      return;
    }

    final attempt = _status.reconnectAttempt + 1;
    final delay = _backoffFor(attempt);
    _logger.info(_tag, 'reconnect attempt $attempt in ${delay.inMilliseconds}ms');
    _update(_status.copyWith(
      state: BleConnectionState.reconnecting,
      reconnectAttempt: attempt,
      nextRetryIn: delay,
    ));

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      if (!_userWantsConnection) return;
      try {
        await _transport.connect(address);
        await _transport.requestMtu(512);
      } on BleTransportException catch (e) {
        _logger.warning(_tag, 'reconnect attempt $attempt failed', e);
        _update(_status.copyWith(error: e.toString()));
        if (_isRetryable(e)) {
          _scheduleReconnect();
        } else {
          _userWantsConnection = false;
          _update(_status.copyWith(
            state: BleConnectionState.error,
            clearRetry: true,
          ));
        }
      }
    });
  }

  /// Whether retrying could plausibly succeed without the user intervening.
  static bool _isRetryable(BleTransportException e) =>
      e is! BleAdapterOffException && e is! BlePermissionException;

  /// Exponential backoff, capped. Capped because an uncapped doubling reaches
  /// delays long enough that the user assumes the app has hung.
  Duration _backoffFor(int attempt) {
    final ms = baseRetryDelay.inMilliseconds * (1 << (attempt - 1));
    return Duration(
        milliseconds: ms.clamp(0, maxRetryDelay.inMilliseconds));
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _update(ConnectionStatus status) {
    _status = status;
    if (!_controller.isClosed) _controller.add(status);
  }

  Future<void> dispose() async {
    _cancelRetry();
    await _stateSub?.cancel();
    await _mtuSub?.cancel();
    await _adapterSub?.cancel();
    await _controller.close();
  }
}

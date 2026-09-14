import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/logging/app_logger.dart';
import 'package:oraimo_lab/features/device_connection/connection_manager.dart';

import '../support/fake_ble_transport.dart';

void main() {
  late FakeBleTransport fake;
  late AppLogger logger;
  late ConnectionManager manager;

  setUp(() {
    fake = FakeBleTransport();
    logger = AppLogger();
    manager = ConnectionManager(
      fake,
      logger,
      maxReconnectAttempts: 3,
      baseRetryDelay: const Duration(milliseconds: 10),
      maxRetryDelay: const Duration(milliseconds: 40),
    );
  });

  tearDown(() async {
    await manager.dispose();
    await fake.dispose();
    await logger.dispose();
  });

  group('happy path', () {
    test('connect reaches Connected and clears any prior error', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF', name: 'Watch 6R');
      await Future<void>.delayed(Duration.zero);

      expect(manager.status.state, BleConnectionState.connected);
      expect(manager.status.deviceAddress, 'AA:BB:CC:DD:EE:FF');
      expect(manager.status.deviceName, 'Watch 6R');
      expect(manager.status.error, isNull);
      expect(manager.status.isConnected, isTrue);
    });

    test('the UI sees every state transition, in order', () async {
      final seen = <BleConnectionState>[];
      manager.statusStream.listen((s) => seen.add(s.state));

      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      expect(seen, contains(BleConnectionState.connecting));
      expect(seen.last, BleConnectionState.connected);
    });

    test('an MTU larger than the default is requested so real fragment sizes '
        'are observable', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);
      expect(manager.status.mtu, 512);
    });

    test('a user-requested disconnect does not trigger a reconnect', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      await manager.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(manager.status.state, BleConnectionState.disconnected);
      expect(manager.status.reconnectAttempt, 0);
      expect(fake.connectAttempts, 1);
    });
  });

  group('failures are surfaced, never hidden', () {
    test('a connect failure keeps the platform error text', () async {
      fake.connectError = BleConnectionException(
        'connect failed',
        detail: 'GATT_ERROR (status 133)',
      );

      await expectLater(
        manager.connect('AA:BB:CC:DD:EE:FF'),
        throwsA(isA<BleConnectionException>()),
      );
      expect(manager.status.error, contains('GATT_ERROR (status 133)'));
    });

    test('connecting with the adapter off reports why, and does not retry',
        () async {
      fake.adapter = BleAdapterState.off;

      await expectLater(
        manager.connect('AA:BB:CC:DD:EE:FF'),
        throwsA(isA<BleAdapterOffException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(manager.status.state, BleConnectionState.error);
      expect(manager.status.error, contains('Bluetooth is off'));
    });

    test('the adapter turning off mid-session is reported plainly', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      fake.emitAdapterState(BleAdapterState.off);
      await Future<void>.delayed(Duration.zero);

      expect(manager.status.state, BleConnectionState.error);
      expect(manager.status.error, contains('Bluetooth unavailable'));
      expect(manager.status.nextRetryIn, isNull,
          reason: 'retrying into a disabled radio is pointless');
    });

    test('a failed service discovery surfaces on the status', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);
      await fake.disconnect(); // discoverServices now throws "not connected"

      await expectLater(
          manager.discoverServices(), throwsA(isA<BleConnectionException>()));
      expect(manager.status.error, contains('not connected'));
    });
  });

  group('reconnection', () {
    test('an unexpected drop triggers a reconnect attempt', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      fake.dropConnection();
      await Future<void>.delayed(Duration.zero);
      expect(manager.status.state, BleConnectionState.reconnecting);
      expect(manager.status.reconnectAttempt, 1);

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(manager.status.state, BleConnectionState.connected);
      expect(fake.connectAttempts, 2);
    });

    test('a successful reconnect resets the attempt counter', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      fake.dropConnection();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(manager.status.state, BleConnectionState.connected);
      expect(manager.status.reconnectAttempt, 0);
    });

    test('backoff grows between attempts and is capped', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      final delays = <Duration>[];
      manager.statusStream.listen((s) {
        if (s.state == BleConnectionState.reconnecting && s.nextRetryIn != null) {
          delays.add(s.nextRetryIn!);
        }
      });

      fake.connectError = BleConnectionException('still down');
      fake.dropConnection();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(delays.length, greaterThanOrEqualTo(3));
      expect(delays[0], const Duration(milliseconds: 10));
      expect(delays[1], const Duration(milliseconds: 20));
      expect(delays[2], const Duration(milliseconds: 40));
      for (final d in delays) {
        expect(d, lessThanOrEqualTo(const Duration(milliseconds: 40)),
            reason: 'backoff must stay capped');
      }
    });

    test('gives up after the attempt limit and says so', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      fake.connectError = BleConnectionException('still down');
      fake.dropConnection();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(manager.status.state, BleConnectionState.error);
      expect(manager.status.error, contains('gave up after 3'));
    });
  });

  group('service discovery', () {
    test('discovered services are cached on the status', () async {
      fake.services = const [];
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);

      expect(manager.status.servicesDiscovered, isFalse);
      await manager.discoverServices();
      expect(manager.status.servicesDiscovered, isTrue);
    });

    test('a disconnect invalidates the cached attribute database', () async {
      await manager.connect('AA:BB:CC:DD:EE:FF');
      await Future<void>.delayed(Duration.zero);
      await manager.discoverServices();
      expect(manager.status.servicesDiscovered, isTrue);

      await manager.disconnect();
      await Future<void>.delayed(Duration.zero);

      expect(manager.status.servicesDiscovered, isFalse,
          reason: 'handles are only valid for the connection that found them');
      expect(manager.status.services, isEmpty);
    });
  });
}

/// Dependency wiring.
///
/// Everything long-lived is created once here and read by the UI. The
/// composition is where the layers are joined: the plugin transport is wrapped
/// in the instrumentation decorator, so nothing downstream can obtain an
/// unobserved transport.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';

import 'bluetooth/ble_transport.dart';
import 'bluetooth/flutter_blue_plus_transport.dart';
import 'bluetooth/instrumented_ble_transport.dart';
import 'logging/app_logger.dart';
import 'logging/ble_event_bus.dart';
import 'storage/database.dart';
import 'storage/research_repository.dart';
import '../features/capture/capture_recorder.dart';
import '../features/device_connection/connection_manager.dart';

final loggerProvider = Provider<AppLogger>((ref) {
  final logger = AppLogger();
  ref.onDispose(logger.dispose);
  return logger;
});

final eventBusProvider = Provider<BleEventBus>((ref) {
  final bus = BleEventBus();
  ref.onDispose(bus.dispose);
  return bus;
});

final databaseProvider = FutureProvider<Database>((ref) async {
  final directory = await getApplicationDocumentsDirectory();
  final path = p.join(directory.path, 'oraimo_lab.db');
  final db = await openDatabase(
    path,
    version: kSchemaVersion,
    onConfigure: onConfigure,
    onCreate: createSchema,
    onUpgrade: migrateSchema,
  );
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = FutureProvider<ResearchRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return ResearchRepository(db);
});

/// The BLE transport, already instrumented.
///
/// Exposed only in this wrapped form on purpose: an uninstrumented transport
/// would move bytes without recording them, which would defeat the point of
/// the app.
final transportProvider = Provider<BleTransport>((ref) {
  final logger = ref.watch(loggerProvider);
  final bus = ref.watch(eventBusProvider);
  final transport = InstrumentedBleTransport(
    FlutterBluePlusTransport(logger, _requestBlePermissions),
    bus,
  );
  ref.onDispose(transport.dispose);
  return transport;
});

final connectionManagerProvider = Provider<ConnectionManager>((ref) {
  final manager = ConnectionManager(
    ref.watch(transportProvider),
    ref.watch(loggerProvider),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

final connectionStatusProvider = StreamProvider<ConnectionStatus>((ref) {
  final manager = ref.watch(connectionManagerProvider);
  return manager.statusStream;
});

final captureRecorderProvider = FutureProvider<CaptureRecorder>((ref) async {
  final repository = await ref.watch(repositoryProvider.future);
  final recorder = CaptureRecorder(
    ref.watch(eventBusProvider),
    repository,
    ref.watch(loggerProvider),
  );
  ref.onDispose(recorder.dispose);
  return recorder;
});

final adapterStateProvider = StreamProvider<BleAdapterState>((ref) {
  return ref.watch(transportProvider).adapterState;
});

/// Requests the runtime permissions BLE needs on this Android version.
///
/// Android 12 split Bluetooth permissions; before that, scanning required the
/// location permission, which is why both sets are requested and a denial of
/// the older one is not treated as fatal on newer devices.
Future<bool> _requestBlePermissions() async {
  final results = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.locationWhenInUse,
  ].request();

  final scan = results[Permission.bluetoothScan];
  final connect = results[Permission.bluetoothConnect];
  final location = results[Permission.locationWhenInUse];

  // On Android 12+ the split permissions are what matter. On Android 11 and
  // below they report as granted automatically and location is what matters.
  final splitGranted = (scan?.isGranted ?? false) && (connect?.isGranted ?? false);
  final legacyGranted = location?.isGranted ?? false;
  return splitGranted || legacyGranted;
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/storage/database.dart';
import 'package:oraimo_lab/core/storage/research_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../fixtures/schema_v1.dart' as v1;

/// Sessions on a phone are experimental results that may be impossible to
/// capture again. These tests build a database exactly as version 1 of the
/// app shipped it, fill it, and upgrade it.
void main() {
  late Directory tempDir;
  late String path;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('oraimo_migration_');
    path = p.join(tempDir.path, 'oraimo_lab.db');
  });

  tearDown(() async => tempDir.delete(recursive: true));

  /// Creates a v1 database holding one session with two packets, the way a
  /// phone running the previous build would have left it.
  Future<void> seedV1() async {
    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: v1.createSchemaV1),
    );
    await db.insert('capture_sessions', {
      'id': 's1',
      'name': 'connection-test',
      'source': 'live',
      'started_at': '2026-10-01T10:00:00.000Z',
      'ended_at': '2026-10-01T10:05:00.000Z',
      'device_address': 'AA:BB:CC:DD:EE:FF',
      'device_name': 'Watch 6R',
    });
    for (final (seq, payload) in [(0, 'AA0104007F'), (1, 'AA810001')]) {
      await db.insert('packets', {
        'session_id': 's1',
        'seq': seq,
        'timestamp': '2026-10-01T10:00:0$seq.123456Z',
        'elapsed_us': seq * 40000,
        'direction': seq == 0 ? 'phone_to_watch' : 'watch_to_phone',
        'operation': seq == 0 ? 'write' : 'notify',
        'characteristic_uuid': '0000fee1-0000-1000-8000-00805f9b34fb',
        'payload_hex': payload,
        'payload_length': payload.length ~/ 2,
        'status': 'ok',
      });
    }
    await db.close();
  }

  Future<Database> openCurrent() => databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: kSchemaVersion,
          onConfigure: onConfigure,
          onCreate: createSchema,
          onUpgrade: migrateSchema,
        ),
      );

  test('a v1 database upgrades with every session and packet intact',
      () async {
    await seedV1();
    final db = await openCurrent();
    final repo = ResearchRepository(db);

    expect(await db.getVersion(), kSchemaVersion);

    final sessions = await repo.listSessions();
    expect(sessions, hasLength(1));
    expect(sessions.single.name, 'connection-test');
    expect(sessions.single.packetCount, 2);

    final packets = await repo.listPackets('s1');
    expect(packets.map((p) => p.payloadHex), ['AA0104007F', 'AA810001']);
    expect(packets.first.timestamp,
        DateTime.utc(2026, 10, 1, 10, 0, 0, 123, 456));
    expect(packets.last.elapsedUs, 40000);
    expect(packets.every((p) => p.detail == null), isTrue,
        reason: 'old packets have no detail, and must not gain an invented one');

    await db.close();
  });

  test('an upgraded database accepts and returns detail on new packets',
      () async {
    await seedV1();
    final db = await openCurrent();
    final repo = ResearchRepository(db);

    final id = await repo.insertPacket(BlePacket(
      sessionId: 's1',
      seq: 2,
      timestamp: DateTime.utc(2026, 10, 1, 10, 0, 3),
      elapsedUs: 80000,
      direction: PacketDirection.phoneToWatch,
      operation: PacketOperation.discoverServices,
      payloadHex: '',
      detail: const {
        'services': [
          {'uuid': '0000180a-0000-1000-8000-00805f9b34fb', 'characteristics': []}
        ],
      },
    ));

    final stored = (await repo.listPackets('s1')).firstWhere((p) => p.id == id);
    expect((stored.detail!['services'] as List).single['uuid'],
        '0000180a-0000-1000-8000-00805f9b34fb');
    await db.close();
  });

  test('a migrated database ends up with the same packet columns as a fresh one',
      () async {
    // Guards the two paths from drifting apart: anything added to
    // createSchema must also be added by a migration step, and vice versa.
    await seedV1();
    final migrated = await openCurrent();
    final migratedColumns = await _columns(migrated, kPacketsTable);
    await migrated.close();

    final fresh = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: onConfigure,
        onCreate: createSchema,
      ),
    );
    final freshColumns = await _columns(fresh, kPacketsTable);
    await fresh.close();

    expect(migratedColumns, freshColumns);
  });

  test('a migrated database still cascades session deletes to packets',
      () async {
    await seedV1();
    final db = await openCurrent();
    final repo = ResearchRepository(db);
    await repo.deleteSession('s1');
    expect(await repo.countPackets('s1'), 0);
    await db.close();
  });

  test('an unknown future version is refused rather than half-migrated',
      () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    expect(
      () => migrateSchema(db, kSchemaVersion, kSchemaVersion + 1),
      throwsA(isA<StateError>()),
    );
    await db.close();
  });
}

Future<Set<String>> _columns(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

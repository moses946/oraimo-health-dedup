/// SQLite schema and connection management.
///
/// Packets are stored with payloads as hex text (rule 6) and are never updated
/// after insert (rule 4) — the only writes to the packets table are inserts and
/// whole-session deletes.
library;

import 'package:sqflite/sqflite.dart';

/// Bumped whenever the schema changes; [_migrate] handles the upgrade.
const int kSchemaVersion = 1;

const String kPacketsTable = 'packets';
const String kSessionsTable = 'capture_sessions';
const String kDevicesTable = 'devices';
const String kObservationsTable = 'protocol_observations';
const String kHypothesesTable = 'protocol_hypotheses';

Future<void> createSchema(Database db, int version) async {
  final batch = db.batch();

  batch.execute('''
    CREATE TABLE $kDevicesTable (
      address TEXT PRIMARY KEY,
      name TEXT NOT NULL DEFAULT '',
      first_seen_at TEXT NOT NULL,
      last_seen_at TEXT NOT NULL,
      last_rssi INTEGER NOT NULL DEFAULT 0,
      advertised_service_uuids TEXT NOT NULL DEFAULT '[]',
      manufacturer_data TEXT NOT NULL DEFAULT '{}',
      service_data TEXT NOT NULL DEFAULT '{}',
      connectable INTEGER NOT NULL DEFAULT 1,
      tx_power_level INTEGER,
      is_favourite INTEGER NOT NULL DEFAULT 0
    )
  ''');

  batch.execute('''
    CREATE TABLE $kSessionsTable (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      source TEXT NOT NULL,
      started_at TEXT NOT NULL,
      ended_at TEXT,
      device_address TEXT,
      device_name TEXT,
      notes TEXT,
      source_file_name TEXT
    )
  ''');

  batch.execute('''
    CREATE TABLE $kPacketsTable (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      timestamp TEXT NOT NULL,
      elapsed_us INTEGER NOT NULL,
      direction TEXT NOT NULL,
      operation TEXT NOT NULL,
      service_uuid TEXT,
      characteristic_uuid TEXT,
      descriptor_uuid TEXT,
      att_handle INTEGER,
      payload_hex TEXT NOT NULL,
      payload_length INTEGER NOT NULL,
      status TEXT NOT NULL,
      error TEXT,
      note TEXT,
      FOREIGN KEY (session_id) REFERENCES $kSessionsTable (id) ON DELETE CASCADE
    )
  ''');

  // Session playback is always ordered by seq; the characteristic index backs
  // the packet monitor's per-characteristic filter.
  batch.execute(
      'CREATE INDEX idx_packets_session_seq ON $kPacketsTable (session_id, seq)');
  batch.execute(
      'CREATE INDEX idx_packets_characteristic ON $kPacketsTable (characteristic_uuid)');

  batch.execute('''
    CREATE TABLE $kObservationsTable (
      id TEXT PRIMARY KEY,
      capture_session_id TEXT,
      characteristic_uuid TEXT,
      observation TEXT NOT NULL,
      evidence TEXT NOT NULL DEFAULT '',
      evidence_packet_ids TEXT NOT NULL DEFAULT '[]',
      confidence TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (capture_session_id) REFERENCES $kSessionsTable (id) ON DELETE SET NULL
    )
  ''');

  batch.execute('''
    CREATE TABLE $kHypothesesTable (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL DEFAULT '',
      evidence TEXT NOT NULL DEFAULT '',
      observation_ids TEXT NOT NULL DEFAULT '[]',
      confidence TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');

  await batch.commit(noResult: true);
}

/// No upgrades exist yet. When the first one does, add it here rather than
/// recreating the database: stored captures are experimental results and must
/// survive an app update.
Future<void> migrateSchema(Database db, int oldVersion, int newVersion) async {
  throw StateError(
    'no migration defined from schema v$oldVersion to v$newVersion',
  );
}

Future<void> onConfigure(Database db) async {
  await db.execute('PRAGMA foreign_keys = ON');
}

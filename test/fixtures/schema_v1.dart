/// The schema as it shipped in version 1, frozen.
///
/// Copied verbatim from `lib/core/storage/database.dart` at commit b3143b6 and
/// never to be edited. Migration tests build a v1 database from this, fill it
/// with data, and upgrade it, which is the only honest way to prove that
/// sessions captured by an older build survive an app update. Testing against
/// the current `createSchema` would only prove that the current code agrees
/// with itself.
library;

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const String kPacketsTable = 'packets';
const String kSessionsTable = 'capture_sessions';
const String kDevicesTable = 'devices';
const String kObservationsTable = 'protocol_observations';
const String kHypothesesTable = 'protocol_hypotheses';

Future<void> createSchemaV1(Database db, int version) async {
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

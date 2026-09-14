/// Persistence for every kind of research record.
///
/// Deliberately a single repository: sessions, packets, devices, observations
/// and hypotheses are one connected body of evidence, and splitting them across
/// repositories would only add indirection.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/ble_device_record.dart';
import '../models/ble_packet.dart';
import '../models/capture_session.dart';
import '../models/protocol_records.dart';
import 'database.dart';

class ResearchRepository {
  ResearchRepository(this._db);

  final Database _db;

  // ---------------------------------------------------------------- devices

  Future<void> upsertDevice(BleDeviceRecord device) async {
    await _db.insert(
      kDevicesTable,
      {
        'address': device.address,
        'name': device.name,
        'first_seen_at': device.firstSeenAt.toUtc().toIso8601String(),
        'last_seen_at': device.lastSeenAt.toUtc().toIso8601String(),
        'last_rssi': device.lastRssi,
        'advertised_service_uuids': jsonEncode(device.advertisedServiceUuids),
        'manufacturer_data': jsonEncode(
            device.manufacturerDataHex.map((k, v) => MapEntry('$k', v))),
        'service_data': jsonEncode(device.serviceDataHex),
        'connectable': device.connectable ? 1 : 0,
        'tx_power_level': device.txPowerLevel,
        'is_favourite': device.isFavourite ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<BleDeviceRecord>> listDevices() async {
    final rows = await _db.query(kDevicesTable, orderBy: 'last_seen_at DESC');
    return rows.map(_deviceFromRow).toList();
  }

  Future<BleDeviceRecord?> findDevice(String address) async {
    final rows = await _db
        .query(kDevicesTable, where: 'address = ?', whereArgs: [address], limit: 1);
    return rows.isEmpty ? null : _deviceFromRow(rows.first);
  }

  Future<void> setDeviceFavourite(String address, bool favourite) async {
    await _db.update(
      kDevicesTable,
      {'is_favourite': favourite ? 1 : 0},
      where: 'address = ?',
      whereArgs: [address],
    );
  }

  // --------------------------------------------------------------- sessions

  Future<void> insertSession(CaptureSession session) async {
    await _db.insert(kSessionsTable, _sessionToRow(session));
  }

  Future<void> updateSession(CaptureSession session) async {
    await _db.update(
      kSessionsTable,
      _sessionToRow(session),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  Future<void> deleteSession(String sessionId) async {
    // Packets cascade via the foreign key.
    await _db.delete(kSessionsTable, where: 'id = ?', whereArgs: [sessionId]);
  }

  /// Sessions newest first, each with its packet count filled in.
  Future<List<CaptureSession>> listSessions() async {
    final rows = await _db.rawQuery('''
      SELECT s.*, (SELECT COUNT(*) FROM $kPacketsTable p WHERE p.session_id = s.id)
             AS packet_count
      FROM $kSessionsTable s
      ORDER BY s.started_at DESC
    ''');
    return rows.map(_sessionFromRow).toList();
  }

  Future<CaptureSession?> findSession(String id) async {
    final rows = await _db.rawQuery('''
      SELECT s.*, (SELECT COUNT(*) FROM $kPacketsTable p WHERE p.session_id = s.id)
             AS packet_count
      FROM $kSessionsTable s
      WHERE s.id = ?
      LIMIT 1
    ''', [id]);
    return rows.isEmpty ? null : _sessionFromRow(rows.first);
  }

  // ---------------------------------------------------------------- packets

  /// Appends one packet and returns its row id.
  Future<int> insertPacket(BlePacket packet) async {
    assert(packet.sessionId != null, 'a stored packet must belong to a session');
    return _db.insert(kPacketsTable, _packetToRow(packet));
  }

  /// Appends many packets in a single transaction.
  ///
  /// Used by the btsnoop importer, where a capture routinely runs to tens of
  /// thousands of packets and per-row inserts would be unusably slow.
  Future<void> insertPackets(Iterable<BlePacket> packets) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final packet in packets) {
        batch.insert(kPacketsTable, _packetToRow(packet));
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<BlePacket>> listPackets(
    String sessionId, {
    int? limit,
    int? offset,
  }) async {
    final rows = await _db.query(
      kPacketsTable,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'seq ASC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_packetFromRow).toList();
  }

  Future<int> countPackets(String sessionId) async {
    final result = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $kPacketsTable WHERE session_id = ?',
      [sessionId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  /// Next sequence number for a session. Sessions can be resumed, so this
  /// reads the current maximum rather than trusting an in-memory counter.
  Future<int> nextSeq(String sessionId) async {
    final result = await _db.rawQuery(
      'SELECT MAX(seq) AS m FROM $kPacketsTable WHERE session_id = ?',
      [sessionId],
    );
    final max = result.first['m'];
    return max == null ? 0 : (max as int) + 1;
  }

  /// Distinct characteristic UUIDs seen in a session, for filter menus.
  Future<List<String>> distinctCharacteristics(String sessionId) async {
    final rows = await _db.rawQuery('''
      SELECT DISTINCT characteristic_uuid FROM $kPacketsTable
      WHERE session_id = ? AND characteristic_uuid IS NOT NULL
      ORDER BY characteristic_uuid
    ''', [sessionId]);
    return rows.map((r) => r['characteristic_uuid'] as String).toList();
  }

  // ----------------------------------------------------------- observations

  Future<void> upsertObservation(ProtocolObservation observation) async {
    await _db.insert(
      kObservationsTable,
      {
        'id': observation.id,
        'capture_session_id': observation.captureSessionId,
        'characteristic_uuid': observation.characteristicUuid,
        'observation': observation.observation,
        'evidence': observation.evidence,
        'evidence_packet_ids': jsonEncode(observation.evidencePacketIds),
        'confidence': observation.confidence.wireName,
        'created_at': observation.createdAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ProtocolObservation>> listObservations({String? sessionId}) async {
    final rows = await _db.query(
      kObservationsTable,
      where: sessionId == null ? null : 'capture_session_id = ?',
      whereArgs: sessionId == null ? null : [sessionId],
      orderBy: 'created_at DESC',
    );
    return rows.map(_observationFromRow).toList();
  }

  Future<void> deleteObservation(String id) async {
    await _db.delete(kObservationsTable, where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ hypotheses

  Future<void> upsertHypothesis(ProtocolHypothesis hypothesis) async {
    await _db.insert(
      kHypothesesTable,
      {
        'id': hypothesis.id,
        'name': hypothesis.name,
        'description': hypothesis.description,
        'evidence': hypothesis.evidence,
        'observation_ids': jsonEncode(hypothesis.observationIds),
        'confidence': hypothesis.confidence.wireName,
        'status': hypothesis.status.wireName,
        'created_at': hypothesis.createdAt.toUtc().toIso8601String(),
        'updated_at': hypothesis.updatedAt.toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ProtocolHypothesis>> listHypotheses() async {
    final rows =
        await _db.query(kHypothesesTable, orderBy: 'updated_at DESC');
    return rows.map(_hypothesisFromRow).toList();
  }

  Future<void> deleteHypothesis(String id) async {
    await _db.delete(kHypothesesTable, where: 'id = ?', whereArgs: [id]);
  }

  // ------------------------------------------------------------ row mapping

  Map<String, Object?> _sessionToRow(CaptureSession s) => {
        'id': s.id,
        'name': s.name,
        'source': s.source.wireName,
        'started_at': s.startedAt.toUtc().toIso8601String(),
        'ended_at': s.endedAt?.toUtc().toIso8601String(),
        'device_address': s.deviceAddress,
        'device_name': s.deviceName,
        'notes': s.notes,
        'source_file_name': s.sourceFileName,
      };

  CaptureSession _sessionFromRow(Map<String, Object?> row) => CaptureSession(
        id: row['id'] as String,
        name: row['name'] as String,
        source: CaptureSource.fromWire(row['source'] as String),
        startedAt: DateTime.parse(row['started_at'] as String),
        endedAt: row['ended_at'] == null
            ? null
            : DateTime.parse(row['ended_at'] as String),
        deviceAddress: row['device_address'] as String?,
        deviceName: row['device_name'] as String?,
        notes: row['notes'] as String?,
        sourceFileName: row['source_file_name'] as String?,
        packetCount: (row['packet_count'] as int?) ?? 0,
      );

  Map<String, Object?> _packetToRow(BlePacket p) => {
        'session_id': p.sessionId,
        'seq': p.seq,
        'timestamp': p.timestamp.toUtc().toIso8601String(),
        'elapsed_us': p.elapsedUs,
        'direction': p.direction.wireName,
        'operation': p.operation.wireName,
        'service_uuid': p.serviceUuid,
        'characteristic_uuid': p.characteristicUuid,
        'descriptor_uuid': p.descriptorUuid,
        'att_handle': p.attHandle,
        'payload_hex': p.payloadHex,
        'payload_length': p.payloadLength,
        'status': p.status.wireName,
        'error': p.error,
        'note': p.note,
      };

  BlePacket _packetFromRow(Map<String, Object?> row) => BlePacket(
        id: row['id'] as int?,
        sessionId: row['session_id'] as String?,
        seq: row['seq'] as int,
        timestamp: DateTime.parse(row['timestamp'] as String),
        elapsedUs: row['elapsed_us'] as int,
        direction: PacketDirection.fromWire(row['direction'] as String),
        operation: PacketOperation.fromWire(row['operation'] as String),
        payloadHex: row['payload_hex'] as String,
        serviceUuid: row['service_uuid'] as String?,
        characteristicUuid: row['characteristic_uuid'] as String?,
        descriptorUuid: row['descriptor_uuid'] as String?,
        attHandle: row['att_handle'] as int?,
        status: PacketStatus.fromWire(row['status'] as String),
        error: row['error'] as String?,
        note: row['note'] as String?,
      );

  BleDeviceRecord _deviceFromRow(Map<String, Object?> row) => BleDeviceRecord(
        address: row['address'] as String,
        name: row['name'] as String? ?? '',
        firstSeenAt: DateTime.parse(row['first_seen_at'] as String),
        lastSeenAt: DateTime.parse(row['last_seen_at'] as String),
        lastRssi: row['last_rssi'] as int? ?? 0,
        advertisedServiceUuids:
            (jsonDecode(row['advertised_service_uuids'] as String) as List)
                .cast<String>(),
        manufacturerDataHex:
            (jsonDecode(row['manufacturer_data'] as String) as Map)
                .map((k, v) => MapEntry(int.parse(k as String), v as String)),
        serviceDataHex: (jsonDecode(row['service_data'] as String) as Map)
            .cast<String, String>(),
        connectable: (row['connectable'] as int? ?? 1) == 1,
        txPowerLevel: row['tx_power_level'] as int?,
        isFavourite: (row['is_favourite'] as int? ?? 0) == 1,
      );

  ProtocolObservation _observationFromRow(Map<String, Object?> row) =>
      ProtocolObservation(
        id: row['id'] as String,
        captureSessionId: row['capture_session_id'] as String?,
        characteristicUuid: row['characteristic_uuid'] as String?,
        observation: row['observation'] as String,
        evidence: row['evidence'] as String? ?? '',
        evidencePacketIds:
            (jsonDecode(row['evidence_packet_ids'] as String) as List)
                .cast<int>(),
        confidence: Confidence.fromWire(row['confidence'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  ProtocolHypothesis _hypothesisFromRow(Map<String, Object?> row) =>
      ProtocolHypothesis(
        id: row['id'] as String,
        name: row['name'] as String,
        description: row['description'] as String? ?? '',
        evidence: row['evidence'] as String? ?? '',
        observationIds:
            (jsonDecode(row['observation_ids'] as String) as List).cast<String>(),
        confidence: Confidence.fromWire(row['confidence'] as String),
        status: HypothesisStatus.fromWire(row['status'] as String),
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );
}

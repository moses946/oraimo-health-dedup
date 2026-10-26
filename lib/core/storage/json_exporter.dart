/// JSON export.
///
/// This is the project's deliverable artefact. Protocol analysis — by us, by a
/// script, or by someone else entirely — reads these files, so the schema is
/// append-only: add keys, never rename or repurpose them, and bump
/// [kExportSchemaVersion] when the shape changes.
library;

import 'dart:convert';

import '../models/ble_packet.dart';
import '../models/capture_session.dart';
import '../models/protocol_records.dart';

/// Version of the export envelope, not of the app.
///
/// History:
///   1 — initial envelope.
///   2 — each event may carry a `detail` object (null for most). Additive:
///       a reader written for v1 that ignores unknown keys still works.
const int kExportSchemaVersion = 2;

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// Exports one capture session and its packets.
Map<String, dynamic> buildSessionExport({
  required CaptureSession session,
  required List<BlePacket> packets,
  DateTime? exportedAt,
}) {
  return {
    'schemaVersion': kExportSchemaVersion,
    'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'generator': 'oraimo_lab',
    'session': session.toJson(),
    // Flattened onto the envelope as well, because the spec's example format
    // puts them here and existing tooling may look for them at the top level.
    'device': {'name': session.deviceName, 'address': session.deviceAddress},
    'startedAt': session.startedAt.toUtc().toIso8601String(),
    'events': packets.map((p) => p.toJson()).toList(),
  };
}

String encodeSessionExport({
  required CaptureSession session,
  required List<BlePacket> packets,
  DateTime? exportedAt,
}) =>
    _pretty.convert(buildSessionExport(
      session: session,
      packets: packets,
      exportedAt: exportedAt,
    ));

/// Exports everything: every session with its packets, plus the whole research
/// ledger. This is the "Export all research data" of the developer section.
Map<String, dynamic> buildFullExport({
  required List<CaptureSession> sessions,
  required Map<String, List<BlePacket>> packetsBySession,
  required List<ProtocolObservation> observations,
  required List<ProtocolHypothesis> hypotheses,
  DateTime? exportedAt,
}) {
  return {
    'schemaVersion': kExportSchemaVersion,
    'exportedAt': (exportedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'generator': 'oraimo_lab',
    'sessions': [
      for (final session in sessions)
        {
          'session': session.toJson(),
          'events': (packetsBySession[session.id] ?? const <BlePacket>[])
              .map((p) => p.toJson())
              .toList(),
        }
    ],
    'observations': observations.map((o) => o.toJson()).toList(),
    'hypotheses': hypotheses.map((h) => h.toJson()).toList(),
  };
}

String encodeFullExport({
  required List<CaptureSession> sessions,
  required Map<String, List<BlePacket>> packetsBySession,
  required List<ProtocolObservation> observations,
  required List<ProtocolHypothesis> hypotheses,
  DateTime? exportedAt,
}) =>
    _pretty.convert(buildFullExport(
      sessions: sessions,
      packetsBySession: packetsBySession,
      observations: observations,
      hypotheses: hypotheses,
      exportedAt: exportedAt,
    ));

/// A filesystem-safe file name for a session export.
String sessionExportFileName(CaptureSession session) {
  final safeName = session.name
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');
  final stamp = session.startedAt
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[:.]'), '-')
      .split('T')
      .join('_')
      .substring(0, 19);
  return '${safeName.isEmpty ? 'session' : safeName}_$stamp.json';
}

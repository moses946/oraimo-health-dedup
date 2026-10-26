import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/capture_session.dart';
import 'package:oraimo_lab/core/models/protocol_records.dart';
import 'package:oraimo_lab/core/storage/json_exporter.dart';

/// The export schema is the artefact everything downstream reads. These tests
/// are deliberately strict about its shape: a silent rename would invalidate
/// captures recorded by an older build.
void main() {
  final session = CaptureSession(
    id: 'ses-1',
    name: 'watchface-A',
    source: CaptureSource.btsnoopImport,
    startedAt: DateTime.utc(2026, 3, 1, 21, 43, 12),
    endedAt: DateTime.utc(2026, 3, 1, 21, 45, 0),
    deviceAddress: 'AA:BB:CC:DD:EE:FF',
    deviceName: 'Watch 6R',
    notes: 'installed face A from Oraimo Health',
    sourceFileName: 'btsnoop_hci.log',
  );

  final packets = [
    BlePacket(
      sessionId: 'ses-1',
      seq: 0,
      timestamp: DateTime.utc(2026, 3, 1, 21, 43, 12, 241),
      elapsedUs: 0,
      direction: PacketDirection.phoneToWatch,
      operation: PacketOperation.write,
      payloadHex: 'AA0104007F',
      serviceUuid: '0000fee7-0000-1000-8000-00805f9b34fb',
      characteristicUuid: '0000fee1-0000-1000-8000-00805f9b34fb',
      attHandle: 0x002b,
    ),
    BlePacket(
      sessionId: 'ses-1',
      seq: 1,
      timestamp: DateTime.utc(2026, 3, 1, 21, 43, 12, 281),
      elapsedUs: 40000,
      direction: PacketDirection.watchToPhone,
      operation: PacketOperation.notify,
      payloadHex: 'AA810001',
      characteristicUuid: null,
      attHandle: 0x002e,
    ),
  ];

  group('session export', () {
    test('matches the agreed schema exactly', () {
      final json = buildSessionExport(
        session: session,
        packets: packets,
        exportedAt: DateTime.utc(2026, 3, 2, 10, 0, 0),
      );

      expect(json['schemaVersion'], 2);
      expect(json['exportedAt'], '2026-03-02T10:00:00.000Z');
      expect(json['generator'], 'oraimo_lab');
      expect(json['startedAt'], '2026-03-01T21:43:12.000Z');
      expect(json['device'], {'name': 'Watch 6R', 'address': 'AA:BB:CC:DD:EE:FF'});

      final s = json['session'] as Map<String, dynamic>;
      expect(s['name'], 'watchface-A');
      expect(s['source'], 'btsnoop_import');
      expect(s['notes'], 'installed face A from Oraimo Health');
      expect(s['sourceFileName'], 'btsnoop_hci.log');

      final events = json['events'] as List;
      expect(events, hasLength(2));
      expect(events.first, {
        'seq': 0,
        'timestamp': '2026-03-01T21:43:12.241Z',
        'elapsedUs': 0,
        'direction': 'phone_to_watch',
        'operation': 'write',
        'service': '0000fee7-0000-1000-8000-00805f9b34fb',
        'characteristic': '0000fee1-0000-1000-8000-00805f9b34fb',
        'descriptor': null,
        'handle': '0x002b',
        'payload': 'AA0104007F',
        'payloadLength': 5,
        'status': 'ok',
        'error': null,
        'note': null,
        'detail': null,
      });
    });

    test('a discovery packet exports the attribute database it found', () {
      final discovery = BlePacket(
        sessionId: 'ses-1',
        seq: 2,
        timestamp: DateTime.utc(2026, 3, 1, 21, 43, 13),
        elapsedUs: 1000000,
        direction: PacketDirection.phoneToWatch,
        operation: PacketOperation.discoverServices,
        payloadHex: '',
        note: '1 services, 0 characteristics',
        detail: const {
          'services': [
            {'uuid': '0000180a-0000-1000-8000-00805f9b34fb'}
          ],
        },
      );
      final json = buildSessionExport(session: session, packets: [discovery]);
      final event = (json['events'] as List).single as Map<String, dynamic>;
      expect(event['detail'], {
        'services': [
          {'uuid': '0000180a-0000-1000-8000-00805f9b34fb'}
        ],
      });
      // And it survives the trip through JSON text and back.
      final restored = BlePacket.fromJson(
          (jsonDecode(encodeSessionExport(session: session, packets: [discovery]))
                  as Map<String, dynamic>)['events'][0] as Map<String, dynamic>);
      expect((restored.detail!['services'] as List).single['uuid'],
          '0000180a-0000-1000-8000-00805f9b34fb');
    });

    test('an unidentified attribute exports a null uuid, never a guess', () {
      final json = buildSessionExport(session: session, packets: packets);
      final notify = (json['events'] as List)[1] as Map<String, dynamic>;
      expect(notify['characteristic'], isNull);
      expect(notify['service'], isNull);
      expect(notify['handle'], '0x002e');
    });

    test('packets survive a full JSON round trip', () {
      final encoded = encodeSessionExport(session: session, packets: packets);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = (decoded['events'] as List)
          .map((e) => BlePacket.fromJson(e as Map<String, dynamic>))
          .toList();

      for (var i = 0; i < packets.length; i++) {
        expect(restored[i].seq, packets[i].seq);
        expect(restored[i].payloadHex, packets[i].payloadHex);
        expect(restored[i].timestamp, packets[i].timestamp);
        expect(restored[i].elapsedUs, packets[i].elapsedUs);
        expect(restored[i].direction, packets[i].direction);
        expect(restored[i].operation, packets[i].operation);
        expect(restored[i].attHandle, packets[i].attHandle);
        expect(restored[i].characteristicUuid, packets[i].characteristicUuid);
      }
    });

    test('session metadata survives a full JSON round trip', () {
      final encoded = encodeSessionExport(session: session, packets: packets);
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored =
          CaptureSession.fromJson(decoded['session'] as Map<String, dynamic>);
      expect(restored.id, session.id);
      expect(restored.name, session.name);
      expect(restored.source, session.source);
      expect(restored.startedAt, session.startedAt);
      expect(restored.endedAt, session.endedAt);
      expect(restored.deviceAddress, session.deviceAddress);
      expect(restored.notes, session.notes);
    });

    test('output is pretty-printed so a diff of two captures is readable', () {
      final encoded = encodeSessionExport(session: session, packets: packets);
      expect(encoded, contains('\n  "schemaVersion": 2'));
    });
  });

  group('full export', () {
    test('carries every session, observation and hypothesis', () {
      final json = buildFullExport(
        sessions: [session],
        packetsBySession: {'ses-1': packets},
        observations: [
          ProtocolObservation(
            id: 'o1',
            captureSessionId: 'ses-1',
            observation: 'writes begin with AA',
            evidencePacketIds: const [1, 2],
            confidence: Confidence.medium,
            createdAt: DateTime.utc(2026, 3, 2),
          ),
        ],
        hypotheses: [
          ProtocolHypothesis(
            id: 'h1',
            name: 'byte 0 is a frame marker',
            description: 'refuted by any frame starting otherwise',
            status: HypothesisStatus.testing,
            createdAt: DateTime.utc(2026, 3, 2),
            updatedAt: DateTime.utc(2026, 3, 2),
          ),
        ],
        exportedAt: DateTime.utc(2026, 3, 2),
      );

      expect(json['schemaVersion'], 2);
      expect((json['sessions'] as List).single['events'], hasLength(2));
      expect((json['observations'] as List).single['evidencePacketIds'], [1, 2]);
      expect((json['hypotheses'] as List).single['status'], 'TESTING');
    });

    test('a session with no packets exports an empty event list', () {
      final json = buildFullExport(
        sessions: [session],
        packetsBySession: const {},
        observations: const [],
        hypotheses: const [],
      );
      expect((json['sessions'] as List).single['events'], isEmpty);
    });
  });

  group('export file names', () {
    test('are filesystem safe and carry the session name and time', () {
      expect(sessionExportFileName(session),
          'watchface-A_2026-03-01_21-43-12.json');
    });

    test('awkward names are sanitised, not rejected', () {
      final awkward = CaptureSession(
        id: 'x',
        name: 'watch face / B (take 2)',
        source: CaptureSource.live,
        startedAt: DateTime.utc(2026, 3, 1, 9, 5, 0),
      );
      expect(sessionExportFileName(awkward),
          'watch-face-B-take-2_2026-03-01_09-05-00.json');
    });
  });
}

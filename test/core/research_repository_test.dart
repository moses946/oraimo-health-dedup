import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/models/ble_device_record.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/capture_session.dart';
import 'package:oraimo_lab/core/models/protocol_records.dart';
import 'package:oraimo_lab/core/storage/database.dart';
import 'package:oraimo_lab/core/storage/research_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ResearchRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: kSchemaVersion,
        onConfigure: onConfigure,
        onCreate: createSchema,
      ),
    );
    repo = ResearchRepository(db);
  });

  tearDown(() async => db.close());

  CaptureSession session({String id = 's1', String name = 'connection-test'}) =>
      CaptureSession(
        id: id,
        name: name,
        source: CaptureSource.live,
        startedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        deviceAddress: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'Watch 6R',
      );

  BlePacket packet({
    String sessionId = 's1',
    int seq = 0,
    String payload = 'AA0104007F',
    PacketDirection direction = PacketDirection.phoneToWatch,
    PacketOperation operation = PacketOperation.write,
    String? characteristic = '0000fee1-0000-1000-8000-00805f9b34fb',
    int? handle,
    PacketStatus status = PacketStatus.ok,
    String? error,
  }) =>
      BlePacket(
        sessionId: sessionId,
        seq: seq,
        timestamp: DateTime.utc(2026, 1, 2, 3, 4, 5, 0, seq),
        elapsedUs: seq * 1000,
        direction: direction,
        operation: operation,
        payloadHex: payload,
        characteristicUuid: characteristic,
        attHandle: handle,
        status: status,
        error: error,
      );

  group('sessions', () {
    test('insert then read back preserves every field', () async {
      await repo.insertSession(session());
      final loaded = await repo.findSession('s1');
      expect(loaded, isNotNull);
      expect(loaded!.name, 'connection-test');
      expect(loaded.source, CaptureSource.live);
      expect(loaded.startedAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(loaded.deviceAddress, 'AA:BB:CC:DD:EE:FF');
      expect(loaded.isRecording, isTrue);
    });

    test('listing reports the packet count', () async {
      await repo.insertSession(session());
      await repo.insertPackets([packet(seq: 0), packet(seq: 1)]);
      final sessions = await repo.listSessions();
      expect(sessions.single.packetCount, 2);
    });

    test('ending a session records endedAt', () async {
      await repo.insertSession(session());
      final ended = DateTime.utc(2026, 1, 2, 3, 9, 0);
      await repo.updateSession(session().copyWith(endedAt: ended));
      final loaded = await repo.findSession('s1');
      expect(loaded!.isRecording, isFalse);
      expect(loaded.endedAt, ended);
      expect(loaded.duration, const Duration(minutes: 4, seconds: 55));
    });

    test('deleting a session cascades to its packets', () async {
      await repo.insertSession(session());
      await repo.insertPackets([packet(seq: 0), packet(seq: 1)]);
      await repo.deleteSession('s1');
      expect(await repo.countPackets('s1'), 0);
      expect(await repo.findSession('s1'), isNull);
    });
  });

  group('packets', () {
    setUp(() async => repo.insertSession(session()));

    test('payload survives storage byte for byte', () async {
      await repo.insertPacket(packet(payload: 'AA0104007F'));
      final stored = (await repo.listPackets('s1')).single;
      expect(stored.payloadHex, 'AA0104007F');
      expect(stored.payloadBytes, [0xAA, 0x01, 0x04, 0x00, 0x7F]);
      expect(stored.payloadLength, 5);
      expect(stored.payloadDisplay, 'AA 01 04 00 7F');
    });

    test('timestamps survive at microsecond precision', () async {
      final ts = DateTime.utc(2026, 1, 2, 3, 4, 5, 123, 456);
      await repo.insertPacket(BlePacket(
        sessionId: 's1',
        seq: 0,
        timestamp: ts,
        elapsedUs: 987654,
        direction: PacketDirection.watchToPhone,
        operation: PacketOperation.notify,
        payloadHex: 'AA81',
      ));
      final stored = (await repo.listPackets('s1')).single;
      expect(stored.timestamp.toUtc(), ts);
      expect(stored.elapsedUs, 987654);
    });

    test('packets come back in sequence order, not insertion order', () async {
      await repo.insertPackets([packet(seq: 2), packet(seq: 0), packet(seq: 1)]);
      final seqs = (await repo.listPackets('s1')).map((p) => p.seq).toList();
      expect(seqs, [0, 1, 2]);
    });

    test('a failed operation is stored as evidence, error text intact',
        () async {
      await repo.insertPacket(packet(
        operation: PacketOperation.error,
        status: PacketStatus.failed,
        error: 'GATT_WRITE_NOT_PERMITTED (status 3)',
        payload: '',
      ));
      final stored = (await repo.listPackets('s1')).single;
      expect(stored.status, PacketStatus.failed);
      expect(stored.error, 'GATT_WRITE_NOT_PERMITTED (status 3)');
      expect(stored.payloadLength, 0);
    });

    test('an unresolved handle stays null rather than being guessed', () async {
      await repo.insertPacket(
          packet(characteristic: null, handle: 0x002b));
      final stored = (await repo.listPackets('s1')).single;
      expect(stored.characteristicUuid, isNull);
      expect(stored.attHandle, 0x002b);
      expect(stored.attributeLabel, 'handle 0x002b');
    });

    test('nextSeq continues from the stored maximum', () async {
      expect(await repo.nextSeq('s1'), 0);
      await repo.insertPackets([packet(seq: 0), packet(seq: 1), packet(seq: 2)]);
      expect(await repo.nextSeq('s1'), 3);
    });

    test('distinctCharacteristics backs the filter menu', () async {
      await repo.insertPackets([
        packet(seq: 0, characteristic: 'uuid-b'),
        packet(seq: 1, characteristic: 'uuid-a'),
        packet(seq: 2, characteristic: 'uuid-a'),
        packet(seq: 3, characteristic: null, handle: 9),
      ]);
      expect(await repo.distinctCharacteristics('s1'), ['uuid-a', 'uuid-b']);
    });

    test('paging returns a stable window', () async {
      await repo.insertPackets(
          List.generate(10, (i) => packet(seq: i, payload: 'AA0$i')));
      final page = await repo.listPackets('s1', limit: 3, offset: 4);
      expect(page.map((p) => p.seq), [4, 5, 6]);
    });
  });

  group('devices', () {
    test('upsert replaces on re-scan and keeps advertisement data verbatim',
        () async {
      final first = BleDeviceRecord(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'Watch 6R',
        firstSeenAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 1),
        lastRssi: -70,
        advertisedServiceUuids: const ['0000fee7-0000-1000-8000-00805f9b34fb'],
        manufacturerDataHex: const {0x01AF: 'DEADBEEF'},
        serviceDataHex: const {'0000fee7-0000-1000-8000-00805f9b34fb': '0102'},
        txPowerLevel: -4,
      );
      await repo.upsertDevice(first);
      await repo.upsertDevice(first.copyWith(
        lastSeenAt: DateTime.utc(2026, 1, 2),
        lastRssi: -55,
      ));

      final devices = await repo.listDevices();
      expect(devices, hasLength(1));
      final d = devices.single;
      expect(d.lastRssi, -55);
      expect(d.firstSeenAt, DateTime.utc(2026, 1, 1));
      expect(d.manufacturerDataHex, {0x01AF: 'DEADBEEF'});
      expect(d.serviceDataHex,
          {'0000fee7-0000-1000-8000-00805f9b34fb': '0102'});
      expect(d.txPowerLevel, -4);
    });

    test('favourite flag is how a device of interest is marked', () async {
      await repo.upsertDevice(BleDeviceRecord(
        address: 'AA:BB:CC:DD:EE:FF',
        name: 'Watch 6R',
        firstSeenAt: DateTime.utc(2026, 1, 1),
        lastSeenAt: DateTime.utc(2026, 1, 1),
        lastRssi: -70,
      ));
      await repo.setDeviceFavourite('AA:BB:CC:DD:EE:FF', true);
      expect((await repo.findDevice('AA:BB:CC:DD:EE:FF'))!.isFavourite, isTrue);
    });
  });

  group('protocol ledger', () {
    test('an observation keeps its link to the packets that back it', () async {
      await repo.insertSession(session());
      final id = await repo.insertPacket(packet());
      await repo.upsertObservation(ProtocolObservation(
        id: 'o1',
        captureSessionId: 's1',
        characteristicUuid: '0000fee1-0000-1000-8000-00805f9b34fb',
        observation: 'every write to this characteristic begins with AA',
        evidence: 'packets 0-4 of connection-test',
        evidencePacketIds: [id],
        confidence: Confidence.medium,
        createdAt: DateTime.utc(2026, 1, 2),
      ));
      final loaded = (await repo.listObservations()).single;
      expect(loaded.evidencePacketIds, [id]);
      expect(loaded.confidence, Confidence.medium);
      expect(loaded.captureSessionId, 's1');
    });

    test('a hypothesis round-trips through every status', () async {
      for (final status in HypothesisStatus.values) {
        await repo.upsertHypothesis(ProtocolHypothesis(
          id: 'h-${status.wireName}',
          name: 'byte 0 is a frame marker',
          description: 'refuted if any observed frame starts with another byte',
          status: status,
          createdAt: DateTime.utc(2026, 1, 2),
          updatedAt: DateTime.utc(2026, 1, 2),
        ));
      }
      final loaded = await repo.listHypotheses();
      expect(loaded.map((h) => h.status).toSet(),
          HypothesisStatus.values.toSet());
    });

    test('a disproven hypothesis is kept, not deleted', () async {
      final h = ProtocolHypothesis(
        id: 'h1',
        name: 'payload is compressed',
        description: 'refuted if entropy is low',
        createdAt: DateTime.utc(2026, 1, 2),
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      await repo.upsertHypothesis(h);
      await repo.upsertHypothesis(h.copyWith(
        status: HypothesisStatus.disproven,
        evidence: 'long runs of 0x00 observed',
      ));
      final loaded = (await repo.listHypotheses()).single;
      expect(loaded.status, HypothesisStatus.disproven);
      expect(loaded.evidence, 'long runs of 0x00 observed');
    });
  });
}

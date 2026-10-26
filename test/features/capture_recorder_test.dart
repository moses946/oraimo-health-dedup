import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:oraimo_lab/core/bluetooth/ble_transport.dart';
import 'package:oraimo_lab/core/bluetooth/instrumented_ble_transport.dart';
import 'package:oraimo_lab/core/logging/app_logger.dart';
import 'package:oraimo_lab/core/logging/ble_event_bus.dart';
import 'package:oraimo_lab/core/models/ble_packet.dart';
import 'package:oraimo_lab/core/models/capture_session.dart';
import 'package:oraimo_lab/core/storage/database.dart';
import 'package:oraimo_lab/core/storage/json_exporter.dart';
import 'package:oraimo_lab/core/storage/research_repository.dart';
import 'package:oraimo_lab/features/capture/capture_recorder.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_ble_transport.dart';

const String svc = '0000fee7-0000-1000-8000-00805f9b34fb';
const String chr = '0000fee1-0000-1000-8000-00805f9b34fb';

void main() {
  late Database db;
  late ResearchRepository repo;
  late BleEventBus bus;
  late AppLogger logger;
  late FakeBleTransport fake;
  late InstrumentedBleTransport transport;
  late CaptureRecorder recorder;

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
    bus = BleEventBus();
    logger = AppLogger();
    fake = FakeBleTransport();
    transport = InstrumentedBleTransport(fake, bus);
    recorder = CaptureRecorder(bus, repo, logger);
    await transport.connect('AA:BB:CC:DD:EE:FF');
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await recorder.dispose();
    await transport.dispose();
    await bus.dispose();
    await logger.dispose();
    await db.close();
  });

  Future<void> writeSome(int count) async {
    for (var i = 0; i < count; i++) {
      await transport.writeCharacteristic(
        serviceUuid: svc,
        characteristicUuid: chr,
        value: Uint8List.fromList([0xAA, i]),
        withoutResponse: true,
      );
    }
  }

  group('recording', () {
    test('captures traffic that happens while it is running', () async {
      await recorder.start(id: 's1', name: 'connection-test');
      await writeSome(3);
      final session = await recorder.stop();

      expect(session!.packetCount, 3);
      final packets = await repo.listPackets('s1');
      expect(packets.map((p) => p.payloadHex), ['AA00', 'AA01', 'AA02']);
    });

    test('ignores traffic from before it started and after it stopped',
        () async {
      await writeSome(2); // before
      await recorder.start(id: 's1', name: 'x');
      await writeSome(1); // during
      await recorder.stop();
      await writeSome(2); // after

      final packets = await repo.listPackets('s1');
      expect(packets, hasLength(1));
      expect(packets.single.payloadHex, 'AA00');
    });

    test('elapsed offsets are measured from the start of the session',
        () async {
      await writeSome(2); // advance the bus clock before recording begins
      await recorder.start(id: 's1', name: 'x');
      await writeSome(3);
      await recorder.stop();

      final packets = await repo.listPackets('s1');
      // Zero is the moment recording started, not the first packet: a gap
      // before the first packet is itself information.
      expect(packets.first.elapsedUs, greaterThanOrEqualTo(0));
      expect(packets.first.elapsedUs, lessThan(Duration.microsecondsPerSecond),
          reason: 'offsets must be session-relative, not bus-relative');
      for (var i = 1; i < packets.length; i++) {
        expect(packets[i].elapsedUs,
            greaterThanOrEqualTo(packets[i - 1].elapsedUs));
      }
    });

    test('sequence numbers are session-relative and dense', () async {
      await writeSome(5); // advance the bus's own counter first
      await recorder.start(id: 's1', name: 'x');
      await writeSome(4);
      await recorder.stop();

      final packets = await repo.listPackets('s1');
      expect(packets.map((p) => p.seq), [0, 1, 2, 3]);
    });

    test('a live session is marked live, never as an import', () async {
      await recorder.start(id: 's1', name: 'x');
      final session = await recorder.stop();
      expect(session!.source, CaptureSource.live);
    });

    test('a failed write is recorded into the session as evidence', () async {
      await recorder.start(id: 's1', name: 'x');
      fake.operationError = BleOperationException(
        'write failed',
        detail: 'GATT_WRITE_NOT_PERMITTED (status 3)',
      );
      await expectLater(
        transport.writeCharacteristic(
          serviceUuid: svc,
          characteristicUuid: chr,
          value: Uint8List.fromList([0xAA]),
          withoutResponse: true,
        ),
        throwsA(isA<BleOperationException>()),
      );
      await recorder.stop();

      final packets = await repo.listPackets('s1');
      final failure =
          packets.firstWhere((p) => p.status == PacketStatus.failed);
      expect(failure.error, contains('GATT_WRITE_NOT_PERMITTED'));
    });

    test('starting twice is refused rather than silently losing a session',
        () async {
      await recorder.start(id: 's1', name: 'first');
      expect(
        () => recorder.start(id: 's2', name: 'second'),
        throwsA(isA<StateError>()),
      );
      await recorder.stop();
    });

    test('stopping when not recording is harmless', () async {
      expect(await recorder.stop(), isNull);
    });

    test('a burst larger than one flush interval is fully persisted', () async {
      await recorder.start(id: 's1', name: 'burst');
      await writeSome(300);
      final session = await recorder.stop();
      expect(session!.packetCount, 300);
      expect(await repo.countPackets('s1'), 300);
    });

    test('notes are timestamped and appended', () async {
      await recorder.start(id: 's1', name: 'x');
      await recorder.addNote('tapped Sync in Oraimo Health');
      await recorder.addNote('progress bar finished');
      await recorder.stop();

      final stored = await repo.findSession('s1');
      expect(stored!.notes, contains('tapped Sync in Oraimo Health'));
      expect(stored.notes, contains('progress bar finished'));
      expect(stored.notes!.split('\n'), hasLength(2));
    });
  });

  group('export of a recorded session', () {
    test('produces the schema downstream analysis reads', () async {
      await recorder.start(
        id: 's1',
        name: 'connection-test',
        deviceAddress: 'AA:BB:CC:DD:EE:FF',
        deviceName: 'Watch 6R',
      );
      await writeSome(2);
      final session = await recorder.stop();

      final json = buildSessionExport(
        session: session!,
        packets: await repo.listPackets('s1'),
      );

      expect(json['schemaVersion'], 2);
      expect((json['session'] as Map)['source'], 'live');
      expect((json['device'] as Map)['address'], 'AA:BB:CC:DD:EE:FF');
      final events = json['events'] as List;
      expect(events, hasLength(2));
      expect((events.first as Map)['payload'], 'AA00');
      expect((events.first as Map)['direction'], 'phone_to_watch');
    });
  });
}

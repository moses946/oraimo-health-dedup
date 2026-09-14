/// Writing sessions out to disk and handing them to the share sheet.
///
/// Exports go to a temporary directory and are shared from there, because the
/// point is to get the JSON off the phone and into an analysis environment.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/ble_packet.dart';
import '../../core/models/capture_session.dart';
import '../../core/storage/json_exporter.dart';
import '../../core/storage/research_repository.dart';

class SessionExportService {
  SessionExportService(this._repository);

  final ResearchRepository _repository;

  /// Writes one session to a JSON file and returns it.
  Future<File> writeSession(CaptureSession session) async {
    final packets = await _repository.listPackets(session.id);
    final json = encodeSessionExport(session: session, packets: packets);
    return _write(sessionExportFileName(session), json);
  }

  /// Writes every session, observation and hypothesis to one file.
  Future<File> writeEverything() async {
    final sessions = await _repository.listSessions();
    final packetsBySession = <String, List<BlePacket>>{
      for (final session in sessions)
        session.id: await _repository.listPackets(session.id),
    };

    final json = encodeFullExport(
      sessions: sessions,
      packetsBySession: packetsBySession,
      observations: await _repository.listObservations(),
      hypotheses: await _repository.listHypotheses(),
    );

    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .substring(0, 19);
    return _write('oraimo-lab-research_$stamp.json', json);
  }

  Future<void> share(File file, {String? subject}) async {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/json')],
        subject: subject,
      ),
    );
  }

  Future<File> _write(String fileName, String contents) async {
    final directory = await getTemporaryDirectory();
    final file = File(p.join(directory.path, fileName));
    await file.writeAsString(contents, encoding: utf8, flush: true);
    return file;
  }
}

/// One capture session, packet by packet.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/ble_packet.dart';
import '../../core/models/ble_uuid.dart';
import '../../core/models/capture_session.dart';
import '../../core/providers.dart';
import '../../features/capture/session_export_service.dart';
import '../widgets/packet_tile.dart';

final sessionPacketsProvider =
    FutureProvider.family<List<BlePacket>, String>((ref, sessionId) async {
  final repository = await ref.watch(repositoryProvider.future);
  return repository.listPackets(sessionId);
});

class SessionDetailScreen extends ConsumerStatefulWidget {
  const SessionDetailScreen({super.key, required this.session});

  final CaptureSession session;

  @override
  ConsumerState<SessionDetailScreen> createState() =>
      _SessionDetailScreenState();
}

class _SessionDetailScreenState extends ConsumerState<SessionDetailScreen> {
  PacketDirection? _direction;
  String? _characteristic;

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final packets = ref.watch(sessionPacketsProvider(session.id));

    return Scaffold(
      appBar: AppBar(
        title: Text(session.name),
        actions: [
          IconButton(
            tooltip: 'Export JSON',
            icon: const Icon(Icons.ios_share),
            onPressed: () async {
              final repository = await ref.read(repositoryProvider.future);
              final service = SessionExportService(repository);
              try {
                final file = await service.writeSession(session);
                await service.share(file, subject: 'Capture: ${session.name}');
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Export failed: $e')));
                }
              }
            },
          ),
        ],
      ),
      body: packets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: SelectableText('$e')),
        data: (all) {
          final characteristics = all
              .map((p) => p.characteristicUuid)
              .whereType<String>()
              .toSet()
              .toList()
            ..sort();

          final visible = all.where((p) {
            if (_direction != null && p.direction != _direction) return false;
            if (_characteristic != null &&
                p.characteristicUuid != _characteristic) {
              return false;
            }
            return true;
          }).toList();

          return Column(
            children: [
              _SessionHeader(session: session, packets: all),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('All'),
                      selected: _direction == null,
                      onSelected: (_) => setState(() => _direction = null),
                    ),
                    const SizedBox(width: 6),
                    for (final d in PacketDirection.values) ...[
                      ChoiceChip(
                        label: Text(d.label),
                        selected: _direction == d,
                        onSelected: (_) => setState(() => _direction = d),
                      ),
                      const SizedBox(width: 6),
                    ],
                    if (characteristics.isNotEmpty)
                      DropdownButton<String?>(
                        value: _characteristic,
                        hint: const Text('Characteristic',
                            style: TextStyle(fontSize: 13)),
                        underline: const SizedBox.shrink(),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('All characteristics',
                                style: TextStyle(fontSize: 13)),
                          ),
                          for (final uuid in characteristics)
                            DropdownMenuItem<String?>(
                              value: uuid,
                              child: Text(
                                BleUuid.tryParse(uuid)?.short ?? uuid,
                                style: const TextStyle(
                                    fontFamily: 'monospace', fontSize: 12),
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _characteristic = v),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('No packets match the filter.'))
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (context, i) =>
                            PacketTile(packet: visible[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.session, required this.packets});

  final CaptureSession session;
  final List<BlePacket> packets;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unresolved =
        packets.where((p) => p.attHandle != null && p.characteristicUuid == null);
    final truncated = packets.where((p) => p.note?.contains('incomplete') ?? false);

    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(session.source.label,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: scheme.primary)),
          const SizedBox(height: 4),
          Text(
            '${packets.length} packets · '
            '${session.deviceName ?? session.deviceAddress ?? 'unknown device'}',
            style: const TextStyle(fontSize: 12),
          ),
          Text(
            'started ${session.startedAt.toLocal()}'
            '${session.duration == null ? '' : ' · lasted ${session.duration!.inSeconds}s'}',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          if (session.sourceFileName != null)
            Text('from ${session.sourceFileName}',
                style: TextStyle(fontSize: 11, color: scheme.outline)),
          if (session.notes != null && session.notes!.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(session.notes!,
                style: const TextStyle(fontSize: 11)),
          ],
          // Caveats stay visible on the session, not buried in a dialog at
          // import time: anyone reading this capture later needs to know that
          // some of it is unidentified or incomplete.
          if (unresolved.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '${unresolved.length} packets reference handles this capture '
              'never identified. Their characteristic is genuinely unknown.',
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
          ],
          if (truncated.isNotEmpty)
            Text(
              '${truncated.length} packets were truncated by the capture and '
              'are incomplete.',
              style: TextStyle(fontSize: 11, color: scheme.error),
            ),
        ],
      ),
    );
  }
}

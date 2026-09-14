/// Phase 5: capture sessions.
///
/// A session is a named experiment. Recording one, annotating it with what you
/// physically did, and exporting it as JSON is the entire point of the app:
/// those files are the evidence later protocol work rests on.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/capture_session.dart';
import '../../core/providers.dart';
import '../../core/storage/research_repository.dart';
import '../../features/capture/capture_recorder.dart';
import '../../features/capture/session_export_service.dart';
import 'btsnoop_import_screen.dart';
import 'session_detail_screen.dart';

final sessionListProvider = FutureProvider<List<CaptureSession>>((ref) async {
  final repository = await ref.watch(repositoryProvider.future);
  return repository.listSessions();
});

/// Names that describe experiments worth running, offered as a starting point.
/// They are experiment labels, not protocol claims.
const List<String> kSuggestedSessionNames = [
  'connection-test',
  'watchface-A',
  'watchface-B',
  'change-time',
  'sync-data',
  'change-settings',
];

class CaptureSessionsScreen extends ConsumerWidget {
  const CaptureSessionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(sessionListProvider);
    final recorder = ref.watch(captureRecorderProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Capture Sessions'),
        actions: [
          IconButton(
            tooltip: 'Import HCI snoop log',
            icon: const Icon(Icons.file_open),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const BtsnoopImportScreen(),
                ),
              );
              ref.invalidate(sessionListProvider);
            },
          ),
        ],
      ),
      floatingActionButton: recorder == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: recorder.isRecording
                  ? Theme.of(context).colorScheme.error
                  : null,
              foregroundColor: recorder.isRecording
                  ? Theme.of(context).colorScheme.onError
                  : null,
              icon: Icon(recorder.isRecording
                  ? Icons.stop
                  : Icons.fiber_manual_record),
              label: Text(recorder.isRecording ? 'Stop' : 'Record'),
              onPressed: () async {
                if (recorder.isRecording) {
                  await recorder.stop();
                } else {
                  await _startRecording(context, ref, recorder);
                }
                ref.invalidate(sessionListProvider);
              },
            ),
      body: sessions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SelectableText('Could not load sessions:\n$e'),
          ),
        ),
        data: (list) {
          if (list.isEmpty) {
            return const _EmptyState();
          }
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(sessionListProvider),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: list.length,
              itemBuilder: (context, i) => _SessionCard(session: list[i]),
            ),
          );
        },
      ),
    );
  }

  Future<void> _startRecording(
    BuildContext context,
    WidgetRef ref,
    CaptureRecorder recorder,
  ) async {
    final status = ref.read(connectionManagerProvider).status;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _NewSessionDialog(),
    );
    if (name == null || name.isEmpty) return;

    try {
      await recorder.start(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        deviceAddress: status.deviceAddress,
        deviceName: status.deviceName,
      );
    } on StateError catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.science_outlined,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No sessions yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Record this app\'s own BLE traffic, or import an Android HCI '
              'snoop log to see what the official app does.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog();

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name this experiment'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'connection-test',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final name in kSuggestedSessionNames)
                ActionChip(
                  label: Text(name, style: const TextStyle(fontSize: 11)),
                  onPressed: () => setState(() => _controller.text = name),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('Start recording'),
        ),
      ],
    );
  }
}

class _SessionCard extends ConsumerWidget {
  const _SessionCard({required this.session});

  final CaptureSession session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final imported = session.source == CaptureSource.btsnoopImport;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ListTile(
        leading: Icon(
          imported ? Icons.download_for_offline : Icons.radio_button_checked,
          color: imported ? scheme.tertiary : scheme.primary,
        ),
        title: Text(session.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '${session.packetCount} packets · ${session.source.label}',
              style: const TextStyle(fontSize: 11),
            ),
            Text(
              session.startedAt.toLocal().toString().substring(0, 19),
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            if (session.isRecording)
              Text('recording…',
                  style: TextStyle(fontSize: 11, color: scheme.error)),
          ],
        ),
        trailing: PopupMenuButton<String>(
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'export', child: Text('Export JSON')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
          onSelected: (action) async {
            final repository = await ref.read(repositoryProvider.future);
            if (!context.mounted) return;
            switch (action) {
              case 'export':
                await _export(context, repository);
              case 'delete':
                await _confirmDelete(context, ref, repository);
            }
          },
        ),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SessionDetailScreen(session: session),
          ),
        ),
      ),
    );
  }

  Future<void> _export(
      BuildContext context, ResearchRepository repository) async {
    final service = SessionExportService(repository);
    try {
      final file = await service.writeSession(session);
      await service.share(file, subject: 'Capture: ${session.name}');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    ResearchRepository repository,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${session.name}"?'),
        content: Text(
          '${session.packetCount} captured packets will be deleted '
          'permanently. Export first if this experiment still matters.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.deleteSession(session.id);
    ref.invalidate(sessionListProvider);
  }
}

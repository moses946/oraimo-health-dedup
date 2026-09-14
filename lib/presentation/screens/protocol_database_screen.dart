/// The research ledger.
///
/// Two lists, kept deliberately separate: what we saw, and what we think it
/// means. The separation is the point — it is what stops a plausible guess
/// from being treated as a known fact three weeks later (rule 3).
///
/// There is no decoder anywhere in this app. When a hypothesis here reaches
/// SUPPORTED on real evidence, that is when writing one becomes justified.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/protocol_records.dart';
import '../../core/providers.dart';

final observationsProvider =
    FutureProvider<List<ProtocolObservation>>((ref) async {
  final repository = await ref.watch(repositoryProvider.future);
  return repository.listObservations();
});

final hypothesesProvider =
    FutureProvider<List<ProtocolHypothesis>>((ref) async {
  final repository = await ref.watch(repositoryProvider.future);
  return repository.listHypotheses();
});

class ProtocolDatabaseScreen extends ConsumerStatefulWidget {
  const ProtocolDatabaseScreen({super.key});

  @override
  ConsumerState<ProtocolDatabaseScreen> createState() =>
      _ProtocolDatabaseScreenState();
}

class _ProtocolDatabaseScreenState extends ConsumerState<ProtocolDatabaseScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Protocol Database'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Observations'),
            Tab(text: 'Hypotheses'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _tabs.index == 0 ? _addObservation() : _addHypothesis(),
        child: const Icon(Icons.add),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_ObservationList(), _HypothesisList()],
      ),
    );
  }

  Future<void> _addObservation() async {
    final result = await showDialog<({String text, String evidence})>(
      context: context,
      builder: (_) => const _ObservationDialog(),
    );
    if (result == null) return;

    final repository = await ref.read(repositoryProvider.future);
    await repository.upsertObservation(ProtocolObservation(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      observation: result.text,
      evidence: result.evidence,
      createdAt: DateTime.now().toUtc(),
    ));
    ref.invalidate(observationsProvider);
  }

  Future<void> _addHypothesis() async {
    final result = await showDialog<({String name, String description})>(
      context: context,
      builder: (_) => const _HypothesisDialog(),
    );
    if (result == null) return;

    final now = DateTime.now().toUtc();
    final repository = await ref.read(repositoryProvider.future);
    await repository.upsertHypothesis(ProtocolHypothesis(
      id: now.microsecondsSinceEpoch.toString(),
      name: result.name,
      description: result.description,
      createdAt: now,
      updatedAt: now,
    ));
    ref.invalidate(hypothesesProvider);
  }
}

class _ObservationList extends ConsumerWidget {
  const _ObservationList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final observations = ref.watch(observationsProvider);
    return observations.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: SelectableText('$e')),
      data: (list) {
        if (list.isEmpty) {
          return const _Empty(
            icon: Icons.visibility_outlined,
            title: 'No observations yet',
            body: 'An observation is something you saw in a capture, phrased '
                'descriptively: "every write to this characteristic begins '
                'with AA". Not what it means — just what is there.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final o = list[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ListTile(
                title: Text(o.observation),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (o.evidence.isNotEmpty)
                      Text(o.evidence, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 4),
                    Text(
                      'confidence ${o.confidence.label.toLowerCase()}'
                      '${o.evidencePacketIds.isEmpty ? '' : ' · ${o.evidencePacketIds.length} packets cited'}'
                      '${o.characteristicUuid == null ? '' : ' · ${o.characteristicUuid}'}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                  ],
                ),
                isThreeLine: true,
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final repository =
                        await ref.read(repositoryProvider.future);
                    await repository.deleteObservation(o.id);
                    ref.invalidate(observationsProvider);
                  },
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _HypothesisList extends ConsumerWidget {
  const _HypothesisList();

  static Color _statusColour(HypothesisStatus status, ColorScheme scheme) =>
      switch (status) {
        HypothesisStatus.unknown => scheme.outline,
        HypothesisStatus.testing => scheme.tertiary,
        HypothesisStatus.supported => scheme.primary,
        HypothesisStatus.disproven => scheme.error,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hypotheses = ref.watch(hypothesesProvider);
    final scheme = Theme.of(context).colorScheme;

    return hypotheses.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: SelectableText('$e')),
      data: (list) {
        if (list.isEmpty) {
          return const _Empty(
            icon: Icons.psychology_outlined,
            title: 'No hypotheses yet',
            body: 'A hypothesis says what you think something means AND what '
                'would prove you wrong. Without the second half it is just an '
                'assertion.',
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: list.length,
          itemBuilder: (context, i) {
            final h = list[i];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: ExpansionTile(
                title: Text(h.name,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  h.status.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: _statusColour(h.status, scheme),
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(h.description,
                        style: const TextStyle(fontSize: 13)),
                  ),
                  if (h.evidence.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText('Evidence: ${h.evidence}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final status in HypothesisStatus.values)
                        ChoiceChip(
                          label: Text(status.label,
                              style: const TextStyle(fontSize: 10)),
                          selected: h.status == status,
                          onSelected: (_) async {
                            final repository =
                                await ref.read(repositoryProvider.future);
                            await repository.upsertHypothesis(
                                h.copyWith(status: status));
                            ref.invalidate(hypothesesProvider);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _ObservationDialog extends StatefulWidget {
  const _ObservationDialog();

  @override
  State<_ObservationDialog> createState() => _ObservationDialogState();
}

class _ObservationDialogState extends State<_ObservationDialog> {
  final _text = TextEditingController();
  final _evidence = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    _evidence.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New observation'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What did you see?',
              hintText: 'every write to 0xFEE1 begins with AA',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _evidence,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Evidence',
              hintText: 'packets 12-48 of watchface-A',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            (text: _text.text.trim(), evidence: _evidence.text.trim()),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _HypothesisDialog extends StatefulWidget {
  const _HypothesisDialog();

  @override
  State<_HypothesisDialog> createState() => _HypothesisDialogState();
}

class _HypothesisDialogState extends State<_HypothesisDialog> {
  final _name = TextEditingController();
  final _description = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New hypothesis'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Claim',
              hintText: 'byte 0 is a start-of-frame marker',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'What would disprove it?',
              hintText: 'observing any frame that starts with another byte',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            (name: _name.text.trim(), description: _description.text.trim()),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

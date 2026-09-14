/// Raw BLE log.
///
/// Rule 9 made visible: everything the BLE layer logged, errors included,
/// with stack traces intact and copyable.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/logging/app_logger.dart';
import '../../core/providers.dart';

class BleLogScreen extends ConsumerStatefulWidget {
  const BleLogScreen({super.key});

  @override
  ConsumerState<BleLogScreen> createState() => _BleLogScreenState();
}

class _BleLogScreenState extends ConsumerState<BleLogScreen> {
  StreamSubscription<LogEntry>? _subscription;
  List<LogEntry> _entries = [];
  LogLevel? _minLevel;

  @override
  void initState() {
    super.initState();
    final logger = ref.read(loggerProvider);
    _entries = logger.entries.reversed.toList();
    _subscription = logger.stream.listen((entry) {
      if (mounted) setState(() => _entries.insert(0, entry));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  List<LogEntry> get _visible => _minLevel == null
      ? _entries
      : _entries.where((e) => e.level.index >= _minLevel!.index).toList();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Log'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all),
            onPressed: visible.isEmpty
                ? null
                : () async {
                    await Clipboard.setData(ClipboardData(
                      text: visible.reversed.map((e) => e.fullText).join('\n'),
                    ));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Log copied')),
                      );
                    }
                  },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              ref.read(loggerProvider).clear();
              setState(_entries.clear);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: _minLevel == null,
                  onSelected: (_) => setState(() => _minLevel = null),
                ),
                const SizedBox(width: 6),
                for (final level in LogLevel.values) ...[
                  ChoiceChip(
                    label: Text(level.label),
                    selected: _minLevel == level,
                    onSelected: (_) => setState(() => _minLevel = level),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? const Center(child: Text('Nothing logged yet.'))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) {
                      final entry = visible[i];
                      final colour = switch (entry.level) {
                        LogLevel.error => scheme.error,
                        LogLevel.warning => scheme.tertiary,
                        LogLevel.info => scheme.onSurface,
                        LogLevel.debug => scheme.outline,
                      };
                      return ListTile(
                        dense: true,
                        title: SelectableText(
                          '${entry.timestamp.toLocal().toIso8601String().substring(11, 23)} '
                          '[${entry.level.label}] ${entry.tag}: ${entry.message}',
                          style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: colour),
                        ),
                        subtitle: entry.error == null
                            ? null
                            : SelectableText(
                                entry.error.toString(),
                                style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: scheme.error),
                              ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

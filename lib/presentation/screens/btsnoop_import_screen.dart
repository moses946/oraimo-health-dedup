/// Importing an Android HCI snoop log.
///
/// This is how the official Oraimo Health app's traffic gets in. The flow is
/// deliberately two-stage — preview, then import — because a phone's snoop log
/// contains every Bluetooth device it was talking to, and importing all of it
/// would bury the watch in traffic from headphones, a car and a keyboard.
library;

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../features/import/btsnoop/btsnoop_importer.dart';
import '../../features/import/btsnoop/btsnoop_reader.dart';

class BtsnoopImportScreen extends ConsumerStatefulWidget {
  const BtsnoopImportScreen({super.key});

  @override
  ConsumerState<BtsnoopImportScreen> createState() =>
      _BtsnoopImportScreenState();
}

class _BtsnoopImportScreenState extends ConsumerState<BtsnoopImportScreen> {
  final BtsnoopImporter _importer = BtsnoopImporter();
  final TextEditingController _nameController =
      TextEditingController(text: 'imported-capture');

  Uint8List? _bytes;
  String? _fileName;
  BtsnoopPreview? _preview;
  String? _selectedPeer;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.pickFile();
      if (picked == null) return;

      // Read through the picker's own handle rather than a filesystem path:
      // on Android the file usually arrives as a content:// URI, for which
      // there is no path to open.
      final bytes = await picked.readAsBytes();
      final preview = _importer.preview(bytes);

      setState(() {
        _bytes = bytes;
        _fileName = picked.name;
        _preview = preview;
        _selectedPeer =
            preview.peers.isEmpty ? null : preview.peers.first.address;
      });
    } on BtsnoopFormatException catch (e) {
      // The format error is shown in full: its text says exactly which mistake
      // was made, and "import failed" would not.
      setState(() {
        _error = e.toString();
        _preview = null;
        _bytes = null;
      });
    } catch (e) {
      setState(() => _error = 'Could not read the file: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    final bytes = _bytes;
    if (bytes == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repository = await ref.read(repositoryProvider.future);
      final result = _importer.import(
        bytes: bytes,
        sessionId: DateTime.now().microsecondsSinceEpoch.toString(),
        sessionName: _nameController.text.trim().isEmpty
            ? 'imported-capture'
            : _nameController.text.trim(),
        peerAddress: _selectedPeer,
        sourceFileName: _fileName,
      );

      await repository.insertSession(result.session);
      await repository.insertPackets(result.packets);

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported ${result.packets.length} packets'
            '${result.hasUnresolvedHandles ? ' — ${result.unresolvedHandles.length} handles unidentified' : ''}',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = _preview;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import HCI snoop log'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: scheme.surfaceContainerHighest,
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Why this exists',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  SizedBox(height: 8),
                  Text(
                    'Android does not let one app see another app\'s Bluetooth '
                    'traffic, so this app cannot watch Oraimo Health directly. '
                    'The phone\'s own Bluetooth stack can: enable "Bluetooth '
                    'HCI snoop log" in Developer options, toggle Bluetooth off '
                    'and on, perform one operation in Oraimo Health, then take '
                    'a bug report and extract\n'
                    'FS/data/misc/bluetooth/logs/btsnoop_hci.log',
                    style: TextStyle(fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.folder_open),
            label: Text(_fileName ?? 'Choose btsnoop_hci.log'),
            onPressed: _busy ? null : _pickFile,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _error!,
                style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
              ),
            ),
          ],
          if (preview != null) ...[
            const SizedBox(height: 24),
            Text('What this capture contains',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _Stat('HCI records', '${preview.summary.totalRecords}'),
            _Stat('ACL records', '${preview.summary.aclRecords}'),
            _Stat('ATT packets', '${preview.summary.attPackets}'),
            _Stat('Devices', '${preview.peers.length}'),
            if (preview.summary.truncatedRecords > 0)
              _Stat('Truncated records', '${preview.summary.truncatedRecords}',
                  warning: true),
            if (preview.summary.droppedRecords > 0)
              _Stat('Dropped by the stack', '${preview.summary.droppedRecords}',
                  warning: true),
            if (preview.summary.firstTimestamp != null)
              _Stat('Starts',
                  preview.summary.firstTimestamp!.toLocal().toString()),
            const SizedBox(height: 24),
            if (preview.peers.isEmpty)
              Text(
                'No BLE connections were found in this capture. If the watch '
                'was already connected when snoop logging started, the '
                'connection event is missing — toggle Bluetooth off and on '
                'before capturing.',
                style: TextStyle(color: scheme.error, fontSize: 12),
              )
            else ...[
              Text('Which device?',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'Busiest first. A watch-face transfer will be the noisiest '
                'thing in the log by a wide margin.',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              const SizedBox(height: 8),
              RadioGroup<String>(
                groupValue: _selectedPeer,
                onChanged: (v) => setState(() => _selectedPeer = v),
                child: Column(
                  children: [
                    for (final peer in preview.peers)
                      RadioListTile<String>(
                        dense: true,
                        value: peer.address,
                        title: Text(peer.address,
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                        subtitle: Text(
                          '${peer.attPacketCount} ATT packets · '
                          '${peer.connectionHandles.length} connections',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Session name',
                  helperText: 'What experiment was this? e.g. watchface-A',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                icon: const Icon(Icons.save),
                label: const Text('Import as capture session'),
                onPressed: _busy || _selectedPeer == null ? null : _import,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.warning = false});

  final String label;
  final String value;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 170,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: warning ? scheme.error : scheme.outline)),
          ),
          Text(value,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: warning ? scheme.error : null,
              )),
        ],
      ),
    );
  }
}

/// Phase 4: the packet monitor.
///
/// A network debugger for BLE. Every operation the app performs appears here
/// with its time, direction, attribute and payload. Pause freezes the view
/// without stopping capture, so a burst can be read without it scrolling away.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/ble_packet.dart';
import '../../core/models/ble_uuid.dart';
import '../../core/providers.dart';
import '../../features/capture/capture_recorder.dart';
import '../widgets/packet_tile.dart';

class PacketMonitorScreen extends ConsumerStatefulWidget {
  const PacketMonitorScreen({super.key});

  @override
  ConsumerState<PacketMonitorScreen> createState() =>
      _PacketMonitorScreenState();
}

class _PacketMonitorScreenState extends ConsumerState<PacketMonitorScreen> {
  StreamSubscription<BlePacket>? _subscription;
  List<BlePacket> _packets = [];

  bool _paused = false;
  PacketDirection? _directionFilter;
  String? _characteristicFilter;

  @override
  void initState() {
    super.initState();
    final bus = ref.read(eventBusProvider);
    _packets = bus.recent.reversed.toList();
    _subscription = bus.stream.listen((packet) {
      // Pausing freezes the display only. The packet is still on the bus and
      // still recorded if a session is running — a pause must never create a
      // hole in the evidence.
      if (_paused || !mounted) return;
      setState(() => _packets.insert(0, packet));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  List<BlePacket> get _visible => _packets.where((p) {
        if (_directionFilter != null && p.direction != _directionFilter) {
          return false;
        }
        if (_characteristicFilter != null &&
            p.characteristicUuid != _characteristicFilter) {
          return false;
        }
        return true;
      }).toList();

  List<String> get _characteristics => _packets
      .map((p) => p.characteristicUuid)
      .whereType<String>()
      .toSet()
      .toList()
    ..sort();

  Future<void> _export() async {
    final text = _visible.reversed
        .map((p) => '${p.timestamp.toIso8601String()}  '
            '${p.direction.wireName}  ${p.operation.wireName}  '
            '${p.characteristicUuid ?? p.attributeLabel}  ${p.payloadHex}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_visible.length} packets copied')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final recorder = ref.watch(captureRecorderProvider).value;
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Packet Monitor'),
        actions: [
          IconButton(
            tooltip: _paused ? 'Resume' : 'Pause',
            icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => _paused = !_paused),
          ),
          IconButton(
            tooltip: 'Clear view',
            icon: const Icon(Icons.delete_sweep),
            onPressed: () {
              ref.read(eventBusProvider).clearBuffer();
              setState(_packets.clear);
            },
          ),
          IconButton(
            tooltip: 'Copy visible packets',
            icon: const Icon(Icons.ios_share),
            onPressed: visible.isEmpty ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          if (recorder != null && recorder.isRecording)
            _RecordingBanner(recorder: recorder),
          if (_paused)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.tertiaryContainer,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
              child: Text(
                'Display paused — packets are still being captured',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          _FilterRow(
            direction: _directionFilter,
            characteristic: _characteristicFilter,
            characteristics: _characteristics,
            onDirection: (d) => setState(() => _directionFilter = d),
            onCharacteristic: (c) => setState(() => _characteristicFilter = c),
            shown: visible.length,
            total: _packets.length,
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        _packets.isEmpty
                            ? 'No BLE activity yet.\nScan, connect or read a '
                                'characteristic and it will appear here.'
                            : 'No packets match the filter.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, i) => PacketTile(packet: visible[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _RecordingBanner extends StatelessWidget {
  const _RecordingBanner({required this.recorder});

  final CaptureRecorder recorder;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.fiber_manual_record, size: 14, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Recording into "${recorder.session?.name}"',
              style: TextStyle(
                  fontSize: 12,
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.direction,
    required this.characteristic,
    required this.characteristics,
    required this.onDirection,
    required this.onCharacteristic,
    required this.shown,
    required this.total,
  });

  final PacketDirection? direction;
  final String? characteristic;
  final List<String> characteristics;
  final ValueChanged<PacketDirection?> onDirection;
  final ValueChanged<String?> onCharacteristic;
  final int shown;
  final int total;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: direction == null,
            onSelected: (_) => onDirection(null),
          ),
          const SizedBox(width: 6),
          for (final d in PacketDirection.values) ...[
            ChoiceChip(
              label: Text(d.label),
              selected: direction == d,
              onSelected: (_) => onDirection(d),
            ),
            const SizedBox(width: 6),
          ],
          if (characteristics.isNotEmpty) ...[
            const VerticalDivider(width: 12),
            DropdownButton<String?>(
              value: characteristic,
              hint: const Text('Characteristic', style: TextStyle(fontSize: 13)),
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
              onChanged: onCharacteristic,
            ),
          ],
          const SizedBox(width: 12),
          Text('$shown / $total',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

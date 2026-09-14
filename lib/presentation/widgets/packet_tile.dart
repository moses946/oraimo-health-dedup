/// One row in the packet monitor.
///
/// Shows the five things the spec asks for — time, direction, operation,
/// attribute and payload — and nothing that would amount to interpreting the
/// bytes.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/ble_packet.dart';
import 'hex_view.dart';

/// Formats a timestamp as HH:MM:SS.mmm, the resolution the spec's example uses.
String formatPacketTime(DateTime timestamp) {
  final t = timestamp.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final ms = t.millisecond.toString().padLeft(3, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$ms';
}

class PacketTile extends StatelessWidget {
  const PacketTile({super.key, required this.packet, this.showSeq = true});

  final BlePacket packet;
  final bool showSeq;

  Color _directionColour(ColorScheme scheme) => switch (packet.direction) {
        PacketDirection.phoneToWatch => scheme.primary,
        PacketDirection.watchToPhone => scheme.tertiary,
        PacketDirection.local => scheme.outline,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = packet.status == PacketStatus.failed;
    final colour = failed ? scheme.error : _directionColour(scheme);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        leading: Icon(
          switch (packet.direction) {
            PacketDirection.phoneToWatch => Icons.north_east,
            PacketDirection.watchToPhone => Icons.south_west,
            PacketDirection.local => Icons.info_outline,
          },
          color: colour,
          size: 20,
        ),
        title: Row(
          children: [
            Text(
              formatPacketTime(packet.timestamp),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                packet.operation.wireName.toUpperCase(),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: colour,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (packet.payloadLength > 0)
              Text(
                '${packet.payloadLength} B',
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '${packet.direction.label}  ·  ${packet.attributeLabel}',
              style: TextStyle(fontSize: 11, color: scheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
            if (packet.payloadHex.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                packet.payloadDisplay,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (failed && packet.error != null) ...[
              const SizedBox(height: 4),
              Text(
                packet.error!,
                style: TextStyle(fontSize: 11, color: scheme.error),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
        children: [
          _DetailRow('Sequence', showSeq ? '${packet.seq}' : '—'),
          _DetailRow('Timestamp (UTC)', packet.timestamp.toIso8601String()),
          _DetailRow('Elapsed', '${packet.elapsedUs} us'),
          _DetailRow('Direction', packet.direction.wireName),
          _DetailRow('Operation', packet.operation.wireName),
          _DetailRow('Service', packet.serviceUuid ?? 'unknown'),
          _DetailRow('Characteristic', packet.characteristicUuid ?? 'unknown'),
          if (packet.descriptorUuid != null)
            _DetailRow('Descriptor', packet.descriptorUuid!),
          if (packet.attHandle != null)
            _DetailRow('ATT handle',
                '0x${packet.attHandle!.toRadixString(16).padLeft(4, '0')}'),
          _DetailRow('Length', '${packet.payloadLength} bytes'),
          if (packet.error != null) _DetailRow('Error', packet.error!),
          if (packet.note != null) _DetailRow('Note', packet.note!),
          const SizedBox(height: 8),
          if (packet.payloadHex.isNotEmpty) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: HexView(payloadHex: packet.payloadHex, showDump: true),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CopyButton(text: packet.payloadHex, label: 'Hex'),
                  TextButton.icon(
                    icon: const Icon(Icons.data_object, size: 16),
                    label: const Text('Copy packet'),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: packet.toJson().toString()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Packet copied'),
                            duration: Duration(seconds: 1),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

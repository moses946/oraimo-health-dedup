/// Phase 3: one characteristic, up close.
///
/// Read it, write raw hex to it, subscribe to it, and watch what comes back —
/// with the bytes shown as bytes. No field is labelled, no value is decoded,
/// and nothing is pre-filled with a payload we think might work (rule 2).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bluetooth/ble_transport.dart';
import '../../core/hex/hex_codec.dart';
import '../../core/models/ble_packet.dart';
import '../../core/models/ble_uuid.dart';
import '../../core/models/gatt_models.dart';
import '../../core/models/sig_assigned_numbers.dart';
import '../../core/providers.dart';
import '../widgets/hex_view.dart';
import '../widgets/packet_tile.dart';

class CharacteristicScreen extends ConsumerStatefulWidget {
  const CharacteristicScreen({super.key, required this.characteristic});

  final GattCharacteristic characteristic;

  @override
  ConsumerState<CharacteristicScreen> createState() =>
      _CharacteristicScreenState();
}

class _CharacteristicScreenState extends ConsumerState<CharacteristicScreen> {
  final TextEditingController _writeController = TextEditingController();
  final List<BlePacket> _activity = [];
  StreamSubscription<BlePacket>? _activitySub;

  bool _busy = false;
  bool _withoutResponse = false;
  bool _subscribed = false;
  String? _error;
  String? _hexError;

  GattCharacteristic get _characteristic => widget.characteristic;

  @override
  void initState() {
    super.initState();
    final transport = ref.read(transportProvider);
    _subscribed =
        transport.subscribedCharacteristics.contains(_characteristic.uuid);
    _withoutResponse = !_characteristic.properties.write &&
        _characteristic.properties.writeWithoutResponse;

    // Show only this characteristic's traffic, taken off the same bus the
    // packet monitor and the recorder use.
    _activitySub = ref.read(eventBusProvider).stream.listen((packet) {
      if (packet.characteristicUuid != _characteristic.uuid) return;
      if (!mounted) return;
      setState(() {
        _activity.insert(0, packet);
        if (_activity.length > 200) _activity.removeLast();
      });
    });
  }

  @override
  void dispose() {
    _activitySub?.cancel();
    _writeController.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on BleTransportException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _read() => _guard(() async {
        await ref.read(transportProvider).readCharacteristic(
              serviceUuid: _characteristic.serviceUuid,
              characteristicUuid: _characteristic.uuid,
            );
      });

  Future<void> _write() async {
    Uint8List value;
    try {
      value = hexToBytes(_writeController.text);
    } on HexFormatException catch (e) {
      setState(() => _hexError = e.message);
      return;
    }
    setState(() => _hexError = null);

    await _guard(() async {
      await ref.read(transportProvider).writeCharacteristic(
            serviceUuid: _characteristic.serviceUuid,
            characteristicUuid: _characteristic.uuid,
            value: value,
            withoutResponse: _withoutResponse,
          );
    });
  }

  Future<void> _toggleSubscription() => _guard(() async {
        final transport = ref.read(transportProvider);
        if (_subscribed) {
          await transport.unsubscribe(
            serviceUuid: _characteristic.serviceUuid,
            characteristicUuid: _characteristic.uuid,
          );
        } else {
          await transport.subscribe(
            serviceUuid: _characteristic.serviceUuid,
            characteristicUuid: _characteristic.uuid,
          );
        }
        if (mounted) setState(() => _subscribed = !_subscribed);
      });

  @override
  Widget build(BuildContext context) {
    final properties = _characteristic.properties;
    final uuid = BleUuid.tryParse(_characteristic.uuid);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(uuid?.short ?? _characteristic.uuid),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  _characteristic.uuid,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  sigLabelFor(_characteristic.uuid),
                  style: TextStyle(fontSize: 12, color: scheme.primary),
                ),
                const SizedBox(height: 4),
                Text(
                  'in service ${_characteristic.serviceUuid}',
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: scheme.outline),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final label in properties.labels)
                      Chip(
                        label: Text(label,
                            style: const TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w700)),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                      ),
                  ],
                ),
                if (_characteristic.descriptors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('Descriptors',
                      style: Theme.of(context).textTheme.labelMedium),
                  for (final descriptor in _characteristic.descriptors)
                    SelectableText(
                      '  ${BleUuid.tryParse(descriptor.uuid)?.short ?? descriptor.uuid}'
                      '  ${sigNameFor(descriptor.uuid)?.name ?? ''}',
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 11),
                    ),
                ],
              ],
            ),
          ),
          if (_error != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _error!,
                style:
                    TextStyle(color: scheme.onErrorContainer, fontSize: 12),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: const Icon(Icons.download),
                    label: const Text('Read'),
                    onPressed: properties.read && !_busy ? _read : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    icon: Icon(_subscribed
                        ? Icons.notifications_off
                        : Icons.notifications_active),
                    label: Text(_subscribed ? 'Unsubscribe' : 'Subscribe'),
                    onPressed: properties.isSubscribable && !_busy
                        ? _toggleSubscription
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (properties.isWritable) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Write', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _writeController,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 14),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      isDense: true,
                      hintText: 'AA 01 04 00 7F',
                      helperText: _writeController.text.isEmpty
                          ? 'Raw bytes as hex. Spaces, 0x and : are ignored.'
                          : '${hexToBytes(_writeController.text.replaceAll(RegExp(r'[^0-9a-fA-F]'), '')).length} bytes',
                      errorText: _hexError,
                    ),
                    onChanged: (_) => setState(() => _hexError = null),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      if (properties.write && properties.writeWithoutResponse)
                        Expanded(
                          child: SegmentedButton<bool>(
                            style: const ButtonStyle(
                                visualDensity: VisualDensity.compact),
                            segments: const [
                              ButtonSegment(value: false, label: Text('WRITE')),
                              ButtonSegment(
                                  value: true, label: Text('WRITE_NR')),
                            ],
                            selected: {_withoutResponse},
                            onSelectionChanged: (s) =>
                                setState(() => _withoutResponse = s.first),
                          ),
                        ),
                      if (properties.write && properties.writeWithoutResponse)
                        const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          icon: const Icon(Icons.upload),
                          label: const Text('Send'),
                          onPressed: _busy ? null : _write,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Activity',
                    style: Theme.of(context).textTheme.labelLarge),
                const Spacer(),
                Text('${_activity.length} packets',
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
          ),
          if (_activity.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'Nothing yet. Read, write or subscribe above.',
                  style: TextStyle(color: scheme.outline, fontSize: 12),
                ),
              ),
            )
          else
            for (final packet in _activity)
              PacketTile(packet: packet, showSeq: false),
          if (_activity.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: HexView(payloadHex: _activity.first.payloadHex),
            ),
        ],
      ),
    );
  }
}

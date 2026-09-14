/// Phase 2 and 3: connection state and the GATT explorer.
///
/// The connection banner shows every state the transport can be in, with the
/// platform's own error text when something fails. Nothing is hidden and
/// nothing is retried behind the user's back without saying so.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bluetooth/ble_transport.dart';
import '../../core/models/ble_device_record.dart';
import '../../core/models/ble_uuid.dart';
import '../../core/models/gatt_models.dart';
import '../../core/providers.dart';
import '../../features/device_connection/connection_manager.dart';
import 'characteristic_screen.dart';

class DeviceDetailScreen extends ConsumerStatefulWidget {
  const DeviceDetailScreen({super.key, required this.device});

  final BleDeviceRecord device;

  @override
  ConsumerState<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends ConsumerState<DeviceDetailScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on BleTransportException {
      // Already recorded on the connection status and in the packet log; the
      // banner renders it. Swallowing it here would be hiding it twice over,
      // so the status is what the user reads.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(connectionManagerProvider);
    final status = ref.watch(connectionStatusProvider).value ?? manager.status;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.displayName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: _busy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: Column(
        children: [
          ConnectionBanner(status: status),
          _ActionBar(
            status: status,
            busy: _busy,
            onConnect: () => _run(() => manager.connect(
                  widget.device.address,
                  name: widget.device.name,
                )),
            onDisconnect: () => _run(manager.disconnect),
            onDiscover: () => _run(manager.discoverServices),
          ),
          const Divider(height: 1),
          Expanded(child: _GattExplorer(status: status)),
        ],
      ),
    );
  }
}

/// The connection state, always visible, always specific.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key, required this.status});

  final ConnectionStatus status;

  (Color, Color, IconData) _style(ColorScheme scheme) =>
      switch (status.state) {
        BleConnectionState.connected => (
            scheme.primaryContainer,
            scheme.onPrimaryContainer,
            Icons.bluetooth_connected
          ),
        BleConnectionState.connecting ||
        BleConnectionState.reconnecting ||
        BleConnectionState.disconnecting =>
          (
            scheme.secondaryContainer,
            scheme.onSecondaryContainer,
            Icons.bluetooth_searching
          ),
        BleConnectionState.error => (
            scheme.errorContainer,
            scheme.onErrorContainer,
            Icons.error_outline
          ),
        BleConnectionState.disconnected => (
            scheme.surfaceContainerHighest,
            scheme.onSurfaceVariant,
            Icons.bluetooth_disabled
          ),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = _style(scheme);

    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: 10),
              Text(
                status.state.label.toUpperCase(),
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const Spacer(),
              if (status.mtu != null)
                Text('MTU ${status.mtu}',
                    style: TextStyle(color: foreground, fontSize: 12)),
            ],
          ),
          if (status.reconnectAttempt > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Reconnect attempt ${status.reconnectAttempt}'
              '${status.nextRetryIn == null ? '' : ' — retrying in '
                  '${status.nextRetryIn!.inMilliseconds} ms'}',
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ],
          if (status.error != null) ...[
            const SizedBox(height: 6),
            SelectableText(
              status.error!,
              style: TextStyle(color: foreground, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.status,
    required this.busy,
    required this.onConnect,
    required this.onDisconnect,
    required this.onDiscover,
  });

  final ConnectionStatus status;
  final bool busy;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onDiscover;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: status.isConnected
                ? OutlinedButton.icon(
                    icon: const Icon(Icons.link_off),
                    label: const Text('Disconnect'),
                    onPressed: busy ? null : onDisconnect,
                  )
                : FilledButton.icon(
                    icon: const Icon(Icons.link),
                    label: const Text('Connect'),
                    onPressed: busy || status.isBusy ? null : onConnect,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton.tonalIcon(
              icon: const Icon(Icons.travel_explore),
              label: const Text('Discover'),
              onPressed: busy || !status.isConnected ? null : onDiscover,
            ),
          ),
        ],
      ),
    );
  }
}

/// Phase 3: the attribute database, exactly as discovered.
class _GattExplorer extends StatelessWidget {
  const _GattExplorer({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    if (!status.servicesDiscovered) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            status.isConnected
                ? 'Connected. Tap Discover to read the attribute database.'
                : 'Connect to the device to explore its GATT services.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    if (status.services.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Discovery returned no services.'),
        ),
      );
    }

    return ListView.builder(
      itemCount: status.services.length,
      itemBuilder: (context, index) =>
          _ServiceTile(service: status.services[index]),
    );
  }
}

class _ServiceTile extends StatelessWidget {
  const _ServiceTile({required this.service});

  final GattService service;

  @override
  Widget build(BuildContext context) {
    final uuid = BleUuid.tryParse(service.uuid);
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: Icon(Icons.folder_outlined, color: scheme.primary),
        title: Text(
          uuid?.short ?? service.uuid,
          style: const TextStyle(
              fontFamily: 'monospace', fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${service.isPrimary ? 'primary' : 'secondary'} · '
          '${service.characteristics.length} characteristics',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectableText(
              service.uuid,
              style: TextStyle(
                  fontFamily: 'monospace', fontSize: 11, color: scheme.outline),
            ),
          ),
          for (final characteristic in service.characteristics)
            _CharacteristicTile(characteristic: characteristic),
        ],
      ),
    );
  }
}

class _CharacteristicTile extends StatelessWidget {
  const _CharacteristicTile({required this.characteristic});

  final GattCharacteristic characteristic;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final uuid = BleUuid.tryParse(characteristic.uuid);

    return ListTile(
      dense: true,
      leading: const Icon(Icons.memory, size: 20),
      title: Text(
        uuid?.short ?? characteristic.uuid,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final label in characteristic.properties.labels)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
              ),
            if (characteristic.descriptors.isNotEmpty)
              Text(
                '${characteristic.descriptors.length} descriptors',
                style: TextStyle(fontSize: 10, color: scheme.outline),
              ),
          ],
        ),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CharacteristicScreen(characteristic: characteristic),
        ),
      ),
    );
  }
}

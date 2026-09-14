/// Phase 1: Nearby Devices.
///
/// Shows every advertising device with everything the advertisement carried.
/// Nothing is filtered out by default and no device is singled out by a
/// hard-coded name or UUID — identifying the Watch 6R is the operator's job,
/// helped by the filters (rule 1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/bluetooth/ble_transport.dart';
import '../../core/models/ble_device_record.dart';
import '../../core/models/ble_uuid.dart';
import '../../core/providers.dart';
import '../../features/device_scan/scan_controller.dart';
import 'device_detail_screen.dart';

class NearbyDevicesScreen extends ConsumerWidget {
  const NearbyDevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(scanControllerProvider);
    final controller = ref.read(scanControllerProvider.notifier);
    final adapter = ref.watch(adapterStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            tooltip: 'Clear list',
            icon: const Icon(Icons.clear_all),
            onPressed: controller.clearDevices,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: state.isScanning ? controller.stopScan : controller.startScan,
        icon: Icon(state.isScanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(state.isScanning ? 'Stop' : 'Scan'),
      ),
      body: Column(
        children: [
          _AdapterBanner(adapter: adapter.value),
          if (state.error != null)
            _ErrorBanner(
              message: state.error!,
              onDismiss: () => controller.setQuery(state.query),
            ),
          _FilterBar(state: state, controller: controller),
          Expanded(
            child: _DeviceList(state: state, controller: controller),
          ),
        ],
      ),
    );
  }
}

class _AdapterBanner extends StatelessWidget {
  const _AdapterBanner({this.adapter});

  final BleAdapterState? adapter;

  @override
  Widget build(BuildContext context) {
    if (adapter == null || adapter!.isReady) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              adapter!.label,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          // The platform's own wording, in full. Truncating a BLE error
          // usually removes the only part that identifies the problem.
          Expanded(
            child: SelectableText(
              message,
              style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state, required this.controller});

  final ScanState state;
  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        children: [
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 20),
              hintText: 'Filter by name, address, service UUID or adv data',
              border: OutlineInputBorder(),
            ),
            onChanged: controller.setQuery,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilterChip(
                label: const Text('Named only'),
                selected: state.namedOnly,
                onSelected: controller.setNamedOnly,
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Strong signal'),
                selected: state.minRssi != null,
                onSelected: (v) => controller.setMinRssi(v ? -70 : null),
              ),
              const Spacer(),
              Text(
                '${state.visibleDevices.length} / ${state.devices.length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.state, required this.controller});

  final ScanState state;
  final ScanController controller;

  @override
  Widget build(BuildContext context) {
    final devices = state.visibleDevices;

    if (devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.watch_off,
                  size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(
                state.isScanning
                    ? 'Scanning…'
                    : state.devices.isEmpty
                        ? 'No devices yet. Tap Scan.\n\nPut the watch close to '
                            'the phone. If it is already connected to Oraimo '
                            'Health, it may not be advertising — disconnect it '
                            'there first.'
                        : 'No devices match the filter.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 88),
      itemCount: devices.length,
      itemBuilder: (context, index) => _DeviceCard(
        device: devices[index],
        onFavourite: () => controller.toggleFavourite(devices[index]),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.onFavourite});

  final BleDeviceRecord device;
  final VoidCallback onFavourite;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: _RssiIndicator(rssi: device.lastRssi),
        title: Text(
          device.displayName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${device.address}   ${device.lastRssi} dBm'
          '${device.connectable ? '' : '   not connectable'}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        trailing: IconButton(
          tooltip: device.isFavourite ? 'Unmark' : 'Mark as device of interest',
          icon: Icon(
            device.isFavourite ? Icons.star : Icons.star_border,
            color: device.isFavourite ? scheme.primary : scheme.outline,
          ),
          onPressed: onFavourite,
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          _Field('Address', device.address),
          _Field('RSSI', '${device.lastRssi} dBm'),
          if (device.txPowerLevel != null)
            _Field('TX power', '${device.txPowerLevel} dBm'),
          _Field('Connectable', device.connectable ? 'yes' : 'no'),
          _Field('First seen', device.firstSeenAt.toLocal().toString()),
          _Field('Last seen', device.lastSeenAt.toLocal().toString()),
          if (device.advertisedServiceUuids.isNotEmpty)
            _Field(
              'Service UUIDs',
              device.advertisedServiceUuids
                  .map((u) => BleUuid.tryParse(u)?.short ?? u)
                  .join('\n'),
            ),
          if (device.manufacturerDataHex.isNotEmpty)
            _Field(
              'Manufacturer data',
              device.manufacturerDataHex.entries
                  .map((e) =>
                      'company 0x${e.key.toRadixString(16).padLeft(4, '0')}: ${e.value}')
                  .join('\n'),
            ),
          if (device.serviceDataHex.isNotEmpty)
            _Field(
              'Service data',
              device.serviceDataHex.entries
                  .map((e) =>
                      '${BleUuid.tryParse(e.key)?.short ?? e.key}: ${e.value}')
                  .join('\n'),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.link),
              label: const Text('Connect and explore'),
              onPressed: device.connectable
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DeviceDetailScreen(device: device),
                        ),
                      )
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _RssiIndicator extends StatelessWidget {
  const _RssiIndicator({required this.rssi});

  final int rssi;

  @override
  Widget build(BuildContext context) {
    // Rough signal buckets, purely a display aid.
    final bars = switch (rssi) {
      >= -60 => 4,
      >= -70 => 3,
      >= -80 => 2,
      >= -90 => 1,
      _ => 0,
    };
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(4, (i) {
          return Container(
            width: 4,
            height: 6.0 + i * 4,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: BoxDecoration(
              color: i < bars
                  ? scheme.primary
                  : scheme.outlineVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        }),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
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

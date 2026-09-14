/// Developer mode.
///
/// The research side of the app, gathered in one place: the raw log, the
/// attribute browser, the packet inspector, the saved experiments, the
/// evidence ledger, and the export that gets all of it off the phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../features/capture/session_export_service.dart';
import 'ble_log_screen.dart';
import 'btsnoop_import_screen.dart';
import 'capture_sessions_screen.dart';
import 'packet_monitor_screen.dart';
import 'protocol_database_screen.dart';

class DeveloperScreen extends ConsumerWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Developer')),
      body: ListView(
        children: [
          const _SectionHeader('Investigate'),
          _Item(
            icon: Icons.terminal,
            title: 'BLE Log',
            subtitle: 'Raw BLE activity, including every error',
            builder: (_) => const BleLogScreen(),
          ),
          _Item(
            icon: Icons.account_tree,
            title: 'Packet Inspector',
            subtitle: 'Live hexadecimal packet viewer',
            builder: (_) => const PacketMonitorScreen(),
          ),
          const _SectionHeader('Evidence'),
          _Item(
            icon: Icons.science,
            title: 'Capture Sessions',
            subtitle: 'Saved experiments',
            builder: (_) => const CaptureSessionsScreen(),
          ),
          _Item(
            icon: Icons.file_open,
            title: 'Import HCI snoop log',
            subtitle: 'See what the official app sends',
            builder: (_) => const BtsnoopImportScreen(),
          ),
          _Item(
            icon: Icons.psychology,
            title: 'Protocol Database',
            subtitle: 'Observations and hypotheses',
            builder: (_) => const ProtocolDatabaseScreen(),
          ),
          const _SectionHeader('Export'),
          ListTile(
            leading: const Icon(Icons.ios_share),
            title: const Text('Export all research data'),
            subtitle: const Text(
                'Every session, packet, observation and hypothesis as JSON'),
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              try {
                final repository = await ref.read(repositoryProvider.future);
                final service = SessionExportService(repository);
                final file = await service.writeEverything();
                await service.share(file, subject: 'Oraimo Lab research data');
              } catch (e) {
                messenger.showSnackBar(
                    SnackBar(content: Text('Export failed: $e')));
              }
            },
          ),
          const _SectionHeader('Status'),
          const _ProtocolStatusCard(),
        ],
      ),
    );
  }
}

/// A standing reminder of what is actually known.
///
/// It says "nothing" because nothing is, and it should keep saying so until a
/// hypothesis in the database reaches SUPPORTED on real captured evidence.
class _ProtocolStatusCard extends StatelessWidget {
  const _ProtocolStatusCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: const Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What we know about the Watch 6R protocol',
                style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 10),
            Text(
              'Nothing, yet.\n\n'
              'No service UUIDs. No characteristic UUIDs. No command format, '
              'no response format, no packet framing, no checksum scheme. '
              'Nothing about the watch-face format or how it is transferred. '
              'Whether any of it is encrypted is unknown.\n\n'
              'This app contains no decoder and no packet builder, because '
              'there is nothing yet to decode or build. It captures evidence. '
              'Implementation comes after the protocol is understood, not '
              'before.',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  const _Item({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: builder)),
    );
  }
}

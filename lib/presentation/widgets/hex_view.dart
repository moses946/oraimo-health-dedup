/// Displays a payload as hex and ASCII.
///
/// Monospaced and byte-grouped, because the entire job of this app is reading
/// unknown bytes and spotting structure in them by eye.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/hex/hex_codec.dart';

class HexView extends StatelessWidget {
  const HexView({
    super.key,
    required this.payloadHex,
    this.showAscii = true,
    this.showDump = false,
    this.maxLines,
  });

  final String payloadHex;
  final bool showAscii;

  /// Offset-prefixed dump, for payloads long enough that column alignment
  /// helps more than a single run-on line.
  final bool showDump;

  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    if (payloadHex.isEmpty) {
      return Text(
        '(no payload)',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: Theme.of(context).colorScheme.outline,
            ),
      );
    }

    final bytes = hexToBytes(payloadHex);
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontFeatures: const [FontFeature.tabularFigures()],
      fontSize: 13,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurface,
    );

    if (showDump) {
      return SelectableText(hexDump(bytes), style: mono);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          bytesToHexDisplay(bytes),
          style: mono,
          maxLines: maxLines,
        ),
        if (showAscii) ...[
          const SizedBox(height: 4),
          SelectableText(
            bytesToAscii(bytes),
            style: mono.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
            maxLines: maxLines,
          ),
        ],
      ],
    );
  }
}

/// A tappable chip that copies text to the clipboard.
class CopyButton extends StatelessWidget {
  const CopyButton({super.key, required this.text, this.label = 'Copy'});

  final String text;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: const Icon(Icons.copy, size: 16),
      label: Text(label),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Copied $label.toLowerCase()'),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      },
    );
  }
}

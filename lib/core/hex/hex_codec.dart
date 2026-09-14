/// Hexadecimal helpers.
///
/// Rule 6 of the project's engineering rules: packets are stored in
/// hexadecimal. Rule 4: raw bytes are never altered. Everything here is a pure
/// representation change — no interpretation, no normalisation of payloads.
library;

import 'dart:typed_data';

/// Thrown when a user-supplied hex string cannot be parsed.
class HexFormatException implements Exception {
  HexFormatException(this.message, {this.offset});

  final String message;
  final int? offset;

  @override
  String toString() => offset == null
      ? 'HexFormatException: $message'
      : 'HexFormatException: $message (at offset $offset)';
}

/// Converts [bytes] to a compact uppercase hex string with no separators.
///
/// This is the canonical *storage* form: `AA0104007F`.
String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Converts [bytes] to the space-grouped *display* form: `AA 01 04 00 7F`.
String bytesToHexDisplay(List<int> bytes) {
  return bytes
      .map((b) => (b & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0'))
      .join(' ');
}

/// Regroups a compact storage hex string into the display form.
String hexToDisplay(String compactHex) => bytesToHexDisplay(hexToBytes(compactHex));

/// Parses a hex string into bytes.
///
/// Tolerates spaces, newlines, tabs, commas, `0x` prefixes and `-`/`:`
/// separators, so a payload pasted from a log, a hex editor or a datasheet all
/// parse the same way. Throws [HexFormatException] on anything else — an
/// unparseable payload is an error the user must see, never a silently
/// truncated write (rule 9).
Uint8List hexToBytes(String input) {
  final cleaned = StringBuffer();
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    if (ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == ',' ||
        ch == '-' || ch == ':' || ch == '_') {
      i++;
      continue;
    }
    if ((ch == '0') && i + 1 < input.length && (input[i + 1] == 'x' || input[i + 1] == 'X')) {
      i += 2;
      continue;
    }
    if (!_isHexDigit(ch)) {
      throw HexFormatException("'$ch' is not a hex digit", offset: i);
    }
    cleaned.write(ch);
    i++;
  }

  final digits = cleaned.toString();
  if (digits.length.isOdd) {
    throw HexFormatException(
      'hex string has an odd number of digits (${digits.length}); '
      'a payload must be a whole number of bytes',
    );
  }

  final out = Uint8List(digits.length ~/ 2);
  for (var j = 0; j < out.length; j++) {
    out[j] = int.parse(digits.substring(j * 2, j * 2 + 2), radix: 16);
  }
  return out;
}

/// True when [input] parses as hex. Never throws.
bool isValidHex(String input) {
  try {
    hexToBytes(input);
    return true;
  } on HexFormatException {
    return false;
  }
}

/// Renders [bytes] as an ASCII sidebar, substituting [placeholder] for any byte
/// outside the printable range. Purely a viewing aid — it asserts nothing about
/// whether the payload *is* text.
String bytesToAscii(List<int> bytes, {String placeholder = '.'}) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    final b = byte & 0xFF;
    buffer.write(b >= 0x20 && b <= 0x7E ? String.fromCharCode(b) : placeholder);
  }
  return buffer.toString();
}

/// Renders a classic hex dump: offset, hex columns, ASCII sidebar.
String hexDump(List<int> bytes, {int bytesPerLine = 16}) {
  if (bytes.isEmpty) return '';
  final lines = <String>[];
  for (var offset = 0; offset < bytes.length; offset += bytesPerLine) {
    final end = (offset + bytesPerLine).clamp(0, bytes.length);
    final chunk = bytes.sublist(offset, end);
    final hex = bytesToHexDisplay(chunk).padRight(bytesPerLine * 3 - 1);
    final ascii = bytesToAscii(chunk);
    lines.add('${offset.toRadixString(16).padLeft(8, '0')}  $hex  |$ascii|');
  }
  return lines.join('\n');
}

bool _isHexDigit(String ch) {
  final c = ch.codeUnitAt(0);
  return (c >= 0x30 && c <= 0x39) || // 0-9
      (c >= 0x41 && c <= 0x46) || // A-F
      (c >= 0x61 && c <= 0x66); // a-f
}

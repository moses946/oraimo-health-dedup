/// Low-level reader for Android Bluetooth HCI snoop logs.
///
/// An Android app cannot observe another app's GATT traffic, so this is the
/// only way to see what the official Oraimo Health app says to the watch: the
/// phone's own Bluetooth stack writes every HCI packet to a btsnoop file, and
/// we read it back here.
///
/// This layer does the file format only — header, record framing, timestamps.
/// It does not know what HCI is; that is [HciParser]'s job.
///
/// Format reference: the btsnoop file format as written by Android's
/// `system/bt` stack and read by Wireshark's `btsnoop.c`.
library;

import 'dart:typed_data';

/// Raised when the input is not a btsnoop file, or is one we cannot read.
///
/// Thrown rather than skipped: silently reading half a malformed capture would
/// produce evidence we could not trust.
class BtsnoopFormatException implements Exception {
  BtsnoopFormatException(this.message, {this.offset});

  final String message;
  final int? offset;

  @override
  String toString() => offset == null
      ? 'BtsnoopFormatException: $message'
      : 'BtsnoopFormatException: $message (at byte $offset)';
}

/// The 8-byte identification pattern: "btsnoop\0".
const List<int> kBtsnoopMagic = [0x62, 0x74, 0x73, 0x6E, 0x6F, 0x6F, 0x70, 0x00];

/// Datalink type for HCI UART (H4), which is what Android writes.
const int kDatalinkH4 = 1002;

/// Other datalink types the format defines. We reject them explicitly rather
/// than guessing at their framing.
const int kDatalinkH1 = 1001;
const int kDatalinkBscp = 1003;
const int kDatalinkH5 = 1004;

/// Microseconds between the btsnoop epoch and the Unix epoch.
///
/// This is **not** the mathematically correct interval. Counting proleptic
/// Gregorian days from 0000-01-01 to 1970-01-01 gives 719528 days, i.e.
/// 62167219200000000 us. The constant below is 719540 days — twelve days more.
///
/// It is used anyway, deliberately, because it is what the ecosystem uses:
/// Android's stack adds exactly this value when writing a record
/// (`BTSNOOP_EPOCH_DELTA` in `system/bt/hci/src/btsnoop.cc`) and Wireshark
/// subtracts exactly this value when reading one. Using the "correct" figure
/// would put every imported timestamp twelve days away from the time
/// Wireshark shows for the same capture, which would be far worse than being
/// twelve days away from the year 0.
const int kBtsnoopEpochDeltaUs = 0x00dcddb30f2f8000;

/// Direction and type flags on a record.
extension BtsnoopFlags on int {
  /// True when the controller sent this to the host — i.e. it came from the
  /// remote device. False when the host sent it out.
  bool get isReceived => this & 0x01 != 0;

  /// True for HCI commands and events, false for ACL/SCO data.
  bool get isCommandOrEvent => this & 0x02 != 0;
}

class BtsnoopRecord {
  const BtsnoopRecord({
    required this.originalLength,
    required this.includedLength,
    required this.flags,
    required this.cumulativeDrops,
    required this.timestamp,
    required this.data,
  });

  /// Length of the packet on the wire.
  final int originalLength;

  /// Length actually stored. Less than [originalLength] when the capture was
  /// configured to truncate.
  final int includedLength;

  final int flags;
  final int cumulativeDrops;
  final DateTime timestamp;
  final Uint8List data;

  bool get isReceived => flags.isReceived;
  bool get isCommandOrEvent => flags.isCommandOrEvent;

  /// True when bytes are missing from this record.
  ///
  /// Matters a great deal for us: a truncated record means the payload we are
  /// trying to reverse engineer is incomplete, and any conclusion drawn from
  /// it would be wrong. The importer reports these rather than hiding them.
  bool get isTruncated => includedLength < originalLength;
}

class BtsnoopFile {
  const BtsnoopFile({required this.version, required this.datalinkType});

  final int version;
  final int datalinkType;
}

/// Streaming reader over a btsnoop file already in memory.
class BtsnoopReader {
  BtsnoopReader(this.bytes) : _view = ByteData.sublistView(bytes) {
    header = _readHeader();
  }

  final Uint8List bytes;
  final ByteData _view;

  late final BtsnoopFile header;

  static const int _fileHeaderLength = 16;
  static const int _recordHeaderLength = 24;

  BtsnoopFile _readHeader() {
    if (bytes.length < _fileHeaderLength) {
      throw BtsnoopFormatException(
        'file is too short to contain a btsnoop header '
        '(${bytes.length} bytes, need at least $_fileHeaderLength)',
      );
    }
    for (var i = 0; i < kBtsnoopMagic.length; i++) {
      if (bytes[i] != kBtsnoopMagic[i]) {
        throw BtsnoopFormatException(
          'not a btsnoop file: identification pattern is missing. '
          'If this came from a bugreport, check you extracted '
          'FS/data/misc/bluetooth/logs/btsnoop_hci.log and not the zip itself',
          offset: i,
        );
      }
    }

    final version = _view.getUint32(8);
    final datalink = _view.getUint32(12);

    if (version != 1) {
      throw BtsnoopFormatException('unsupported btsnoop version $version');
    }
    if (datalink != kDatalinkH4) {
      throw BtsnoopFormatException(
        'unsupported datalink type $datalink '
        '(${_datalinkName(datalink)}); this reader handles HCI UART (H4, '
        '$kDatalinkH4), which is what Android writes',
      );
    }

    return BtsnoopFile(version: version, datalinkType: datalink);
  }

  /// Reads every record in order.
  ///
  /// Lazy, because a capture of a watch-face transfer can run to hundreds of
  /// megabytes and materialising it all at once would be wasteful.
  Iterable<BtsnoopRecord> records() sync* {
    var offset = _fileHeaderLength;
    while (offset < bytes.length) {
      if (offset + _recordHeaderLength > bytes.length) {
        throw BtsnoopFormatException(
          'truncated record header: ${bytes.length - offset} bytes left, '
          'need $_recordHeaderLength',
          offset: offset,
        );
      }

      final originalLength = _view.getUint32(offset);
      final includedLength = _view.getUint32(offset + 4);
      final flags = _view.getUint32(offset + 8);
      final drops = _view.getUint32(offset + 12);
      final rawTimestamp = _view.getInt64(offset + 16);

      final dataStart = offset + _recordHeaderLength;
      final dataEnd = dataStart + includedLength;
      if (dataEnd > bytes.length) {
        throw BtsnoopFormatException(
          'record claims $includedLength bytes but only '
          '${bytes.length - dataStart} remain',
          offset: offset,
        );
      }
      if (includedLength > originalLength) {
        throw BtsnoopFormatException(
          'record included length ($includedLength) exceeds original '
          'length ($originalLength)',
          offset: offset,
        );
      }

      yield BtsnoopRecord(
        originalLength: originalLength,
        includedLength: includedLength,
        flags: flags,
        cumulativeDrops: drops,
        timestamp: timestampFromBtsnoop(rawTimestamp),
        data: Uint8List.sublistView(bytes, dataStart, dataEnd),
      );

      offset = dataEnd;
    }
  }

  static String _datalinkName(int datalink) => switch (datalink) {
        kDatalinkH1 => 'HCI unencapsulated',
        kDatalinkH4 => 'HCI UART H4',
        kDatalinkBscp => 'HCI BSCP',
        kDatalinkH5 => 'HCI three-wire H5',
        _ => 'unknown',
      };
}

/// Converts a raw btsnoop timestamp to UTC wall-clock time.
DateTime timestampFromBtsnoop(int rawMicroseconds) =>
    DateTime.fromMicrosecondsSinceEpoch(
      rawMicroseconds - kBtsnoopEpochDeltaUs,
      isUtc: true,
    );

/// Inverse of [timestampFromBtsnoop]. Used to build fixtures.
int btsnoopTimestampFrom(DateTime time) =>
    time.toUtc().microsecondsSinceEpoch + kBtsnoopEpochDeltaUs;

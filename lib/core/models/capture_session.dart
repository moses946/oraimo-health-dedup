/// A named experiment.
///
/// Sessions are how experiments become reproducible (rule 8): a session records
/// what was done, against which device, when, and every packet that resulted.
library;

/// Where a session's packets came from.
///
/// This distinction matters more than it looks. Packets we generated ourselves
/// and packets sniffed from the official Oraimo Health app are both evidence,
/// but they are evidence of different things, and a hypothesis built on one
/// must not silently be credited to the other.
enum CaptureSource {
  /// Recorded by this app while it was driving the BLE connection.
  live('live', 'Live (this app)'),

  /// Imported from an Android Bluetooth HCI snoop log, which records traffic
  /// from every app on the phone — including Oraimo Health.
  btsnoopImport('btsnoop_import', 'Imported HCI snoop log');

  const CaptureSource(this.wireName, this.label);

  final String wireName;
  final String label;

  static CaptureSource fromWire(String wire) => values.firstWhere(
        (s) => s.wireName == wire,
        orElse: () => throw FormatException('unknown capture source', wire),
      );
}

class CaptureSession {
  const CaptureSession({
    required this.id,
    required this.name,
    required this.source,
    required this.startedAt,
    this.endedAt,
    this.deviceAddress,
    this.deviceName,
    this.notes,
    this.sourceFileName,
    this.packetCount = 0,
  });

  final String id;

  /// Operator-chosen name: `connection-test`, `watchface-A`, `change-time`.
  final String name;

  final CaptureSource source;
  final DateTime startedAt;

  /// Null while recording is still in progress.
  final DateTime? endedAt;

  final String? deviceAddress;
  final String? deviceName;

  /// Free text. The place to record what was physically done and when —
  /// "opened Oraimo Health, tapped Face B, waited for the progress bar".
  /// Without this an exported capture is much harder to interpret later.
  final String? notes;

  /// Original file name for an imported capture, kept for provenance.
  final String? sourceFileName;

  /// Denormalised count, maintained by the repository for list rendering.
  final int packetCount;

  bool get isRecording => endedAt == null;

  Duration? get duration => endedAt?.difference(startedAt);

  CaptureSession copyWith({
    String? name,
    DateTime? endedAt,
    String? deviceAddress,
    String? deviceName,
    String? notes,
    int? packetCount,
  }) =>
      CaptureSession(
        id: id,
        name: name ?? this.name,
        source: source,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        deviceAddress: deviceAddress ?? this.deviceAddress,
        deviceName: deviceName ?? this.deviceName,
        notes: notes ?? this.notes,
        sourceFileName: sourceFileName,
        packetCount: packetCount ?? this.packetCount,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'source': source.wireName,
        'device': {
          'name': deviceName,
          'address': deviceAddress,
        },
        'startedAt': startedAt.toUtc().toIso8601String(),
        'endedAt': endedAt?.toUtc().toIso8601String(),
        'notes': notes,
        'sourceFileName': sourceFileName,
        'packetCount': packetCount,
      };

  factory CaptureSession.fromJson(Map<String, dynamic> json) {
    final device = json['device'] as Map<String, dynamic>?;
    return CaptureSession(
      id: json['id'] as String,
      name: json['name'] as String,
      source: CaptureSource.fromWire(json['source'] as String),
      startedAt: DateTime.parse(json['startedAt'] as String),
      endedAt: json['endedAt'] == null
          ? null
          : DateTime.parse(json['endedAt'] as String),
      deviceName: device?['name'] as String?,
      deviceAddress: device?['address'] as String?,
      notes: json['notes'] as String?,
      sourceFileName: json['sourceFileName'] as String?,
      packetCount: json['packetCount'] as int? ?? 0,
    );
  }
}

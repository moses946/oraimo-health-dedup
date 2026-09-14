/// The research ledger.
///
/// The point of these two types is to keep guesses from turning into facts.
/// An observation is something we saw. A hypothesis is something we think it
/// means. Neither is protocol implementation, and both must cite the packets
/// they rest on (rule 8).
library;

/// How much weight a claim carries. Deliberately coarse — the evidence is what
/// matters, not a spurious percentage.
enum Confidence {
  low('low', 'Low'),
  medium('medium', 'Medium'),
  high('high', 'High');

  const Confidence(this.wireName, this.label);

  final String wireName;
  final String label;

  static Confidence fromWire(String wire) => values.firstWhere(
        (c) => c.wireName == wire,
        orElse: () => throw FormatException('unknown confidence', wire),
      );
}

/// Lifecycle of a hypothesis.
enum HypothesisStatus {
  /// Stated, not yet tested.
  unknown('UNKNOWN'),

  /// An experiment is underway that would confirm or refute it.
  testing('TESTING'),

  /// Evidence supports it. Note: supported, never "proven" — this is a
  /// black-box investigation of someone else's firmware.
  supported('SUPPORTED'),

  /// Evidence contradicts it. Kept, not deleted: knowing what the protocol is
  /// *not* is worth as much as knowing what it is.
  disproven('DISPROVEN');

  const HypothesisStatus(this.wireName);

  final String wireName;

  String get label => wireName;

  static HypothesisStatus fromWire(String wire) => values.firstWhere(
        (s) => s.wireName == wire,
        orElse: () => throw FormatException('unknown hypothesis status', wire),
      );
}

/// Something observed in a capture.
class ProtocolObservation {
  const ProtocolObservation({
    required this.id,
    required this.observation,
    required this.createdAt,
    this.captureSessionId,
    this.characteristicUuid,
    this.evidence = '',
    this.evidencePacketIds = const [],
    this.confidence = Confidence.low,
  });

  final String id;

  /// The capture this was seen in. Null only for observations entered by hand.
  final String? captureSessionId;

  final String? characteristicUuid;

  /// What was seen, phrased descriptively: "every write to this
  /// characteristic begins with the byte AA".
  final String observation;

  /// Free-text supporting detail: packet ranges, byte offsets, counts.
  final String evidence;

  /// Row ids of the packets that back this up. The traceable link between a
  /// claim and the bytes it came from.
  final List<int> evidencePacketIds;

  final Confidence confidence;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'captureSessionId': captureSessionId,
        'characteristicUuid': characteristicUuid,
        'observation': observation,
        'evidence': evidence,
        'evidencePacketIds': evidencePacketIds,
        'confidence': confidence.wireName,
        'createdAt': createdAt.toUtc().toIso8601String(),
      };

  factory ProtocolObservation.fromJson(Map<String, dynamic> json) =>
      ProtocolObservation(
        id: json['id'] as String,
        captureSessionId: json['captureSessionId'] as String?,
        characteristicUuid: json['characteristicUuid'] as String?,
        observation: json['observation'] as String,
        evidence: json['evidence'] as String? ?? '',
        evidencePacketIds:
            (json['evidencePacketIds'] as List?)?.cast<int>() ?? const [],
        confidence: json['confidence'] == null
            ? Confidence.low
            : Confidence.fromWire(json['confidence'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );

  ProtocolObservation copyWith({
    String? observation,
    String? evidence,
    List<int>? evidencePacketIds,
    Confidence? confidence,
    String? characteristicUuid,
  }) =>
      ProtocolObservation(
        id: id,
        captureSessionId: captureSessionId,
        characteristicUuid: characteristicUuid ?? this.characteristicUuid,
        observation: observation ?? this.observation,
        evidence: evidence ?? this.evidence,
        evidencePacketIds: evidencePacketIds ?? this.evidencePacketIds,
        confidence: confidence ?? this.confidence,
        createdAt: createdAt,
      );
}

/// A proposed explanation, and its current standing.
class ProtocolHypothesis {
  const ProtocolHypothesis({
    required this.id,
    required this.name,
    required this.description,
    required this.createdAt,
    required this.updatedAt,
    this.evidence = '',
    this.observationIds = const [],
    this.confidence = Confidence.low,
    this.status = HypothesisStatus.unknown,
  });

  final String id;

  /// Short name: "Byte 0 is a start-of-frame marker".
  final String name;

  /// What is being claimed, and what would refute it. Stating the refutation
  /// condition is what makes it a hypothesis rather than an assertion.
  final String description;

  final String evidence;

  /// Observations this rests on.
  final List<String> observationIds;

  final Confidence confidence;
  final HypothesisStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'evidence': evidence,
        'observationIds': observationIds,
        'confidence': confidence.wireName,
        'status': status.wireName,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };

  factory ProtocolHypothesis.fromJson(Map<String, dynamic> json) =>
      ProtocolHypothesis(
        id: json['id'] as String,
        name: json['name'] as String,
        description: json['description'] as String? ?? '',
        evidence: json['evidence'] as String? ?? '',
        observationIds:
            (json['observationIds'] as List?)?.cast<String>() ?? const [],
        confidence: json['confidence'] == null
            ? Confidence.low
            : Confidence.fromWire(json['confidence'] as String),
        status: json['status'] == null
            ? HypothesisStatus.unknown
            : HypothesisStatus.fromWire(json['status'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  ProtocolHypothesis copyWith({
    String? name,
    String? description,
    String? evidence,
    List<String>? observationIds,
    Confidence? confidence,
    HypothesisStatus? status,
    DateTime? updatedAt,
  }) =>
      ProtocolHypothesis(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        evidence: evidence ?? this.evidence,
        observationIds: observationIds ?? this.observationIds,
        confidence: confidence ?? this.confidence,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: updatedAt ?? DateTime.now().toUtc(),
      );
}

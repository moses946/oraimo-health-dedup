/// A device seen while scanning.
///
/// Advertisement contents are stored as hex exactly as they arrived: the
/// manufacturer-specific data of a proprietary wearable frequently encodes
/// model and state information, and we have no business reinterpreting it yet.
library;

class BleDeviceRecord {
  const BleDeviceRecord({
    required this.address,
    required this.name,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.lastRssi,
    this.advertisedServiceUuids = const [],
    this.manufacturerDataHex = const {},
    this.serviceDataHex = const {},
    this.connectable = true,
    this.txPowerLevel,
    this.isFavourite = false,
  });

  /// Platform device identifier. On Android this is the MAC address; on iOS it
  /// is an opaque per-app UUID, which is why it is never treated as globally
  /// meaningful.
  final String address;

  /// Advertised local name. Empty when the device advertises none — common,
  /// and not a reason to hide the device from the scan list.
  final String name;

  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final int lastRssi;

  /// Canonical service UUIDs from the advertisement.
  final List<String> advertisedServiceUuids;

  /// Company identifier → payload hex, verbatim.
  final Map<int, String> manufacturerDataHex;

  /// Service UUID → payload hex, verbatim.
  final Map<String, String> serviceDataHex;

  final bool connectable;
  final int? txPowerLevel;

  /// Operator-marked device of interest. This is how the Watch 6R gets
  /// singled out: by the operator confirming it, not by a hard-coded name or
  /// UUID match (rule 1).
  final bool isFavourite;

  String get displayName => name.isEmpty ? '(no name)' : name;

  BleDeviceRecord copyWith({
    String? name,
    DateTime? lastSeenAt,
    int? lastRssi,
    List<String>? advertisedServiceUuids,
    Map<int, String>? manufacturerDataHex,
    Map<String, String>? serviceDataHex,
    bool? connectable,
    int? txPowerLevel,
    bool? isFavourite,
  }) =>
      BleDeviceRecord(
        address: address,
        name: name ?? this.name,
        firstSeenAt: firstSeenAt,
        lastSeenAt: lastSeenAt ?? this.lastSeenAt,
        lastRssi: lastRssi ?? this.lastRssi,
        advertisedServiceUuids:
            advertisedServiceUuids ?? this.advertisedServiceUuids,
        manufacturerDataHex: manufacturerDataHex ?? this.manufacturerDataHex,
        serviceDataHex: serviceDataHex ?? this.serviceDataHex,
        connectable: connectable ?? this.connectable,
        txPowerLevel: txPowerLevel ?? this.txPowerLevel,
        isFavourite: isFavourite ?? this.isFavourite,
      );

  Map<String, dynamic> toJson() => {
        'address': address,
        'name': name,
        'firstSeenAt': firstSeenAt.toUtc().toIso8601String(),
        'lastSeenAt': lastSeenAt.toUtc().toIso8601String(),
        'lastRssi': lastRssi,
        'advertisedServiceUuids': advertisedServiceUuids,
        'manufacturerData': manufacturerDataHex
            .map((k, v) => MapEntry(k.toString(), v)),
        'serviceData': serviceDataHex,
        'connectable': connectable,
        'txPowerLevel': txPowerLevel,
        'isFavourite': isFavourite,
      };

  factory BleDeviceRecord.fromJson(Map<String, dynamic> json) =>
      BleDeviceRecord(
        address: json['address'] as String,
        name: json['name'] as String? ?? '',
        firstSeenAt: DateTime.parse(json['firstSeenAt'] as String),
        lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
        lastRssi: json['lastRssi'] as int? ?? 0,
        advertisedServiceUuids:
            (json['advertisedServiceUuids'] as List?)?.cast<String>() ??
                const [],
        manufacturerDataHex:
            (json['manufacturerData'] as Map?)?.map(
                  (k, v) => MapEntry(int.parse(k as String), v as String),
                ) ??
                const {},
        serviceDataHex:
            (json['serviceData'] as Map?)?.cast<String, String>() ?? const {},
        connectable: json['connectable'] as bool? ?? true,
        txPowerLevel: json['txPowerLevel'] as int?,
        isFavourite: json['isFavourite'] as bool? ?? false,
      );
}

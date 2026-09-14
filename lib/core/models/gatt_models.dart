/// GATT structure as discovered on a device.
///
/// These describe the shape of the attribute database and nothing about its
/// meaning. A characteristic's purpose is never inferred here (rule 3).
library;

/// The properties bitfield, as declared by the characteristic itself.
class GattProperties {
  const GattProperties({
    this.broadcast = false,
    this.read = false,
    this.writeWithoutResponse = false,
    this.write = false,
    this.notify = false,
    this.indicate = false,
    this.authenticatedSignedWrites = false,
    this.extendedProperties = false,
  });

  final bool broadcast;
  final bool read;
  final bool writeWithoutResponse;
  final bool write;
  final bool notify;
  final bool indicate;
  final bool authenticatedSignedWrites;
  final bool extendedProperties;

  bool get isWritable => write || writeWithoutResponse;
  bool get isSubscribable => notify || indicate;

  /// Short labels for the UI, in spec order.
  List<String> get labels => [
        if (broadcast) 'BROADCAST',
        if (read) 'READ',
        if (writeWithoutResponse) 'WRITE_NR',
        if (write) 'WRITE',
        if (notify) 'NOTIFY',
        if (indicate) 'INDICATE',
        if (authenticatedSignedWrites) 'SIGNED_WRITE',
        if (extendedProperties) 'EXTENDED',
      ];

  Map<String, dynamic> toJson() => {
        'broadcast': broadcast,
        'read': read,
        'writeWithoutResponse': writeWithoutResponse,
        'write': write,
        'notify': notify,
        'indicate': indicate,
        'authenticatedSignedWrites': authenticatedSignedWrites,
        'extendedProperties': extendedProperties,
      };
}

class GattDescriptor {
  const GattDescriptor({required this.uuid, this.handle});

  final String uuid;
  final int? handle;

  Map<String, dynamic> toJson() => {'uuid': uuid, 'handle': handle};
}

class GattCharacteristic {
  const GattCharacteristic({
    required this.uuid,
    required this.serviceUuid,
    required this.properties,
    this.handle,
    this.descriptors = const [],
  });

  final String uuid;
  final String serviceUuid;
  final GattProperties properties;
  final int? handle;
  final List<GattDescriptor> descriptors;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'handle': handle,
        'properties': properties.toJson(),
        'propertyLabels': properties.labels,
        'descriptors': descriptors.map((d) => d.toJson()).toList(),
      };
}

class GattService {
  const GattService({
    required this.uuid,
    required this.characteristics,
    this.isPrimary = true,
    this.includedServiceUuids = const [],
  });

  final String uuid;
  final List<GattCharacteristic> characteristics;
  final bool isPrimary;
  final List<String> includedServiceUuids;

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'isPrimary': isPrimary,
        'includedServices': includedServiceUuids,
        'characteristics': characteristics.map((c) => c.toJson()).toList(),
      };
}

enum VehicleType { scooter, heavy }

enum SpaceType { paidMotorcycle, freeMotorcycle, heavyOnly, car, offStreet }

enum TrustStatus { pending, confirmed, hidden }

enum FacilityType { multiStorey, underground, surface, roadside }

enum ParkingAccess {
  scooterOnly,
  scooterHeavy,
  heavyCar,
  noMotorcycle,
  heavyOnly,
}

extension FacilityLabel on FacilityType {
  String get label => switch (this) {
    FacilityType.multiStorey => '立體停車場',
    FacilityType.underground => '地下停車場',
    FacilityType.surface => '路外平面停車場',
    FacilityType.roadside => '路邊停車格',
  };
}

extension ParkingAccessLabel on ParkingAccess {
  String get label => switch (this) {
    ParkingAccess.scooterOnly => '普機專用',
    ParkingAccess.scooterHeavy => '普大共用',
    ParkingAccess.heavyCar => '大汽共用',
    ParkingAccess.noMotorcycle => '機車不可停',
    ParkingAccess.heavyOnly => '大重專用',
  };

  String get description => switch (this) {
    ParkingAccess.scooterOnly => '普通機車專用',
    ParkingAccess.scooterHeavy => '普通機車與大型重機共用',
    ParkingAccess.heavyCar => '大型重機與汽車共用',
    ParkingAccess.noMotorcycle => '普通機車與大型重機皆不可停',
    ParkingAccess.heavyOnly => '大型重機專用',
  };
}

T? _optionalEnum<T extends Enum>(List<T> values, Object? name) =>
    values.where((value) => value.name == name).firstOrNull;

/// A facility may have different access rules and fees in each area.
/// These describe the source's information, not a legal eligibility decision.
class ParkingZone {
  const ParkingZone({
    required this.name,
    this.access,
    this.feeNote = '',
    this.guide = '',
  });

  final String name, feeNote, guide;
  final ParkingAccess? access;

  factory ParkingZone.fromJson(Map<String, dynamic> json) => ParkingZone(
    name: json['name'] as String? ?? '',
    access: _optionalEnum(ParkingAccess.values, json['access']),
    feeNote: json['fee_note'] as String? ?? '',
    guide: json['guide'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    if (access != null) 'access': access!.name,
    if (feeNote.isNotEmpty) 'fee_note': feeNote,
    if (guide.isNotEmpty) 'guide': guide,
  };
}

extension VehicleLabel on VehicleType {
  String get label => this == VehicleType.scooter ? '普通機車' : '大型重機';
}

extension SpaceLabel on SpaceType {
  String get label => switch (this) {
    SpaceType.paidMotorcycle => '路邊收費機車格',
    SpaceType.freeMotorcycle => '免費機車格',
    SpaceType.heavyOnly => '重機專用格',
    SpaceType.car => '汽車格',
    SpaceType.offStreet => '路外停車場',
  };
}

class ParkingSpot {
  const ParkingSpot({
    required this.id,
    required this.name,
    required this.lat,
    required this.lng,
    required this.city,
    required this.spaceType,
    this.source = 'community',
    this.feeNote = '請依現場公告',
    this.scooterTotal,
    this.available,
    this.heavyAllowed,
    this.scooterAllowed,
    this.status = TrustStatus.pending,
    this.updatedAt,
    this.lastConfirmedAt,
    this.note = '',
    this.district = '',
    this.sourceUrl = '',
    this.sourceName = '',
    this.licenseNote = '',
    this.facilityType,
    this.access,
    this.address = '',
    this.roadSegment = '',
    this.entranceNote = '',
    this.parkingGuide = '',
    this.specialRules = '',
    this.photoUrls = const [],
    this.zones = const [],
    this.availabilityUpdatedAt,
  });
  final String id, name, city, source, feeNote, note, district, sourceUrl;
  final String sourceName, licenseNote;
  final double lat, lng;
  final SpaceType spaceType;
  final int? scooterTotal, available;
  final bool? heavyAllowed, scooterAllowed;
  final TrustStatus status;
  final DateTime? updatedAt, lastConfirmedAt;
  final FacilityType? facilityType;
  final ParkingAccess? access;
  final String address, roadSegment, entranceNote, parkingGuide, specialRules;
  final List<String> photoUrls;
  final List<ParkingZone> zones;
  final DateTime? availabilityUpdatedAt;

  bool get isFacility => facilityType != null
      ? facilityType != FacilityType.roadside
      : spaceType == SpaceType.offStreet;
  bool get stale =>
      lastConfirmedAt != null &&
      DateTime.now().difference(lastConfirmedAt!).inDays > 180;
  factory ParkingSpot.fromJson(Map<String, dynamic> j) => ParkingSpot(
    id: j['id'] as String,
    name: j['name'] as String,
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    city: j['city'] as String,
    source: j['source'] as String? ?? 'community',
    spaceType: SpaceType.values.byName(j['space_type'] as String),
    feeNote: j['fee_note'] as String? ?? '請依現場公告',
    scooterTotal: j['scooter_total'] as int?,
    available: j['available'] as int?,
    heavyAllowed: j['heavy_allowed'] as bool?,
    scooterAllowed: j['scooter_allowed'] as bool?,
    status: TrustStatus.values.byName(j['status'] as String? ?? 'pending'),
    updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
    lastConfirmedAt: DateTime.tryParse(j['last_confirmed_at'] as String? ?? ''),
    note: j['note'] as String? ?? '',
    district: j['district'] as String? ?? '',
    sourceUrl: j['source_url'] as String? ?? '',
    sourceName: j['source_name'] as String? ?? '',
    licenseNote: j['license_note'] as String? ?? '',
    facilityType: _optionalEnum(FacilityType.values, j['facility_type']),
    access: _optionalEnum(ParkingAccess.values, j['parking_access']),
    address: j['address'] as String? ?? '',
    roadSegment: j['road_segment'] as String? ?? '',
    entranceNote: j['entrance_note'] as String? ?? '',
    parkingGuide: j['parking_guide'] as String? ?? '',
    specialRules: j['special_rules'] as String? ?? '',
    photoUrls: (j['photo_urls'] as List<dynamic>? ?? []).cast<String>(),
    zones: (j['parking_zones'] as List<dynamic>? ?? [])
        .map((zone) => ParkingZone.fromJson(zone as Map<String, dynamic>))
        .toList(),
    availabilityUpdatedAt: DateTime.tryParse(
      j['availability_updated_at'] as String? ?? '',
    ),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'lat': lat,
    'lng': lng,
    'city': city,
    'source': source,
    'space_type': spaceType.name,
    'fee_note': feeNote,
    'scooter_total': scooterTotal,
    'available': available,
    'heavy_allowed': heavyAllowed,
    'scooter_allowed': scooterAllowed,
    'status': status.name,
    'updated_at': updatedAt?.toIso8601String(),
    'last_confirmed_at': lastConfirmedAt?.toIso8601String(),
    'note': note,
    'district': district,
    'source_url': sourceUrl,
    'source_name': sourceName,
    'license_note': licenseNote,
    if (facilityType != null) 'facility_type': facilityType!.name,
    if (access != null) 'parking_access': access!.name,
    if (address.isNotEmpty) 'address': address,
    if (roadSegment.isNotEmpty) 'road_segment': roadSegment,
    if (entranceNote.isNotEmpty) 'entrance_note': entranceNote,
    if (parkingGuide.isNotEmpty) 'parking_guide': parkingGuide,
    if (specialRules.isNotEmpty) 'special_rules': specialRules,
    if (photoUrls.isNotEmpty) 'photo_urls': photoUrls,
    if (zones.isNotEmpty)
      'parking_zones': zones.map((zone) => zone.toJson()).toList(),
    if (availabilityUpdatedAt != null)
      'availability_updated_at': availabilityUpdatedAt!.toIso8601String(),
  };
}

class CityRule {
  const CityRule({
    required this.city,
    required this.vehicle,
    required this.allowedSpaceTypes,
    required this.feeNote,
    required this.exceptions,
    required this.sourceUrl,
    required this.version,
    required this.effectiveDate,
    this.canUseTwoSpaces = false,
    this.conditionalSpaceTypes = const [],
    this.districts = const [],
  });
  final String city, feeNote, exceptions, sourceUrl;
  final VehicleType vehicle;
  final List<SpaceType> allowedSpaceTypes, conditionalSpaceTypes;
  final List<String> districts;
  final int version;
  final DateTime effectiveDate;
  final bool canUseTwoSpaces;
  factory CityRule.fromJson(Map<String, dynamic> j) => CityRule(
    city: j['city'] as String,
    vehicle: VehicleType.values.byName(j['vehicle'] as String),
    allowedSpaceTypes: (j['allowed_space_types'] as List<dynamic>)
        .map((e) => SpaceType.values.byName(e as String))
        .toList(),
    conditionalSpaceTypes:
        (j['conditional_space_types'] as List<dynamic>? ?? [])
            .map((e) => SpaceType.values.byName(e as String))
            .toList(),
    districts: (j['districts'] as List<dynamic>? ?? []).cast<String>(),
    feeNote: j['fee_note'] as String,
    exceptions: j['exceptions'] as String,
    sourceUrl: j['source_url'] as String,
    version: j['version'] as int,
    effectiveDate: DateTime.parse(j['effective_date'] as String),
    canUseTwoSpaces: j['can_use_two_spaces'] as bool? ?? false,
  );
}

class ParkedRecord {
  const ParkedRecord({
    required this.lat,
    required this.lng,
    required this.at,
    this.note = '',
    this.floor = '',
    this.remindAt,
  });
  final double lat, lng;
  final DateTime at;
  final DateTime? remindAt;
  final String note, floor;
  Map<String, dynamic> toJson() => {
    'lat': lat,
    'lng': lng,
    'at': at.toIso8601String(),
    'note': note,
    'floor': floor,
    'remind_at': remindAt?.toIso8601String(),
  };
  factory ParkedRecord.fromJson(Map<String, dynamic> j) => ParkedRecord(
    lat: (j['lat'] as num).toDouble(),
    lng: (j['lng'] as num).toDouble(),
    at: DateTime.parse(j['at'] as String),
    note: j['note'] as String? ?? '',
    floor: j['floor'] as String? ?? '',
    remindAt: DateTime.tryParse(j['remind_at'] as String? ?? ''),
  );
}

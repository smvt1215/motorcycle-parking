import 'closure.dart';
import 'fee.dart';
import 'parking_condition.dart';
import 'zone_entries.dart';

enum VehicleType { scooter, heavy }

/// Space kinds a rider meets, from Taipei's official street-space codes
/// (pktype) and the national special-bay rules. Added kinds sit after the
/// original five so stored names never shift.
enum SpaceType {
  paidMotorcycle,
  freeMotorcycle,
  heavyOnly,
  car,
  offStreet,

  /// 身心障礙專用機車格 (pktype 04, 18): conditional, for permit holders.
  disabledMotorcycle,

  /// 限時停車機車格 (pktype 20): a motorcycle bay with a time limit.
  timedMotorcycle,

  /// 汽機車彈性共用 (pktype 22): cars and motorcycles by posted hours.
  flexShared,

  /// 電動機車停車／充換電格: electric motorcycles only.
  evMotorcycle,
}

/// How a rule limits its conditional space types; the map picks the marker
/// icon from it.
/// - [signage]: only spaces marked for the vehicle on site.
/// - [unverified]: the rule itself is not verified yet, so nothing it opens
///   counts as parkable.
enum RuleRestriction {
  signage('signage'),
  unverified('unverified'),

  /// Set by the space itself, never by a rule: posted time limits.
  timeLimited('time_limited'),

  /// Set by the space itself: electric motorcycles only.
  evOnly('ev_only');

  const RuleRestriction(this.key);
  final String key;
  String get label => switch (this) {
    signage => '限標示車格',
    unverified => '規則未確認',
    timeLimited => '限時段',
    evOnly => '限電動機車',
  };
  static RuleRestriction? parse(Object? value) =>
      values.where((r) => r.key == value).firstOrNull;
}

enum TrustStatus { pending, confirmed, hidden }

/// A vehicle's eligibility as it is written (#201): 可停、不可停 or 官方未標示
/// (the official data, for a lot its operator's notice too, does not say).
/// Stored as the `x_allowed` flag and `x_not_stated`; a spot with neither is
/// old data's 待確認, which no write leaves behind.
enum Eligible {
  allowed,
  notAllowed,
  notStated;

  /// What a stored flag pair says; null is 待確認.
  static Eligible? of(bool? allowed, {bool notStated = false}) => notStated
      ? Eligible.notStated
      : switch (allowed) {
          true => Eligible.allowed,
          false => Eligible.notAllowed,
          null => null,
        };

  /// The `x_allowed` flag it is stored as.
  bool? get flag => switch (this) {
    allowed => true,
    notAllowed => false,
    notStated => null,
  };

  String get label => switch (this) {
    allowed => '可停',
    notAllowed => '不可停',
    notStated => '官方未標示',
  };

  /// [vehicle]'s keys (`scooter` or `heavy`) as a write sends them: a
  /// boolean, or a null flag with `x_not_stated`; the table clears
  /// `x_not_stated` whenever a boolean is written.
  Map<String, Object?> payload(String vehicle) => {
    '${vehicle}_allowed': flag,
    if (this == notStated) '${vehicle}_not_stated': true,
  };
}

/// In the order the contract stores a set of them
/// (`placement.facility_types`): lot types first, 路邊 last.
enum FacilityType { multiStorey, underground, surface, roadside }

/// The facility types in [json] (a list of names), each once, in
/// [FacilityType] order; names this build does not know are left out.
List<FacilityType> facilityTypesOf(Object? json) => json is List
    ? [
        for (final t in FacilityType.values)
          if (json.contains(t.name)) t,
      ]
    : const [];

enum ParkingAccess {
  scooterOnly,
  scooterHeavy,
  heavyCar,
  noMotorcycle,
  heavyOnly,
}

/// Several facility types in one name (decision 58): the lot types share
/// one 停車場 (「地下、平面停車場」); one type reads as its own label.
String facilityTypesLabel(List<FacilityType> types) {
  if (types.length == 1) return types.single.label;
  final lots = [
    for (final t in types)
      if (t != FacilityType.roadside) t.shortLabel,
  ];
  return [
    if (lots.isNotEmpty) '${lots.join('、')}停車場',
    if (types.contains(FacilityType.roadside)) FacilityType.roadside.label,
  ].join('、');
}

extension FacilityLabel on FacilityType {
  /// The type alone, as a choice or inside [facilityTypesLabel].
  String get shortLabel => switch (this) {
    FacilityType.multiStorey => '立體',
    FacilityType.underground => '地下',
    FacilityType.surface => '平面',
    FacilityType.roadside => '路邊',
  };

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

String _feeNoteText(Object? value) => value is String ? value : '';

/// A parking location may have different access rules and fees in each area.
/// These describe the source's information, not a legal eligibility decision.
class ParkingZone {
  const ParkingZone({
    this.id,
    required this.name,
    this.access,
    this.feeNote = '',
    this.guide = '',
    this.scooterFeeNote = '',
    this.heavyFeeNote = '',
    this.carFeeNote = '',
    this.fee,
    this.area,
    this.condition,
    this.evidenceUrl = '',
  });

  /// The zone's stable id in its spot (#188); null until the server gives
  /// it one (a zone a form has just added). Writers send it back, so that a
  /// renamed zone stays the same zone.
  final String? id;

  final String name, feeNote, guide;

  /// A link to a photo or notice of the zone (https), or empty.
  final String evidenceUrl;

  /// Rates belong to vehicles independently of whether their bays are shared.
  /// Empty means unprovided; a generic fee note is never copied into a rate.
  final String scooterFeeNote, heavyFeeNote, carFeeNote;
  final ParkingAccess? access;
  final Fee? fee;

  /// The zone's area; null is unconfirmed.
  final ZoneArea? area;

  /// The zone's parking condition (§1.2), or null — unconfirmed — when the
  /// zone has none or it breaks the contract. [access] stays for builds
  /// that cannot read it.
  final ParkingCondition? condition;

  /// Whether builds that read only [access] read this zone as it is.
  bool get legacySafe => legacySafeStoredZone(condition, access);

  /// Structured rates supersede the legacy vehicle strings as one record.
  /// A missing vehicle remains unconfirmed, even if an old string exists.
  String get scooterFeeText =>
      fee == null ? scooterFeeNote : fee!.riderText('scooter') ?? '';
  String get heavyFeeText =>
      fee == null ? heavyFeeNote : fee!.riderText('heavy') ?? '';

  /// The car's structured rate when the zone's fee has one; otherwise the
  /// legacy text, which predates `fee.car`.
  String get carFeeText => fee?.textOf('car') ?? carFeeNote;
  bool get hasVehicleFees =>
      fee != null ||
      [
        scooterFeeNote,
        heavyFeeNote,
        carFeeNote,
      ].any((v) => v.trim().isNotEmpty);

  factory ParkingZone.fromJson(Map<String, dynamic> json) => ParkingZone(
    id: json['id'] is String ? json['id'] as String : null,
    name: json['name'] as String? ?? '',
    access: _optionalEnum(ParkingAccess.values, json['access']),
    feeNote: json['fee_note'] as String? ?? '',
    guide: json['guide'] as String? ?? '',
    scooterFeeNote: _feeNoteText(json['scooter_fee_note']),
    heavyFeeNote: _feeNoteText(json['heavy_fee_note']),
    carFeeNote: _feeNoteText(json['car_fee_note']),
    fee: json['fee'] is Map ? Fee.fromJson(json['fee']) : null,
    area: _optionalEnum(ZoneArea.values, json['area']),
    condition: ParkingCondition.fromJson(json['condition'], zone: true),
    evidenceUrl: validEntryUrl(json['evidence_url'])
        ? json['evidence_url'] as String
        : '',
  );

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'name': name,
    if (access != null) 'access': access!.name,
    if (area != null) 'area': area!.name,
    if (condition != null) 'condition': condition!.toJson(),
    if (feeNote.isNotEmpty) 'fee_note': feeNote,
    if (guide.isNotEmpty) 'guide': guide,
    if (scooterFeeNote.isNotEmpty) 'scooter_fee_note': scooterFeeNote,
    if (heavyFeeNote.isNotEmpty) 'heavy_fee_note': heavyFeeNote,
    if (carFeeNote.isNotEmpty) 'car_fee_note': carFeeNote,
    if (fee case final fee?) 'fee': fee.toJson(),
    if (evidenceUrl.isNotEmpty) 'evidence_url': evidenceUrl,
  };
}

/// One stretch of a street spot's bays (#188, design canvas S3b, S4): its
/// side, the range it covers, what is painted there and how many. Builds
/// before segments never read them; the spot's own condition still stands
/// for the whole spot there.
class ParkingSegment {
  const ParkingSegment({
    this.id,
    required this.name,
    this.side,
    this.range = '',
    this.condition,
    this.total,
    this.guide = '',
    this.evidenceUrl = '',
  });

  /// The segment's stable id in its spot; null until the server gives one.
  final String? id;
  final String name;
  final RoadSide? side;

  /// Where it runs, e.g. 建國北路口至松江路口; empty when not given.
  final String range;

  /// What is painted there; null is unconfirmed (or broke the contract).
  /// Never carries `allow`: the city's rules decide who may park.
  final ParkingCondition? condition;

  /// How many bays; null is unconfirmed.
  final int? total;
  final String guide, evidenceUrl;

  /// The bay kind painted there; null is unconfirmed.
  BayKind? get bayKind => bayKindOf(condition);

  factory ParkingSegment.fromJson(Map<String, dynamic> json) {
    final c = json['condition'];
    final total = json['total'];
    return ParkingSegment(
      id: json['id'] is String ? json['id'] as String : null,
      name: json['name'] as String? ?? '',
      side: _optionalEnum(RoadSide.values, json['side']),
      range: json['range'] is String ? json['range'] as String : '',
      condition: c is Map && c.containsKey('allow')
          ? null
          : ParkingCondition.fromJson(c, zone: true),
      total: total is num && total == total.truncate() && total >= 1
          ? total.toInt()
          : null,
      guide: json['guide'] is String ? json['guide'] as String : '',
      evidenceUrl: validEntryUrl(json['evidence_url'])
          ? json['evidence_url'] as String
          : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': ?id,
    'name': name,
    'side': ?side?.name,
    if (range.isNotEmpty) 'range': range,
    if (condition case final c?) 'condition': c.toJson(),
    'total': ?total,
    if (guide.isNotEmpty) 'guide': guide,
    if (evidenceUrl.isNotEmpty) 'evidence_url': evidenceUrl,
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
    SpaceType.disabledMotorcycle => '身障機車專用格',
    SpaceType.timedMotorcycle => '限時停車機車格',
    SpaceType.flexShared => '汽機車彈性共用格',
    SpaceType.evMotorcycle => '電動機車充換電格',
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
    this.fee,
    this.scooterTotal,
    this.available,
    this.heavyAllowed,
    this.scooterAllowed,
    this.scooterNotStated = false,
    this.heavyNotStated = false,
    this.status = TrustStatus.pending,
    this.updatedAt,
    this.lastConfirmedAt,
    this.createdAt,
    this.note = '',
    this.district = '',
    this.sourceUrl = '',
    this.sourceName = '',
    this.licenseNote = '',
    this.contributorName = '',
    this.contributorRole = '',
    this.facilityType,
    this.facilityTypes = const [],
    this.access,
    this.address = '',
    this.roadSegment = '',
    this.entranceNote = '',
    this.parkingGuide = '',
    this.specialRules = '',
    this.photoUrls = const [],
    this.zones = const [],
    this.segments = const [],
    this.availabilityUpdatedAt,
    this.scooterVerifiedAt,
    this.heavyVerifiedAt,
    this.condition,
    this.zonesComplete = false,
    this.closure,
  });
  final String id, name, city, source, feeNote, note, district, sourceUrl;
  final String sourceName, licenseNote;

  /// Public attribution only, supplied by the backend without contributor ids.
  /// The name is live data: [toJson] leaves it out so saved copies never
  /// keep it. The role describes who added the point; it never grants app
  /// permissions.
  final String contributorName, contributorRole;
  final Fee? fee;
  final double lat, lng;
  final SpaceType spaceType;
  final int? scooterTotal, available;
  final bool? heavyAllowed, scooterAllowed;

  /// 官方未標示 (#201): the official data (for a lot, its operator's notice
  /// too) does not say whether the vehicle may park; [scooterAllowed] or
  /// [heavyAllowed] is then null. Neither 可停 nor 不可停: it judges as
  /// unconfirmed. False with a null flag is old data's 待確認.
  final bool scooterNotStated, heavyNotStated;

  /// [vehicle]'s [scooterNotStated] or [heavyNotStated].
  bool notStated(VehicleType vehicle) =>
      vehicle == VehicleType.heavy ? heavyNotStated : scooterNotStated;
  final TrustStatus status;
  final DateTime? updatedAt, lastConfirmedAt;

  /// When the spot was added (a community spot's report or import); null
  /// for sources that do not send it.
  final DateTime? createdAt;

  /// The first of [facilityTypes], kept for builds and viewports that read
  /// one type; a lot type whenever any is (they are stored in the
  /// contract's order).
  final FacilityType? facilityType;

  /// Every type the spot is built as (decision 58), in [FacilityType]
  /// order; empty when the source sends only [facilityType]. Read
  /// [facilities] for both.
  final List<FacilityType> facilityTypes;

  /// The types the spot is built as: [facilityTypes], or the one
  /// [facilityType] older sources send.
  List<FacilityType> get facilities =>
      facilityTypes.isNotEmpty ? facilityTypes : [?facilityType];
  final ParkingAccess? access;
  final String address, roadSegment, entranceNote, parkingGuide, specialRules;
  final List<String> photoUrls;
  final List<ParkingZone> zones;

  /// A street spot's segments (#188), in the order stored; empty when it
  /// has none or the source predates them.
  final List<ParkingSegment> segments;
  final DateTime? availabilityUpdatedAt;

  /// When an administrator last set this community spot's access for each
  /// vehicle; null when none has, or a later rider-side change voided it.
  /// Only the backend records these, never a rider's report or vote.
  final DateTime? scooterVerifiedAt, heavyVerifiedAt;

  /// A street bay's parking condition (§1.2); null when the spot has none
  /// (read it through `conditionOf(spaceType)`) or it breaks the contract.
  /// Lots keep theirs in [zones].
  final ParkingCondition? condition;

  /// Whether [zones] cover the whole lot; only admins and imports set it.
  final bool zonesComplete;

  /// A temporary closure or works (#116), with the server's judgement of
  /// whether it still holds. Saved with favorites like the other fields
  /// (without the judgement, which [SpotClosure.stateOn] makes again by
  /// date), so a favorite opened later still shows it and lets it lapse.
  final SpotClosure? closure;

  /// Whether builds that cannot read conditions read this spot as it is
  /// (§1.3, `condition_legacy_safe_spot()` in SQL). When not, [toJson] gives
  /// them the conservative projection the viewports give (§5.2, §5.3).
  bool get isLegacySafe => isOffStreet(spaceType, facilityType)
      ? condition == null && zones.every((z) => z.legacySafe)
      : legacySafe(condition);

  /// [vehicle]'s admin verification time, see [scooterVerifiedAt].
  DateTime? verifiedAt(VehicleType vehicle) =>
      vehicle == VehicleType.heavy ? heavyVerifiedAt : scooterVerifiedAt;

  /// Points are either official (government data, including TDX spots kept in
  /// older favorites) or
  /// community (user reports and unverified imports).
  bool get isOfficial => source == 'official' || source == 'tdx';

  bool get isFacility => facilityType != null
      ? facilityType != FacilityType.roadside
      : spaceType == SpaceType.offStreet;
  bool get stale =>
      lastConfirmedAt != null &&
      DateTime.now().difference(lastConfirmedAt!).inDays > 180;

  /// [row] as a spot, or nothing when its space kind is newer than this
  /// build: one unknown row must not fail the whole map.
  static Iterable<ParkingSpot> known(Object? row) {
    final j = row as Map<String, dynamic>;
    if (_kind(j) == null) return const [];
    return [ParkingSpot.fromJson(j)];
  }

  /// A saved favorite as a spot. Favorites never keep the contributor's
  /// name: it follows the account and can be cleared, so a stored copy
  /// would go stale. Copies saved by earlier builds are ignored here too.
  static Iterable<ParkingSpot> favorite(Object? row) =>
      known({...row as Map<String, dynamic>}..remove('contributor_name'));

  /// A snapshot's exact kind (see [toJson]: `exact_v2`, then `exact`), else
  /// its `space_type`; null when this build knows none of them.
  static SpaceType? _kind(Map<String, dynamic> j) {
    final names = SpaceType.values.asNameMap();
    return names[(j['exact_v2'] as Map<String, dynamic>?)?['space_type']] ??
        names[(j['exact'] as Map<String, dynamic>?)?['space_type']] ??
        names[j['space_type']];
  }

  /// Kinds older builds lack. Their snapshots read there as a lot with no
  /// access flags and a pending status, which those builds always judge
  /// unverified, whatever the source: never parkable without the kind's
  /// limit (permit, electric only, posted hours).
  static const _newKinds = {
    SpaceType.disabledMotorcycle,
    SpaceType.timedMotorcycle,
    SpaceType.flexShared,
    SpaceType.evMotorcycle,
  };

  factory ParkingSpot.fromJson(Map<String, dynamic> raw) {
    // The exact fields override the conservative ones: `exact_v2` (a spot
    // older builds cannot read safely), then `exact` (a newer kind).
    final j = {
      ...raw,
      ...?raw['exact'] as Map<String, dynamic>?,
      ...?raw['exact_v2'] as Map<String, dynamic>?,
    };
    return ParkingSpot(
      id: j['id'] as String,
      name: j['name'] as String,
      lat: (j['lat'] as num).toDouble(),
      lng: (j['lng'] as num).toDouble(),
      city: j['city'] as String,
      source: j['source'] as String? ?? 'community',
      spaceType: _kind(j) ?? SpaceType.values.byName(j['space_type'] as String),
      feeNote: j['fee_note'] as String? ?? '請依現場公告',
      fee: structuredFee(j['fee']),
      scooterTotal: j['scooter_total'] as int?,
      available: j['available'] as int?,
      heavyAllowed: j['heavy_allowed'] as bool?,
      scooterAllowed: j['scooter_allowed'] as bool?,
      scooterNotStated: j['scooter_not_stated'] == true,
      heavyNotStated: j['heavy_not_stated'] == true,
      status: TrustStatus.values.byName(j['status'] as String? ?? 'pending'),
      updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
      lastConfirmedAt: DateTime.tryParse(
        j['last_confirmed_at'] as String? ?? '',
      ),
      createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
      note: j['note'] as String? ?? '',
      district: j['district'] as String? ?? '',
      sourceUrl: j['source_url'] as String? ?? '',
      sourceName: j['source_name'] as String? ?? '',
      licenseNote: j['license_note'] as String? ?? '',
      contributorName: j['contributor_name'] is String
          ? j['contributor_name'] as String
          : '',
      contributorRole:
          const {'rider', 'admin', 'import'}.contains(j['contributor_role'])
          ? j['contributor_role'] as String
          : '',
      facilityType:
          facilityTypesOf(j['facility_types']).firstOrNull ??
          _optionalEnum(FacilityType.values, j['facility_type']),
      facilityTypes: facilityTypesOf(j['facility_types']),
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
      segments: [
        for (final s in j['parking_segments'] as List<dynamic>? ?? const [])
          if (s is Map<String, dynamic>) ParkingSegment.fromJson(s),
      ],
      availabilityUpdatedAt: DateTime.tryParse(
        j['availability_updated_at'] as String? ?? '',
      ),
      scooterVerifiedAt: DateTime.tryParse(
        j['scooter_verified_at'] as String? ?? '',
      ),
      heavyVerifiedAt: DateTime.tryParse(
        j['heavy_verified_at'] as String? ?? '',
      ),
      condition: ParkingCondition.fromJson(j['condition']),
      zonesComplete: j['zones_complete'] == true,
      closure: SpotClosure.fromJson(j['closure'], state: j['closure_state']),
    );
  }

  Map<String, dynamic> toJson() {
    // Favorites sync this snapshot to every signed-in device, including
    // builds that predate newer kinds or conditions. A spot those builds
    // would read more loosely gets the viewports' projection on top and its
    // real fields in `exact_v2`, a key they do not know: re-saved there, it
    // loses information, never safety (§5.3). A newer kind that is otherwise
    // safe keeps `exact`, which builds since the kinds restore.
    final safe = isLegacySafe;
    final exact = safe && _newKinds.contains(spaceType);
    final legacy = exact || !safe;
    final zonesJson = [for (final zone in zones) zone.toJson()];
    return {
      'id': id,
      'name': name,
      'lat': lat,
      'lng': lng,
      'city': city,
      'source': source,
      'space_type': legacy ? SpaceType.offStreet.name : spaceType.name,
      'fee_note': feeNote,
      if (fee case final fee?) 'fee': fee.toJson(),
      'scooter_total': scooterTotal,
      'available': available,
      'heavy_allowed': legacy ? null : heavyAllowed,
      'scooter_allowed': legacy ? null : scooterAllowed,
      // Builds before #201 ignore these and read the null flag as 待確認.
      if (scooterNotStated) 'scooter_not_stated': true,
      if (heavyNotStated) 'heavy_not_stated': true,
      'status': legacy ? TrustStatus.pending.name : status.name,
      if (exact)
        'exact': {
          'space_type': spaceType.name,
          'heavy_allowed': heavyAllowed,
          'scooter_allowed': scooterAllowed,
          'status': status.name,
        },
      if (!safe)
        'exact_v2': {
          'space_type': spaceType.name,
          'heavy_allowed': heavyAllowed,
          'scooter_allowed': scooterAllowed,
          'status': status.name,
          if (condition case final condition?) 'condition': condition.toJson(),
          'parking_zones': zonesJson,
        },
      if (safe && condition != null) 'condition': condition!.toJson(),
      if (zonesComplete) 'zones_complete': true,
      'updated_at': updatedAt?.toIso8601String(),
      'last_confirmed_at': lastConfirmedAt?.toIso8601String(),
      if (createdAt != null) 'created_at': createdAt!.toIso8601String(),
      'note': note,
      'district': district,
      'source_url': sourceUrl,
      'source_name': sourceName,
      'license_note': licenseNote,
      if (contributorRole.isNotEmpty) 'contributor_role': contributorRole,
      if (facilityType != null) 'facility_type': facilityType!.name,
      if (facilityTypes.isNotEmpty)
        'facility_types': [for (final t in facilityTypes) t.name],
      if (access != null) 'parking_access': access!.name,
      if (address.isNotEmpty) 'address': address,
      if (roadSegment.isNotEmpty) 'road_segment': roadSegment,
      if (entranceNote.isNotEmpty) 'entrance_note': entranceNote,
      if (parkingGuide.isNotEmpty) 'parking_guide': parkingGuide,
      if (specialRules.isNotEmpty) 'special_rules': specialRules,
      if (photoUrls.isNotEmpty) 'photo_urls': photoUrls,
      if (zones.isNotEmpty)
        'parking_zones': [
          for (final (i, zone) in zones.indexed)
            safe || zone.legacySafe
                ? zonesJson[i]
                : ({...zonesJson[i]}..remove('access')),
        ],
      // Builds before segments ignore the key; nothing to project.
      if (segments.isNotEmpty)
        'parking_segments': [for (final s in segments) s.toJson()],
      if (availabilityUpdatedAt != null)
        'availability_updated_at': availabilityUpdatedAt!.toIso8601String(),
      if (scooterVerifiedAt != null)
        'scooter_verified_at': scooterVerifiedAt!.toIso8601String(),
      if (heavyVerifiedAt != null)
        'heavy_verified_at': heavyVerifiedAt!.toIso8601String(),
      if (closure case final closure?) 'closure': closure.toJson(),
    };
  }
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
    this.districtSpaceTypes = const {},
    this.restriction,
    this.expiresOn,
  });
  final String city, feeNote, exceptions, sourceUrl;
  final VehicleType vehicle;
  final List<SpaceType> allowedSpaceTypes, conditionalSpaceTypes;
  final List<String> districts;

  /// Space types the rule opens in named districts only, e.g. New Taipei's
  /// free bays in Banqiao and Xindian: parkable there, closed elsewhere.
  final Map<SpaceType, List<String>> districtSpaceTypes;
  final int version;
  final DateTime effectiveDate;
  final bool canUseTwoSpaces;
  final RuleRestriction? restriction;

  /// The first day the rule no longer holds (§3.2); null when it has no end.
  /// Builds before C4 never read it, which is why `city_rules` serves them
  /// expired rows as a conservative projection.
  final DateTime? expiresOn;
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
    districtSpaceTypes: {
      for (final MapEntry(:key, :value)
          in (j['district_space_types'] as Map<String, dynamic>? ?? {}).entries)
        SpaceType.values.byName(key): (value as List<dynamic>).cast<String>(),
    },
    feeNote: j['fee_note'] as String,
    exceptions: j['exceptions'] as String,
    sourceUrl: j['source_url'] as String,
    version: j['version'] as int,
    effectiveDate: DateTime.parse(j['effective_date'] as String),
    canUseTwoSpaces: j['can_use_two_spaces'] as bool? ?? false,
    restriction: RuleRestriction.parse(j['restriction']),
    expiresOn: j['expires_on'] is String
        ? DateTime.tryParse(j['expires_on'] as String)
        : null,
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

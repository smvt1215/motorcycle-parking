import '../../domain/eligibility.dart';
import '../../domain/parking_decision.dart';
import '../../models/parking.dart';

/// Every place a rule can be written for: the national default and the 22
/// municipalities, in the order riders know them (north to south, then the
/// east and the islands). Same list as the server's `admin_upsert_city_rule`.
const ruleCities = [
  '全國',
  '臺北市',
  '新北市',
  '基隆市',
  '桃園市',
  '新竹市',
  '新竹縣',
  '苗栗縣',
  '臺中市',
  '彰化縣',
  '南投縣',
  '雲林縣',
  '嘉義市',
  '嘉義縣',
  '臺南市',
  '高雄市',
  '屏東縣',
  '宜蘭縣',
  '花蓮縣',
  '臺東縣',
  '澎湖縣',
  '金門縣',
  '連江縣',
];

/// How a rule treats one kind of street space.
enum StreetAccess {
  open('可停'),
  conditional('有條件'),
  closed('不開放');

  const StreetAccess(this.label);
  final String label;
}

/// The street spaces a rule decides for each vehicle. Lots follow their own
/// data; disabled, electric and flex bays follow the law or the bay; timed
/// bays follow paid ones; and a heavy-only bay is never a scooter's.
List<SpaceType> streetTypes(VehicleType vehicle) => [
  SpaceType.paidMotorcycle,
  SpaceType.freeMotorcycle,
  if (vehicle == VehicleType.heavy) SpaceType.heavyOnly,
  SpaceType.car,
];

/// Rule restrictions an admin may pick, keyed as stored. `pilot_area` has no
/// app enum value: the app shows it as a generic condition.
const ruleRestrictions = {
  'pilot_area': (label: '限試辦路段', help: '只在公告的試辦路段或區域開放，其他路段不適用'),
  'signage': (label: '限標示車格', help: '只在地面或牌面標示開放此車種的格位停放'),
  'unverified': (label: '規則未核實', help: '公告內容尚未核實，App 會把這些格位顯示為待確認'),
};

String restrictionLabel(String? key) =>
    ruleRestrictions[key]?.label ?? key ?? '無限制';

/// Names from a field: split on 、 , ， and whitespace, blanks and repeats
/// dropped.
List<String> parseNames(String text) {
  final seen = <String>{};
  return [
    for (final name in text.split(RegExp(r'[、,，\s]+')))
      if (name.isNotEmpty && seen.add(name)) name,
  ];
}

/// One `city_rules` row as the editor holds it.
class RuleDraft {
  RuleDraft({
    required this.city,
    required this.vehicle,
    required this.access,
    required this.typeDistricts,
    required this.restriction,
    required this.districts,
    required this.canUseTwoSpaces,
    required this.feeNote,
    required this.exceptions,
    required this.effectiveDate,
    required this.sourceUrl,
    this.version,
    this.original = const {},
  });

  /// The row's values; a missing row starts every street space closed.
  factory RuleDraft.fromRow(
    String city,
    VehicleType vehicle,
    Map<String, dynamic>? row,
  ) {
    final r = row ?? const <String, dynamic>{};
    List<String> names(Object? v) =>
        (v as List<dynamic>? ?? const []).cast<String>();
    final allowed = names(r['allowed_space_types']);
    final conditional = names(r['conditional_space_types']);
    final byDistrict = {
      for (final e
          in (r['district_space_types'] as Map<String, dynamic>? ?? const {})
              .entries)
        e.key: names(e.value),
    };
    return RuleDraft(
      city: city,
      vehicle: vehicle,
      access: {
        for (final t in streetTypes(vehicle))
          t: conditional.contains(t.name)
              ? StreetAccess.conditional
              : allowed.contains(t.name) || byDistrict.containsKey(t.name)
              ? StreetAccess.open
              : StreetAccess.closed,
      },
      typeDistricts: {
        for (final t in streetTypes(vehicle)) t: ?byDistrict[t.name],
      },
      restriction: r['restriction'] as String?,
      districts: names(r['districts']),
      canUseTwoSpaces: r['can_use_two_spaces'] as bool? ?? false,
      feeNote: r['fee_note'] as String? ?? '',
      exceptions: r['exceptions'] as String? ?? '',
      effectiveDate: r['effective_date'] as String? ?? '',
      sourceUrl: r['source_url'] as String? ?? '',
      version: r['version'] as int?,
      original: r,
    );
  }

  final String city;
  final VehicleType vehicle;
  final Map<SpaceType, StreetAccess> access;

  /// Districts a street space is limited to; absent means the whole city.
  final Map<SpaceType, List<String>> typeDistricts;
  String? restriction;
  List<String> districts;
  bool canUseTwoSpaces;
  String feeNote, exceptions, effectiveDate, sourceUrl;

  /// The published version this draft edits; null for a rule not yet written.
  final int? version;

  /// The row as loaded, so kinds the form does not show survive a publish.
  final Map<String, dynamic> original;

  bool get isNew => version == null;
  int get nextVersion => (version ?? 0) + 1;

  RuleDraft copy() => RuleDraft(
    city: city,
    vehicle: vehicle,
    access: {...access},
    typeDistricts: {
      for (final e in typeDistricts.entries) e.key: [...e.value],
    },
    restriction: restriction,
    districts: [...districts],
    canUseTwoSpaces: canUseTwoSpaces,
    feeNote: feeNote,
    exceptions: exceptions,
    effectiveDate: effectiveDate,
    sourceUrl: sourceUrl,
    version: version,
    original: original,
  );

  bool get hasConditional => access.values.contains(StreetAccess.conditional);

  /// Keeps [list]'s order for kinds still wanted, then adds new ones.
  static List<String> _ordered(Object? list, Iterable<String> wanted) {
    final want = wanted.toSet();
    final old = (list as List<dynamic>? ?? const []).cast<String>();
    return [
      ...old.where(want.contains),
      ...want.where((t) => !old.contains(t)),
    ];
  }

  /// The values `admin_upsert_city_rule` stores.
  Map<String, dynamic> toValues() {
    final shown = streetTypes(vehicle).map((t) => t.name).toSet();
    Iterable<String> keep(String key) =>
        ((original[key] as List<dynamic>?) ?? const []).cast<String>().where(
          (t) => !shown.contains(t),
        );
    // New rules list lots as conditional like every bundled rule, so older
    // builds that still read lots from the rule keep doing so.
    final keepConditional = isNew
        ? ['offStreet']
        : keep('conditional_space_types');
    final limited = {
      for (final t in streetTypes(vehicle))
        if (access[t] != StreetAccess.closed &&
            (typeDistricts[t]?.isNotEmpty ?? false))
          t: typeDistricts[t]!,
    };
    final keepDistricts = {
      for (final e
          in (original['district_space_types'] as Map<String, dynamic>? ??
                  const {})
              .entries)
        if (!shown.contains(e.key)) e.key: e.value,
    };
    return {
      'allowed_space_types': _ordered(original['allowed_space_types'], [
        ...keep('allowed_space_types'),
        for (final t in streetTypes(vehicle))
          if (access[t] == StreetAccess.open && !limited.containsKey(t)) t.name,
      ]),
      'conditional_space_types': _ordered(original['conditional_space_types'], [
        ...keepConditional,
        for (final t in streetTypes(vehicle))
          if (access[t] == StreetAccess.conditional) t.name,
      ]),
      'districts': districts,
      'district_space_types': {
        ...keepDistricts,
        for (final e in limited.entries) e.key.name: e.value,
      },
      'restriction': hasConditional ? restriction : null,
      'can_use_two_spaces': canUseTwoSpaces,
      'fee_note': feeNote.trim(),
      'exceptions': exceptions.trim(),
      'effective_date': effectiveDate.trim(),
      'source_url': sourceUrl.trim(),
    };
  }

  /// Field key → why it cannot be published; same limits as the server.
  Map<String, String> errors() {
    final e = <String, String>{};
    final fee = feeNote.trim(), ex = exceptions.trim();
    if (fee.isEmpty || fee.length > 200) e['fee_note'] = '請填 1–200 字的費率說明';
    if (ex.isEmpty || ex.length > 500) {
      e['exceptions'] = '請填 1–500 字，騎士在不可停或有條件時會看到這段說明';
    }
    if (!RegExp(r'^https://\S+$').hasMatch(sourceUrl.trim()) ||
        sourceUrl.trim().length > 500) {
      e['source_url'] = '請貼上 https:// 開頭的公告網址';
    }
    if (parseDate(effectiveDate) == null) {
      e['effective_date'] = '請用 YYYY-MM-DD 格式，例如 2026-11-01';
    }
    if (hasConditional && restriction == null) {
      e['restriction'] = '有條件開放的格位需要選限制類型';
    }
    bool badNames(List<String> names) =>
        names.length > 50 || names.any((n) => n.length > 20);
    if (badNames(districts)) e['districts'] = '每個行政區最多 20 字，最多 50 個';
    for (final t in streetTypes(vehicle)) {
      if (badNames(typeDistricts[t] ?? const [])) {
        e['districts:${t.name}'] = '每個行政區最多 20 字，最多 50 個';
      }
    }
    return e;
  }

  /// The rule as the app would read it once published, for the preview.
  CityRule? toCityRule() {
    final date = parseDate(effectiveDate);
    if (date == null) return null;
    final v = toValues();
    return CityRule.fromJson({
      'city': city,
      'vehicle': vehicle.name,
      ...v,
      'effective_date': effectiveDate.trim(),
      'version': nextVersion,
    });
  }

  /// Equal once published: what the form changes, ignoring list order.
  bool sameAs(RuleDraft other) {
    final a = toValues(), b = other.toValues();
    Object? norm(Object? v) => switch (v) {
      final List<dynamic> l => (l.map((e) => '$e').toList()..sort()).join('|'),
      final Map<String, dynamic> m => {
        for (final k in m.keys.toList()..sort()) k: norm(m[k]),
      }.toString(),
      _ => v,
    };
    return a.keys.every((k) => norm(a[k]) == norm(b[k]));
  }
}

DateTime? parseDate(String text) {
  final t = text.trim();
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) return null;
  final d = DateTime.tryParse(t);
  // DateTime.parse rolls 2026-02-30 over to March; refuse it like Postgres.
  if (d == null || d.toIso8601String().substring(0, 10) != t) return null;
  return d;
}

/// A published rule as the list shows it.
class RuleSummary {
  const RuleSummary({
    required this.city,
    required this.vehicle,
    this.version,
    this.restriction,
    this.bundledVersion,
  });
  final String city;
  final VehicleType vehicle;
  final int? version;
  final String? restriction;

  /// The version inside the app's bundled rule file, if it has the rule.
  final int? bundledVersion;

  /// Published since the bundled file was last exported.
  bool get unsynced => version != null && version != bundledVersion;
}

/// One preview row: what a trusted (official) spot of [type] shows.
typedef PreviewRow = ({SpaceType type, Eligibility result});

/// Districts the preview can place a spot in: every district the rule
/// names, then one outside them, then one whose district is unknown.
const otherDistrict = '其他行政區';
const unknownDistrict = '';

List<String> previewDistricts(RuleDraft draft) {
  final named = <String>{
    ...draft.districts,
    for (final d in draft.typeDistricts.entries)
      if (draft.access[d.key] != StreetAccess.closed) ...d.value,
  };
  return [...named, otherDistrict, unknownDistrict];
}

/// Each street space as the app would mark it on [date] in [district],
/// judged by the shared [eligibility] on an official spot, so only the rule
/// decides.
List<PreviewRow> preview(RuleDraft draft, DateTime date, String district) {
  final rule = draft.toCityRule();
  return [
    for (final type in [
      ...streetTypes(draft.vehicle),
      // Timed bays follow paid ones, then the posted hours.
      SpaceType.timedMotorcycle,
    ])
      (
        type: type,
        result: eligibility(
          ParkingSpot(
            id: 'preview-${type.name}',
            name: type.label,
            lat: 25,
            lng: 121.5,
            city: draft.city == '全國' ? '臺北市' : draft.city,
            district: district == otherDistrict ? '（清單外）' : district,
            spaceType: type,
            condition: typicalCondition(type),
            source: 'official',
          ),
          draft.vehicle,
          rule,
          now: date,
        ),
      ),
  ];
}

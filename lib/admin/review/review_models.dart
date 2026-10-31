import '../../models/closure.dart';
import '../../models/condition_text.dart';
import '../../models/parking_condition.dart';
import '../../models/fee.dart';
import '../../models/fee_plan.dart' show canonicalJson;
import '../../models/parking.dart';
import '../../models/zone_entries.dart';
import '../spots/lot_models.dart';

/// Queue filters from docs/ADMIN_WEB.md: eligibility, gone, everything else.
enum ReviewKind {
  access('停放資格'),
  gone('已不存在'),
  info('點位資訊');

  const ReviewKind(this.label);
  final String label;
}

/// Risk class of a report (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.1),
/// derived by the database when the report is queued; null for rows the
/// server has not classified.
enum ReviewRisk {
  low('低風險', '只改名稱或文字說明'),
  medium('中風險', '費率、同類格位類型、150 m 內移位或已不存在'),
  high('高風險', '停放資格、路外與路邊互換、移位超過 150 m，或無法判斷');

  const ReviewRisk(this.label, this.reason);
  final String label;

  /// What puts a report in this class, in the admin's words.
  final String reason;

  static ReviewRisk? parse(Object? value) =>
      values.where((r) => r.name == value).firstOrNull;
}

/// Why a report is rejected (required) or closed without a change
/// (optional); stored as `moderation_queue.resolution_kind`.
enum ResolutionKind {
  wrong('與現況不符', '建議內容和現場或官方資料不一致'),
  duplicate('重複回報', '與既有案件或已處理的建議重複'),
  insufficient('資訊不足', '說明或照片不夠，無法查證'),
  outdated('已不適用', '點位在送出後已更新，這項建議不再適用'),
  abuse('濫用', '廣告、謾罵或刻意填寫錯誤資料'),
  other('其他原因', '請在處理說明寫下原因');

  const ResolutionKind(this.label, this.description);
  final String label;
  final String description;
}

enum FieldInput {
  text,
  spaceType,
  triState,
  visibility,
  hiddenFlag,
  coordinate,

  /// One of [ReviewField.choices], or unset.
  choice,

  /// Several of [ReviewField.choices] (`facility_types`, decision 58), or
  /// unset.
  multiChoice,

  /// A structured fee per vehicle (`fee`), edited with the shared FeeEditor.
  fee,

  /// A street bay's condition (`condition`, design §1.2): shown and applied
  /// with its space type as the rider sent it; editing it is C6's.
  condition,

  /// A temporary closure (`closure`, #116): works or a closure until a date.
  closure,

  /// A lot's zones or a street spot's segments (`parking_zones`,
  /// `parking_segments`, #188): shown as the list the rider's patches leave
  /// and sent back as the patches that make it, by id.
  entries,
}

/// A spot column `admin_resolve_report` may change, as the admin sees it.
class ReviewField {
  const ReviewField(
    this.key,
    this.label,
    this.input, {
    this.maxLength,
    this.choices = const {},
  });
  final String key;
  final String label;
  final FieldInput input;
  final int? maxLength;

  /// Stored value -> label, for [FieldInput.choice].
  final Map<String, String> choices;
}

/// Display order of the diff table; limits match the table constraints.
final reviewFields = [
  const ReviewField('name', '停車點名稱', FieldInput.text, maxLength: 100),
  const ReviewField('space_type', '格位類型', FieldInput.spaceType),
  // An off-street space type may come with what kind of lot it is.
  ReviewField(
    'facility_type',
    '場站類型',
    FieldInput.choice,
    choices: {for (final f in FacilityType.values) f.name: f.label},
  ),
  // Builds since decision 58 send every type the lot is built as.
  ReviewField(
    'facility_types',
    '場站類型（複選）',
    FieldInput.multiChoice,
    choices: {for (final f in FacilityType.values) f.name: f.label},
  ),
  ReviewField(
    'parking_access',
    '車種開放',
    FieldInput.choice,
    choices: {for (final a in ParkingAccess.values) a.name: a.label},
  ),
  ReviewField('scooter_allowed', '普通機車', FieldInput.triState),
  ReviewField('heavy_allowed', '大型重機', FieldInput.triState),
  ReviewField('condition', '停放條件', FieldInput.condition),
  ReviewField('fee', '費率', FieldInput.fee),
  ReviewField('fee_note', '收費資訊', FieldInput.text, maxLength: 200),
  const ReviewField('note', '備註', FieldInput.text, maxLength: 500),
  const ReviewField('entrance_note', '入口說明', FieldInput.text, maxLength: 500),
  const ReviewField('parking_guide', '停放方式', FieldInput.text, maxLength: 500),
  ReviewField('status', '地圖顯示', FieldInput.visibility),
  ReviewField('hidden', '地圖顯示', FieldInput.hiddenFlag),
  ReviewField('lat', '緯度', FieldInput.coordinate),
  ReviewField('lng', '經度', FieldInput.coordinate),
  // A location suggestion brings the county and district the app looked up,
  // so a move across a border also changes which rules apply.
  const ReviewField('city', '縣市', FieldInput.text, maxLength: 30),
  const ReviewField('district', '行政區', FieldInput.text, maxLength: 30),
  ReviewField('closure', '暫時無法停車', FieldInput.closure),
  const ReviewField('parking_zones', '分區', FieldInput.entries),
  const ReviewField('parking_segments', '路邊分段', FieldInput.entries),
];

ReviewField? reviewField(String key) =>
    reviewFields.where((f) => f.key == key).firstOrNull;

/// Votes hide a community spot themselves and queue this reason.
const autoHiddenReason = '加權負向回報達門檻';

/// Stable `field` keys the app sends, with their labels. Builds before the
/// keys sent the label itself, so both forms are read.
const suggestionFieldLabels = {
  'name': '停車點名稱',
  'space_type': '格位類型',
  'fee_note': '收費資訊',
  'eligibility': '機車停放資格',
  'guide': '入口與停車指引',
  'note': '其他備註',
  'location': '位置不正確',
  'gone': '點位已不存在',
  'reopened': '暫時封閉已恢復',
  'zones': '分區',
  'segments': '路邊分段',
};

/// Labels older builds sent instead of a key.
const _legacyFieldLabels = {'位置或其他備註': 'note'};

/// The key for [field], whether it arrived as a key or as an older label.
String? suggestionKey(String? field) => suggestionFieldLabels.containsKey(field)
    ? field
    : _legacyFieldLabels[field] ??
          suggestionFieldLabels.entries
              .where((e) => e.value == field)
              .firstOrNull
              ?.key;

class ReviewReport {
  const ReviewReport({
    required this.id,
    required this.sourceId,
    required this.reason,
    required this.createdAt,
    this.field,
    this.proposed,
    this.note = '',
    this.baseSpot,
    this.risk,
    this.riskFlags = const [],
    this.evidenceUrl,
  });

  factory ReviewReport.fromJson(Map<String, dynamic> j) => ReviewReport(
    id: j['id'] as String,
    sourceId: j['source_id'] as String,
    reason: j['reason'] as String? ?? '',
    field: j['field'] as String?,
    proposed: (j['proposed'] as Map?)?.cast<String, dynamic>(),
    note: j['note'] as String? ?? '',
    createdAt: DateTime.parse(j['created_at'] as String),
    baseSpot: (j['base_spot'] as Map?)?.cast<String, dynamic>(),
    risk: ReviewRisk.parse(j['risk']),
    riskFlags: [
      for (final f in j['risk_flags'] as List? ?? const [])
        if (f is String) f,
    ],
    evidenceUrl: j['evidence_url'] as String?,
  );

  final String id;
  final String sourceId;

  /// Readable summary; the only content of reports from older app builds.
  final String reason;
  final String? field;
  final Map<String, dynamic>? proposed;
  final String note;
  final DateTime createdAt;

  /// The spot as the rider saw it; null for reports queued before versions.
  final Map<String, dynamic>? baseSpot;

  /// Derived on the server; null when it has not been classified.
  final ReviewRisk? risk;

  /// The precheck `hold` rules the report broke (#158): it was let through
  /// for a closer look. Codes of precheck_rules.json.
  final List<String> riskFlags;

  /// The notice link the rider attached (https), never written to the spot.
  final String? evidenceUrl;

  bool get official => sourceId.startsWith('official:');
  bool get autoHidden => reason == autoHiddenReason;

  /// What the report is about: the structured field, else the prefix older
  /// builds wrote before "：".
  String get title {
    if (field != null) return suggestionFieldLabels[field] ?? field!;
    if (autoHidden) return '多位騎士回報已不存在';
    return _reasonPrefix ?? '其他回報';
  }

  /// What builds before structured fields wrote before "：" in [reason].
  String? get _reasonPrefix {
    final cut = reason.indexOf('：');
    return cut > 0 && cut <= 12 ? reason.substring(0, cut) : null;
  }

  ReviewKind get kind {
    final keys = proposed?.keys ?? const <String>[];
    // Older builds sent only the reason; its prefix names the field.
    final key = suggestionKey(field ?? _reasonPrefix);
    if (key == 'gone' ||
        autoHidden ||
        proposed?['status'] == 'hidden' ||
        proposed?['hidden'] == true) {
      return ReviewKind.gone;
    }
    if (key == 'eligibility' ||
        keys.contains('scooter_allowed') ||
        keys.contains('heavy_allowed')) {
      return ReviewKind.access;
    }
    return ReviewKind.info;
  }

  /// The rider's own words: the whole reason when nothing structured came
  /// with it, or for a gone report, whose cause and reopening date live only
  /// there (alongside the note); else the note.
  String? get riderText => proposed == null || kind == ReviewKind.gone
      ? reason
      : note.trim().isNotEmpty
      ? note.trim()
      : null;
}

/// The reported spot's current values, from `community_spots` or
/// `official_heavy_spots`.
class ReviewSpot {
  const ReviewSpot({
    required this.sourceId,
    required this.official,
    required this.values,
  });

  final String sourceId;
  final bool official;
  final Map<String, dynamic> values;

  String get name => values['name'] as String? ?? '';
  String get city => values['city'] as String? ?? '';
  String get district => values['district'] as String? ?? '';
  double get lat => (values['lat'] as num).toDouble();
  double get lng => (values['lng'] as num).toDouble();
  bool get hidden =>
      official ? values['hidden'] == true : values['status'] == 'hidden';
  DateTime? get updatedAt =>
      DateTime.tryParse(values['updated_at'] as String? ?? '');

  /// Official spots carry their government source; community rows say so.
  String get sourceLabel {
    final name = values['source_name'] as String? ?? '';
    if (official) return name.isEmpty ? '官方點' : '官方點（$name）';
    return '社群點';
  }

  /// Fields this table lets the RPC change: community spots hide through
  /// `status`, official ones through `hidden`.
  bool allows(String key) =>
      reviewField(key) != null && key != (official ? 'status' : 'hidden');
}

/// The proposal the admin starts from: only what the rider sent. A gone
/// report without a value (works, a temporary closure, older builds, votes)
/// is never turned into hiding; the admin decides, see [visibilityKey].
Map<String, dynamic> initialProposal(ReviewReport report, ReviewSpot? spot) {
  final proposal = {...?report.proposed};
  // A suggested fee changes only the vehicles it names; null clears one
  // (design §5.4). What is adopted, shown and checked is the fee it leaves.
  if (proposal['fee'] is Map) {
    final merged = mergeFeeJson(spot?.values['fee'], proposal['fee']);
    proposal['fee'] = merged.isEmpty ? null : merged;
  }
  // Zone and segment patches (#188) change the entries they name by id:
  // what is adopted, shown and checked is the list they leave. A patch
  // naming an entry the spot no longer has is marked stale: never read as
  // a whole list (that would remove the others), only set aside.
  for (final key in entryKeys) {
    if (!proposal.containsKey(key)) continue;
    final merged = entriesPatch(jsonList(spot?.values[key]), proposal[key]);
    proposal[key] = merged ?? StaleEntries(key);
  }
  // A rider's closure (#116) starts the day it was reported and rests on
  // that report; the reviewer may change either before applying.
  if (proposal['closure'] case final Map<String, dynamic> c
      when !c.containsKey('since')) {
    final words = report.note.trim();
    final basis = words.isEmpty ? '車友回報' : '車友回報，附「$words」';
    proposal['closure'] = {
      ...c,
      'since': closureDate(taiwanToday(report.createdAt)),
      'basis': basis.length <= 200 ? basis : '${basis.substring(0, 198)}…」',
    };
  }
  // An adopted fee always carries this build's text of it, never the one
  // the rider's build wrote: older builds write older sentences, which
  // fee_note_of() would refuse.
  if (proposal.containsKey('fee')) {
    proposal['fee_note'] = feeNoteOf(reviewFee(proposal['fee']));
  }
  return proposal;
}

/// The column that hides [spot]: `hidden` for official spots, `status` for
/// community ones.
String visibilityKey(ReviewSpot spot) => spot.official ? 'hidden' : 'status';

/// Only keys the RPC accepts for this spot become the patch.
Map<String, dynamic> applicablePatch(
  Map<String, dynamic> proposal,
  ReviewSpot spot,
) => {
  for (final e in proposal.entries)
    if (_applicable(e.key, e.value, spot)) e.key: e.value,
};

/// Proposal keys that cannot be applied here, shown so they are not missed.
List<String> ignoredKeys(Map<String, dynamic> proposal, ReviewSpot spot) => [
  for (final e in proposal.entries)
    if (!_applicable(e.key, e.value, spot)) e.key,
];

bool _applicable(String key, Object? value, ReviewSpot spot) =>
    spot.allows(key) && fitsField(reviewField(key)!, value);

/// The fields that hold a list of zones or segments by id (#188).
const entryKeys = ['parking_zones', 'parking_segments'];

/// A zone or segment suggestion that names an entry the spot no longer has
/// (removed or replaced since the report): it cannot be applied, and is
/// shown among the suggestions set aside.
class StaleEntries {
  const StaleEntries(this.key);
  final String key;

  @override
  String toString() => key == 'parking_zones' ? '這區已不存在，無法套用' : '這段已不存在，無法套用';
}

/// The keys an entry change names, as the review shows them.
const _entryKeyLabels = {
  'name': '名稱',
  'access': '車種開放',
  'area': '區域',
  'guide': '指引',
  'fee': '費率',
  'fee_plan': '計費規則',
  'condition': '格位',
  'evidence_url': '照片連結',
  'side': '哪一側',
  'range': '範圍',
  'total': '格數',
};

String _entryValue(String key, Object? v) => switch ((key, v)) {
  (_, null) => '未填',
  ('access', final String a) => ParkingAccess.values.asNameMap()[a]?.label ?? a,
  ('fee', _) => reviewFee(v)?.summary ?? '未設定',
  ('condition', _) => conditionSummary(
    ParkingCondition.fromJson(v, zone: true),
  ),
  ('side', final String side) =>
    RoadSide.values.asNameMap()[side]?.label ?? side,
  ('total', final num n) => '$n 格',
  (_, final String text) => text.trim().isEmpty ? '未填' : text,
  _ => '$v',
};

/// What [next] changes in [current] (a zone or segment list), one line per
/// change: 新增, 撤除, or each changed key of an entry, 舊→新.
List<String> entriesChangeLines(Object? current, Object? next) {
  if (next is! List) return const [];
  final now = jsonList(current);
  String nameOf(Map<Object?, Object?> e) =>
      e['name'] is String ? '「${e['name']}」' : '#${e['id']}';
  final byId = {
    for (final e in now)
      if (e['id'] is String) e['id'] as String: e,
  };
  return [
    for (final change in entriesDiff(now, next))
      if (change['removed'] == true)
        '撤除${nameOf(byId[change['id']] ?? change)}'
      else if (!change.containsKey('id'))
        '新增${nameOf(change)}'
      else
        '${nameOf(byId[change['id']]!)}：${[for (final k in change.keys)
          if (k != 'id') '${_entryKeyLabels[k] ?? k} '
                '${_entryValue(k, byId[change['id']]![k])}→${_entryValue(k, change[k])}'].join('；')}',
  ];
}

/// Whether [value] is a whole list of [key]'s entries, each named, as the
/// contract takes it.
bool validEntries(String key, Object? value) =>
    value is List &&
    value.every((e) => e is Map && e['name'] is String) &&
    (key == 'parking_zones' ? validZoneList(value) : validSegmentList(value));

/// Whether [value] has the shape [field]'s editor expects. Proposals come
/// from riders, so a wrong type is set aside instead of reaching an editor.
bool fitsField(ReviewField field, Object? value) => switch (field.input) {
  FieldInput.text => value is String,
  FieldInput.spaceType => SpaceType.values.asNameMap().containsKey(value),
  FieldInput.triState => value == null || value is bool,
  FieldInput.visibility => const {
    'pending',
    'confirmed',
    'hidden',
  }.contains(value),
  FieldInput.hiddenFlag => value is bool,
  FieldInput.coordinate => value is num,
  FieldInput.choice => value == null || field.choices.containsKey(value),
  FieldInput.multiChoice => value == null || validChoices(field, value),
  FieldInput.fee =>
    value == null || value is Fee || Fee.tryParse(value) != null,
  FieldInput.condition => value == null || validCondition(value),
  FieldInput.closure => value == null || validClosure(value),
  FieldInput.entries => validEntries(field.key, value),
};

/// Whether [value] is a non-empty list of distinct [field] choices.
bool validChoices(ReviewField field, Object? value) =>
    value is List &&
    value.isNotEmpty &&
    value.every(field.choices.containsKey) &&
    value.toSet().length == value.length;

/// A `fee` value as a [Fee]: the editor's own, or a valid JSON one. Null
/// when there is none, it is invalid, or it names no vehicle (the form
/// writes no structured fee then).
Fee? reviewFee(Object? value) {
  final fee = value is Fee ? value : Fee.tryParse(value);
  return fee == null || fee.isEmpty ? null : fee;
}

/// Whether two values of [key] say the same; a fee compares by content.
bool sameValue(String key, Object? a, Object? b) =>
    switch (reviewField(key)?.input) {
      FieldInput.fee => reviewFee(a) == reviewFee(b),
      FieldInput.condition =>
        ParkingCondition.fromJson(a) == ParkingCondition.fromJson(b),
      // The same set in any order.
      FieldInput.multiChoice => _sameSet(a, b),
      FieldInput.entries => canonicalJson(a) == canonicalJson(b),
      _ => a == b,
    };

bool _sameSet(Object? a, Object? b) {
  if (a is! List || b is! List) return a == b;
  final x = a.toSet(), y = b.toSet();
  return x.length == y.length && x.containsAll(y);
}

/// [patch] as the RPC takes it: a fee being edited becomes its JSON; a
/// zone or segment list becomes the patches that turn [spot]'s into it, by
/// id (#188), so only the entries it changes can conflict.
Map<String, dynamic> wirePatch(
  Map<String, dynamic> patch, {
  ReviewSpot? spot,
}) => {
  for (final MapEntry(:key, :value) in patch.entries)
    key: switch (reviewField(key)?.input) {
      FieldInput.fee => reviewFee(value)?.toJson(),
      FieldInput.entries when value is List => entriesDiff(
        jsonList(spot?.values[key]),
        value,
      ),
      _ => value,
    },
};

/// A zone or segment list in a line: how many, and their names.
String entriesSummary(String key, Object? value) {
  if (value is! List) return '未設定';
  final names = [
    for (final e in value)
      if (e is Map && e['name'] is String) e['name'] as String,
  ];
  if (names.isEmpty) return key == 'parking_zones' ? '沒有分區' : '沒有路段';
  final unit = key == 'parking_zones' ? '區' : '段';
  return '${names.length} $unit：${names.join('、')}';
}

String formatValue(String key, Object? value) {
  final field = reviewField(key);
  if (field == null) return value?.toString() ?? '未填寫';
  return switch (field.input) {
    FieldInput.triState => switch (value) {
      true => '可停',
      false => '不可停',
      _ => '未確認',
    },
    FieldInput.spaceType =>
      SpaceType.values.asNameMap()[value]?.label ?? '$value',
    FieldInput.visibility => switch (value) {
      'hidden' => '隱藏',
      'confirmed' => '顯示（已確認）',
      _ => '顯示（待確認）',
    },
    FieldInput.hiddenFlag => value == true ? '隱藏' : '顯示',
    FieldInput.coordinate => value is num ? value.toStringAsFixed(6) : '未填寫',
    FieldInput.text =>
      value is String && value.trim().isNotEmpty ? value : '未填寫',
    FieldInput.choice => field.choices[value] ?? '未設定',
    FieldInput.multiChoice =>
      value is List && facilityTypesOf(value).isNotEmpty
          ? facilityTypesLabel(facilityTypesOf(value))
          : '未設定',
    FieldInput.fee => reviewFee(value)?.summary ?? '未設定',
    FieldInput.condition => conditionSummary(ParkingCondition.fromJson(value)),
    FieldInput.closure => closureSummary(value),
    FieldInput.entries => entriesSummary(key, value),
  };
}

/// Mirrors the table checks so an invalid patch never reaches the RPC.
String? validatePatch(Map<String, dynamic> patch, ReviewSpot spot) {
  for (final MapEntry(:key, :value) in patch.entries) {
    final field = reviewField(key);
    if (field == null || !spot.allows(key)) return '「$key」無法在審核中修改';
    switch (field.input) {
      case FieldInput.text:
        final text = value is String ? value.trim() : '';
        if (key == 'name' && text.isEmpty) return '停車點名稱不可空白';
        if (key == 'city' && text.isEmpty) return '縣市不可空白';
        // A fee's own sentence may run past 200 (design §2.5); the check
        // below holds it to the fee.
        final fee = key == 'fee_note'
            ? reviewFee(
                patch.containsKey('fee') ? patch['fee'] : spot.values['fee'],
              )
            : null;
        if (value is! String ||
            (value.length > field.maxLength! &&
                !(key == 'fee_note' && feeNoteFits(value, fee)))) {
          return '${field.label}請在 ${field.maxLength} 個字以內';
        }
      case FieldInput.spaceType:
        if (!SpaceType.values.asNameMap().containsKey(value)) {
          return '請選擇格位類型';
        }
      case FieldInput.triState:
        if (value != null && value is! bool) return '${field.label}的值無效';
      case FieldInput.visibility:
        if (!const {'pending', 'confirmed', 'hidden'}.contains(value)) {
          return '請選擇地圖顯示方式';
        }
      case FieldInput.choice:
        if (value != null && !field.choices.containsKey(value)) {
          return '請選擇${field.label}';
        }
      case FieldInput.multiChoice:
        if (value != null && !validChoices(field, value)) {
          return '請選擇${field.label}';
        }
      case FieldInput.hiddenFlag:
        if (value is! bool) return '請選擇地圖顯示方式';
      case FieldInput.coordinate:
        final (min, max) = key == 'lat' ? (20.0, 27.0) : (118.0, 123.0);
        if (value is! num || value < min || value > max) {
          return '${field.label}需介於 $min 與 $max 之間';
        }
      case FieldInput.condition:
        if (value == null) break;
        final condition = ParkingCondition.fromJson(value);
        if (condition == null) return '停放條件格式不正確';
        // The table holds a street condition to its space type (§1.3).
        final type = SpaceType.values
            .asNameMap()[patch['space_type'] ?? spot.values['space_type']];
        if (type == null ||
            legacySpaceType(condition, offStreet: false) != type) {
          return '停放條件和格位類型不一致，請一併套用建議的格位類型';
        }
      case FieldInput.closure:
        if (!validClosure(value)) return '暫時無法停車的資料不正確，請重新選擇預計恢復日期';
      case FieldInput.entries:
        if (!validEntries(key, value)) return '${field.label}的資料不正確';
      case FieldInput.fee:
        if (value == null) break;
        final fee = value is Fee ? value : Fee.tryParse(value);
        if (fee == null) return '費率格式不正確，請重新選擇收費方式';
        if ([
          fee.scooter,
          fee.heavy,
          fee.car,
        ].nonNulls.any((r) => !r.complete)) {
          return '請填完收費金額，計時另需選計費時間';
        }
        if (!fee.valid) return '金額請填 0 到 10000 的整數';
        if (fee.followGap case final gap?) return gap;
    }
  }
  // The app shows a structured fee before the text, so the text must be the
  // fee's own (feeNoteOf), or an edit to it would never reach riders.
  if (patch.containsKey('fee') || patch.containsKey('fee_note')) {
    final fee = reviewFee(
      patch.containsKey('fee') ? patch['fee'] : spot.values['fee'],
    );
    final note = patch.containsKey('fee_note')
        ? patch['fee_note']
        : spot.values['fee_note'];
    if (fee != null && note != feeNoteOf(fee)) {
      return patch.containsKey('fee')
          ? '收費資訊要和費率一致。改費率時收費資訊會自動更新，不需另外修改。'
          : '這個點位已設定各車種費率，App 顯示的是費率而不是收費資訊。請按「修改後套用」，加入「費率」欄位修改。';
    }
  }
  return null;
}

String relativeAge(DateTime time, DateTime now) {
  final d = now.difference(time);
  if (d.inMinutes < 1) return '剛剛';
  if (d.inHours < 1) return '${d.inMinutes} 分鐘前';
  if (d.inDays < 1) return '${d.inHours} 小時前';
  return '${d.inDays} 天前';
}

/// A location suggestion without the county the app looked up (the lookup
/// failed, or an older build): the admin has to check whether the new
/// position lies in another county or city.
bool locationWithoutCity(ReviewReport report) {
  final proposed = report.proposed;
  return suggestionKey(report.field) == 'location' &&
      proposed != null &&
      (proposed.containsKey('lat') || proposed.containsKey('lng')) &&
      !proposed.containsKey('city');
}

/// The precheck rules that flag a report for a closer look rather than
/// refuse it (supabase/functions/submit-report/precheck_rules.json), in the
/// reviewer's words. Rules in [storedPairHoldRules] are refused when a
/// report names both sides; they only reach review as a hold.
const riskFlagLabels = {
  'share_free_needs_basis': '普大共用的免費格較少見，請對照公告',
  'car_area_scooter_fee': '汽車區填了普通機車費率，請確認現場公告開放機車',
  'charge_free_rate': '免費格的費率不是「免費」',
  'charge_toll_free_rate': '收費格的費率是「免費」',
  'free_with_renew': '免費格填了跨日怎麼收',
  'free_with_extension': '免費格填了付費延長',
  'heavy_bay_scooter_fee': '重機格填了普通機車費率',
  'motorcycle_bay_car_fee': '機車格填了汽車費率',
  'time_limit_mismatch': '限時與計次的有效時間不同',
};

/// precheck_rules.json `stored_pair_hold`: rules between a bay's condition
/// and its fee. A suggestion that brings only one of the two is judged with
/// the spot's stored other half (#158 design trade-off, #155 item 20).
const storedPairHoldRules = {
  'charge_free_rate',
  'charge_toll_free_rate',
  'free_with_renew',
  'free_with_extension',
  'heavy_bay_scooter_fee',
  'motorcycle_bay_car_fee',
  'time_limit_mismatch',
};

/// Each flag of [report] as one line for the reviewer: what the rule says,
/// and for a stored-pair hold which half came from the spot.
List<String> riskFlagLines(ReviewReport report) {
  final proposed = report.proposed ?? const {};
  final hasFee = proposed['fee'] is Map;
  final hasCondition = proposed.containsKey('condition');
  return [
    for (final code in report.riskFlags)
      [
        riskFlagLabels[code] ?? '預檢規則 $code',
        if (storedPairHoldRules.contains(code))
          hasFee && !hasCondition
              ? '：建議只改費率，和點位目前的停放條件不一致。套用前請一併確認停放條件，必要時「修改後套用」加入條件。'
              : !hasFee && hasCondition
              ? '：建議只改停放條件，和點位目前的費率不一致。套用前請一併確認費率，必要時「修改後套用」加入費率。'
              : '：和點位目前的資料組合不一致，請一併確認條件與費率。',
      ].join(),
  ];
}

/// The shared plan an accepted fee would reach beyond this suggestion
/// (design §2.6; canvas AdminSharedPlan): the spot's whole fee uses a plan
/// some zones use too. Suggestions name the spot's whole fee, so the
/// suggestion's own use is 全場費率. Null when the plan is the spot's alone,
/// or the fee is cleared (that only drops the reference).
({Json plan, List<String> zones})? sharedPlanOf(
  Map<String, dynamic> patch,
  ReviewSpot spot,
) {
  if (patch['fee'] is! Map) return null;
  final plan = planById(
    jsonList(spot.values['fee_plans']),
    spot.values['fee_plan'],
  );
  if (plan == null) return null;
  final zones = [
    for (final z in jsonList(spot.values['parking_zones']))
      if (z['fee_plan'] == plan['id'] && z['fee'] is Map)
        (z['name'] as String?)?.trim().isNotEmpty == true
            ? z['name'] as String
            : '未命名分區',
  ];
  return zones.isEmpty ? null : (plan: plan, zones: zones);
}

/// [patch] (as wired) giving the whole fee a plan of its own named [name];
/// the zones keep the shared one.
Map<String, dynamic> ownPlanPatch(
  Map<String, dynamic> patch,
  ReviewSpot spot,
  String name,
) {
  final plans = jsonList(spot.values['fee_plans']);
  final id = nextPlanId(plans);
  return {
    ...patch,
    'fee_plans': [
      ...plans,
      {'id': id, 'name': name.trim(), 'fee': patch['fee']},
    ],
    'fee_plan': id,
    'fee_plans_seen': _seen(spot),
  };
}

/// The plans the page built the edit on; the server refuses the write as a
/// conflict when they changed meanwhile.
Map<String, Object?> _seen(ReviewSpot spot) => {
  'plans': spot.values['fee_plans'],
};

/// [patch] (as wired) editing the shared plan itself: every use follows
/// through the database, so the fee and its text are left to it.
Map<String, dynamic> editedPlanPatch(
  Map<String, dynamic> patch,
  ReviewSpot spot,
) {
  final id = spot.values['fee_plan'];
  return {
    ...patch,
    'fee_plans': [
      for (final p in jsonList(spot.values['fee_plans']))
        if (p['id'] == id) {...p, 'fee': patch['fee']} else p,
    ],
    'fee_plans_seen': _seen(spot),
  }..removeWhere((k, _) => k == 'fee' || k == 'fee_note');
}

/// A closure as one line: 施工中，預計 11 月 30 日（一）恢復; 沒有 when none.
String closureSummary(Object? value) {
  final c = SpotClosure.fromJson(value);
  if (c == null) return value == null ? '沒有（可以停）' : '格式不正確';
  final until = c.until;
  return '${c.reason.label}，'
      '${until == null ? '恢復時間未知（$closureDefaultDays 天後到期）' : '預計 ${closureDayLabel(until)}恢復'}'
      '（${closureDate(c.since)} 起）';
}

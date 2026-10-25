import '../../models/parking.dart';

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
  ReviewField(
    'parking_access',
    '車種開放',
    FieldInput.choice,
    choices: {for (final a in ParkingAccess.values) a.name: a.label},
  ),
  ReviewField('scooter_allowed', '普通機車', FieldInput.triState),
  ReviewField('heavy_allowed', '大型重機', FieldInput.triState),
  ReviewField('fee_note', '收費資訊', FieldInput.text, maxLength: 200),
  const ReviewField('note', '備註', FieldInput.text, maxLength: 500),
  const ReviewField('entrance_note', '入口說明', FieldInput.text, maxLength: 500),
  const ReviewField('parking_guide', '停放方式', FieldInput.text, maxLength: 500),
  ReviewField('status', '地圖顯示', FieldInput.visibility),
  ReviewField('hidden', '地圖顯示', FieldInput.hiddenFlag),
  ReviewField('lat', '緯度', FieldInput.coordinate),
  ReviewField('lng', '經度', FieldInput.coordinate),
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
Map<String, dynamic> initialProposal(ReviewReport report, ReviewSpot? spot) => {
  ...?report.proposed,
};

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
};

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
        if (value is! String || value.length > field.maxLength!) {
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
      case FieldInput.hiddenFlag:
        if (value is! bool) return '請選擇地圖顯示方式';
      case FieldInput.coordinate:
        final (min, max) = key == 'lat' ? (20.0, 27.0) : (118.0, 123.0);
        if (value is! num || value < min || value > max) {
          return '${field.label}需介於 $min 與 $max 之間';
        }
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

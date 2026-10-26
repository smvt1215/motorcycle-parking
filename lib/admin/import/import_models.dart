import '../../models/fee.dart';
import '../review/review_models.dart' show formatValue, reviewField;
import 'fee_reading.dart';

/// What importing one file entry would do (`admin_import_preview`).
enum ImportStatus {
  added('new', '新增', '資料庫還沒有這個點位'),
  update('update', '更新', '匯入會改這些欄位'),
  conflict('conflict', '有管理員修改', '匯入值與管理員修改過的值不同'),
  unchanged('unchanged', '不變', '與資料庫相同'),
  existing('existing', '已存在', '社群點已存在，匯入不更新'),
  invalid('invalid', '無法匯入', '檔案內容有誤');

  const ImportStatus(this.wire, this.label, this.hint);
  final String wire, label, hint;

  /// Entries the administrator can choose to import.
  bool get applicable => this == added || this == update || this == conflict;
}

class ImportChange {
  const ImportChange({
    required this.field,
    required this.current,
    required this.incoming,
    this.adminAt,
    this.adminAction,
  });
  final String field;
  final Object? current, incoming;

  /// When an administrator last set the current value, if it is theirs.
  final DateTime? adminAt;
  final String? adminAction;
  bool get byAdmin => adminAt != null;

  static ImportChange fromJson(Map<String, dynamic> json) {
    final admin = json['admin'];
    return ImportChange(
      field: json['field'] as String,
      current: json['current'],
      incoming: json['incoming'],
      adminAt: admin is Map ? DateTime.tryParse('${admin['at']}') : null,
      adminAction: admin is Map ? admin['action'] as String? : null,
    );
  }
}

class ImportEntry {
  const ImportEntry({
    required this.sourceId,
    required this.official,
    required this.status,
    required this.reason,
    required this.name,
    required this.city,
    required this.district,
    this.baseUpdatedAt,
    this.hidden = false,
    this.changes = const [],
  });
  final String sourceId;
  final bool official;
  final ImportStatus status;
  final String reason, name, city, district;

  /// The version the preview compared with, sent back on apply.
  final String? baseUpdatedAt;
  final bool hidden;
  final List<ImportChange> changes;

  Iterable<ImportChange> get adminChanges => changes.where((c) => c.byAdmin);

  static ImportEntry fromJson(Map<String, dynamic> json) => ImportEntry(
    sourceId: json['source_id'] as String? ?? '',
    official: json['kind'] == 'official',
    status: ImportStatus.values.firstWhere(
      (s) => s.wire == json['status'],
      orElse: () => ImportStatus.invalid,
    ),
    reason: json['reason'] as String? ?? '',
    name: json['name'] as String? ?? '',
    city: json['city'] as String? ?? '',
    district: json['district'] as String? ?? '',
    baseUpdatedAt: json['base_updated_at'] as String?,
    hidden: json['hidden'] == true,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        ImportChange.fromJson(c as Map<String, dynamic>),
    ],
  );
}

/// `admin_import_apply` and `admin_convert_fees` both report what they did
/// not write and why.
class Skipped {
  const Skipped(this.sourceId, this.reason);
  final String sourceId, reason;

  static List<Skipped> listOf(Object? json) => [
    for (final s in (json as List? ?? const []))
      Skipped(
        (s as Map)['source_id'] as String? ?? '',
        s['reason'] as String? ?? '',
      ),
  ];
}

class ImportResult {
  const ImportResult({
    this.inserted = 0,
    this.updated = 0,
    this.skipped = const [],
  });
  final int inserted, updated;
  final List<Skipped> skipped;

  static ImportResult fromJson(Map<String, dynamic> json) => ImportResult(
    inserted: (json['inserted'] as num?)?.toInt() ?? 0,
    updated: (json['updated'] as num?)?.toInt() ?? 0,
    skipped: Skipped.listOf(json['skipped']),
  );

  ImportResult operator +(ImportResult other) => ImportResult(
    inserted: inserted + other.inserted,
    updated: updated + other.updated,
    skipped: [...skipped, ...other.skipped],
  );
}

/// A spot with a fee note but no structured fee (`admin_fee_backlog`).
class FeeBacklogItem {
  const FeeBacklogItem({
    required this.sourceId,
    required this.official,
    required this.name,
    required this.city,
    required this.district,
    required this.spaceType,
    required this.feeNote,
    this.hidden = false,
  });
  final String sourceId, name, city, district, spaceType, feeNote;
  final bool official, hidden;

  static FeeBacklogItem fromJson(Map<String, dynamic> json) => FeeBacklogItem(
    sourceId: json['source_id'] as String,
    official: json['kind'] == 'official',
    name: json['name'] as String? ?? '',
    city: json['city'] as String? ?? '',
    district: json['district'] as String? ?? '',
    spaceType: json['space_type'] as String? ?? '',
    feeNote: json['fee_note'] as String? ?? '',
    hidden: json['hidden'] == true,
  );
}

/// Spots that share one writing and therefore one reading.
class FeeGroup {
  FeeGroup(this.note, this.reading, this.spots);
  final String note;
  final FeeReading reading;
  final List<FeeBacklogItem> spots;

  /// A stable key for selection: the writing, the verdict and the reading's
  /// fee, so a certain reading never shares a group (or its default choice)
  /// with a suggestion that needs a person.
  String get key => '${reading.verdict.name}|${reading.fee?.toJson()}|$note';
}

/// Groups [items] by writing; a community note reads differently on a
/// heavy-only bay, so the space type is part of the reading.
List<FeeGroup> groupFees(Iterable<FeeBacklogItem> items) {
  final groups = <String, FeeGroup>{};
  for (final item in items) {
    final reading = readFeeNote(item.feeNote, spaceType: item.spaceType);
    final group = FeeGroup(item.feeNote, reading, []);
    groups.putIfAbsent(group.key, () => group).spots.add(item);
  }
  return groups.values.toList()
    ..sort((a, b) => b.spots.length.compareTo(a.spots.length));
}

/// The fee and the text it is read from belong together.
const feePair = {'fee', 'fee_note'};

/// Labels for every column an import writes.
const importFieldLabels = {
  'name': '停車點名稱',
  'lat': '緯度',
  'lng': '經度',
  'city': '縣市',
  'district': '行政區',
  'space_type': '格位類型',
  'facility_type': '場站類型',
  'parking_access': '車種開放',
  'scooter_allowed': '普通機車',
  'heavy_allowed': '大型重機',
  'scooter_total': '機車格數',
  'fee_note': '收費資訊',
  'fee': '結構化費率',
  'note': '備註',
  'address': '地址',
  'road_segment': '路段',
  'entrance_note': '入口說明',
  'parking_guide': '停放方式',
  'special_rules': '特殊規則',
  'parking_zones': '停放區域',
  'source_name': '資料來源',
  'source_url': '官方資料網址',
  'source_id': '官方資料編號',
  'license_note': '授權說明',
};

String importFieldLabel(String key) => importFieldLabels[key] ?? key;

/// A stored or imported value as an administrator reads it.
String formatImportValue(String key, Object? value) {
  if (reviewField(key) != null) return formatValue(key, value);
  return switch (key) {
    'fee' => value == null ? '未轉換' : feeNoteOf(Fee.fromJson(value)),
    'parking_zones' =>
      value is List && value.isNotEmpty
          ? value.map((z) => z is Map ? '${z['name'] ?? ''}' : '$z').join('、')
          : '未填寫',
    'scooter_total' => value == null ? '未填寫' : '$value 格',
    _ => value is String && value.trim().isNotEmpty ? value : '未填寫',
  };
}

/// What an audited administrator write was, in the preview's words.
String adminActionLabel(String? action) => switch (action) {
  'update_spot' => '點位頁修改',
  'create_spot' => '管理員新增',
  'resolve_report' => '採納回報',
  'promote_spot' => '改為官方點',
  'convert_fee' => '費率轉換',
  _ => '管理員修改',
};

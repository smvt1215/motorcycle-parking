import '../../models/parking.dart';

enum SpotKind {
  community('社群點'),
  official('官方點');

  const SpotKind(this.label);
  final String label;
}

/// A row of the spots list, from `admin_spots`.
class SpotSummary {
  const SpotSummary({
    required this.sourceId,
    required this.kind,
    required this.name,
    required this.city,
    required this.district,
    required this.address,
    required this.spaceType,
    required this.state,
    required this.updatedAt,
  });

  factory SpotSummary.fromJson(Map<String, dynamic> j) => SpotSummary(
    sourceId: j['source_id'] as String,
    kind: j['kind'] == 'official' ? SpotKind.official : SpotKind.community,
    name: j['name'] as String,
    city: j['city'] as String? ?? '',
    district: j['district'] as String? ?? '',
    address: j['address'] as String? ?? '',
    spaceType: j['space_type'] as String? ?? '',
    state: j['state'] as String? ?? '',
    updatedAt: DateTime.parse(j['updated_at'] as String),
  );

  final String sourceId;
  final SpotKind kind;
  final String name, city, district, address, spaceType;

  /// Community: pending／confirmed／hidden. Official: visible／hidden.
  final String state;
  final DateTime updatedAt;

  bool get hidden => state == 'hidden';
}

/// The spot as loaded for editing; [values] holds its columns.
class SpotRecord {
  const SpotRecord({required this.sourceId, required this.values});
  final String sourceId;
  final Map<String, dynamic> values;

  bool get official => sourceId.startsWith('official:');
  SpotKind get kind => official ? SpotKind.official : SpotKind.community;
  String get name => values['name'] as String? ?? '';
  bool get hidden =>
      official ? values['hidden'] == true : values['status'] == 'hidden';

  /// The version the form was opened with, sent back with every write.
  String get updatedAt => values['updated_at'] as String;

  /// How the community spot came to be: imports are marked by `source`.
  String get origin =>
      values['source'] == 'import' ? 'Google 我的地圖匯入整理' : '騎士回報或管理者新增';
}

enum SpotInput {
  text,
  multiline,
  number,
  integer,
  spaceType,
  triState,
  choice,
  date,
}

enum SpotGroup {
  basic('基本資訊'),
  vehicles('可停車種'),
  fees('費率與說明'),
  location('位置'),
  source('來源');

  const SpotGroup(this.label);
  final String label;
}

class SpotField {
  const SpotField(
    this.key,
    this.label,
    this.group,
    this.input, {
    this.maxLength,
    this.required = false,
    this.choices = const {},
    this.only,
    this.help,
  });
  final String key, label;
  final SpotGroup group;
  final SpotInput input;
  final int? maxLength;
  final bool required;

  /// Stored value -> label, for [SpotInput.choice].
  final Map<String, String> choices;

  /// Fields that exist on one kind only.
  final SpotKind? only;
  final String? help;

  bool appliesTo(SpotKind kind) => only == null || only == kind;
}

/// The 22 municipal and county governments official data comes from.
const governments = [
  '臺北市政府', '新北市政府', '桃園市政府', '臺中市政府', '臺南市政府', '高雄市政府', //
  '基隆市政府', '新竹市政府', '嘉義市政府', '新竹縣政府', '苗栗縣政府', '彰化縣政府',
  '南投縣政府', '雲林縣政府', '嘉義縣政府', '屏東縣政府', '宜蘭縣政府', '花蓮縣政府',
  '臺東縣政府', '澎湖縣政府', '金門縣政府', '連江縣政府',
];

/// Form fields in display order; limits match the table constraints.
final spotFields = <SpotField>[
  const SpotField(
    'name',
    '名稱',
    SpotGroup.basic,
    SpotInput.text,
    maxLength: 100,
    required: true,
  ),
  const SpotField(
    'space_type',
    '格位類型',
    SpotGroup.basic,
    SpotInput.spaceType,
    required: true,
  ),
  SpotField(
    'facility_type',
    '場站類型',
    SpotGroup.basic,
    SpotInput.choice,
    choices: {for (final f in FacilityType.values) f.name: f.label},
  ),
  SpotField(
    'parking_access',
    '車種開放',
    SpotGroup.basic,
    SpotInput.choice,
    choices: {for (final a in ParkingAccess.values) a.name: a.label},
  ),
  const SpotField(
    'status',
    '存在狀態',
    SpotGroup.basic,
    SpotInput.choice,
    only: SpotKind.community,
    choices: {'pending': '待確認', 'confirmed': '已確認存在'},
    help: '「已確認存在」只代表點位存在，不代表停放資格已核實。隱藏請用「隱藏點位」。',
  ),
  const SpotField(
    'scooter_allowed',
    '普通機車',
    SpotGroup.vehicles,
    SpotInput.triState,
  ),
  const SpotField(
    'heavy_allowed',
    '大型重機',
    SpotGroup.vehicles,
    SpotInput.triState,
    help: '大型重機只採官方明載；沒有官方資料時保持「未確認」。',
  ),
  const SpotField(
    'fee_note',
    '費率',
    SpotGroup.fees,
    SpotInput.text,
    maxLength: 200,
    required: true,
  ),
  const SpotField('scooter_total', '機車格數', SpotGroup.fees, SpotInput.integer),
  const SpotField(
    'note',
    '備註',
    SpotGroup.fees,
    SpotInput.multiline,
    maxLength: 500,
  ),
  const SpotField(
    'entrance_note',
    '入口說明',
    SpotGroup.fees,
    SpotInput.multiline,
    maxLength: 500,
  ),
  const SpotField(
    'parking_guide',
    '停放方式',
    SpotGroup.fees,
    SpotInput.multiline,
    maxLength: 500,
  ),
  const SpotField(
    'special_rules',
    '特殊規定',
    SpotGroup.fees,
    SpotInput.multiline,
    maxLength: 500,
  ),
  const SpotField(
    'city',
    '縣市',
    SpotGroup.location,
    SpotInput.text,
    maxLength: 30,
    required: true,
  ),
  const SpotField(
    'district',
    '行政區',
    SpotGroup.location,
    SpotInput.text,
    maxLength: 30,
  ),
  const SpotField(
    'address',
    '地址',
    SpotGroup.location,
    SpotInput.text,
    maxLength: 200,
  ),
  const SpotField(
    'road_segment',
    '路段',
    SpotGroup.location,
    SpotInput.text,
    maxLength: 200,
  ),
  const SpotField(
    'lat',
    '緯度',
    SpotGroup.location,
    SpotInput.number,
    required: true,
  ),
  const SpotField(
    'lng',
    '經度',
    SpotGroup.location,
    SpotInput.number,
    required: true,
  ),
  SpotField(
    'source_name',
    '資料來源',
    SpotGroup.source,
    SpotInput.choice,
    only: SpotKind.official,
    required: true,
    choices: {for (final g in governments) g: g},
  ),
  const SpotField(
    'source_url',
    '官方資料網址',
    SpotGroup.source,
    SpotInput.text,
    only: SpotKind.official,
    required: true,
    help: '需為 https 網址。',
  ),
  const SpotField(
    'effective_date',
    '生效日期',
    SpotGroup.source,
    SpotInput.date,
    only: SpotKind.official,
    required: true,
  ),
  const SpotField(
    'license_note',
    '授權說明',
    SpotGroup.source,
    SpotInput.text,
    only: SpotKind.official,
    maxLength: 200,
  ),
];

SpotField spotField(String key) => spotFields.firstWhere((f) => f.key == key);

/// Mirrors the table checks so a bad value never reaches the RPC.
String? validateSpotField(SpotField field, Object? value) {
  final text = value is String ? value.trim() : null;
  final empty = value == null || (text != null && text.isEmpty);
  if (empty) return field.required ? '請填寫${field.label}' : null;
  switch (field.input) {
    case SpotInput.text || SpotInput.multiline:
      if (value is! String) return '${field.label}格式不正確';
      if (field.maxLength != null && value.length > field.maxLength!) {
        return '${field.label}請在 ${field.maxLength} 個字以內';
      }
      if (field.key == 'source_url' && !value.startsWith('https://')) {
        return '官方資料網址需以 https:// 開頭';
      }
    case SpotInput.number:
      if (value is! num) return '${field.label}需為數字';
      final (min, max) = field.key == 'lat' ? (20.0, 27.0) : (118.0, 123.0);
      if (value < min || value > max) return '${field.label}需介於 $min 與 $max 之間';
    case SpotInput.integer:
      if (value is! int || value < 0) return '${field.label}需為 0 以上的整數';
    case SpotInput.spaceType:
      if (!SpaceType.values.asNameMap().containsKey(value)) return '請選擇格位類型';
    case SpotInput.triState:
      if (value is! bool) return '${field.label}的值無效';
    case SpotInput.choice:
      if (!field.choices.containsKey(value)) return '請選擇${field.label}';
    case SpotInput.date:
      if (value is! String || DateTime.tryParse(value) == null) {
        return '${field.label}格式需為 YYYY-MM-DD';
      }
  }
  return null;
}

/// Only fields whose value differs from the loaded row are sent.
Map<String, dynamic> changedValues(
  Map<String, dynamic> draft,
  Map<String, dynamic> original,
) => {
  for (final e in draft.entries)
    if (_differs(e.value, original[e.key])) e.key: e.value,
};

bool _differs(Object? a, Object? b) {
  if (a is num && b is num) return a != b;
  if (a is String && b is String) return a.trim() != b.trim();
  return a != b;
}

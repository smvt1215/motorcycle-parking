/// A spot's edit history (#141): the admin site's timeline
/// (`admin_spot_history`, C6 canvas EditHistory) and the app's short list
/// (`spot_history`, AppHistory). Both read the same entries; the app's carry
/// no person, note, report or before value.
library;

import 'dart:convert';

import 'condition_text.dart';
import 'fee.dart';
import 'parking.dart';
import 'parking_condition.dart';

/// Who made an entry: an administrator's own write, an import (or fee
/// conversion), or a rider's report an administrator decided (or a rider's
/// new spot).
enum HistoryKind {
  admin,
  import,
  report;

  static HistoryKind parse(Object? v) =>
      values.where((k) => k.name == v).firstOrNull ?? admin;
}

/// One field a write changed. [hasBefore] and [hasAfter] tell a value that
/// is null (unconfirmed) from one the entry does not give: the app's
/// history leaves out the new value once the spot no longer holds it.
class HistoryChange {
  const HistoryChange(
    this.field, {
    this.before,
    this.after,
    this.hasBefore = false,
    this.hasAfter = false,
  });
  final String field;
  final Object? before, after;
  final bool hasBefore, hasAfter;

  factory HistoryChange.fromJson(Map<String, dynamic> j) => HistoryChange(
    j['field'] as String,
    before: j['before'],
    after: j['after'],
    hasBefore: j.containsKey('before'),
    hasAfter: j.containsKey('after'),
  );
}

/// The report an entry decided, as the rider sent it (admin only).
class HistoryReport {
  const HistoryReport({
    required this.id,
    required this.status,
    this.reason = '',
    this.field,
    this.proposed,
    this.note = '',
    this.evidenceUrl,
    this.resolutionNote = '',
    this.resolutionKind,
    this.createdAt,
  });
  final String id, status, reason, note, resolutionNote;
  final String? field, evidenceUrl, resolutionKind;
  final Map<String, dynamic>? proposed;
  final DateTime? createdAt;

  bool get accepted => status == 'accepted';

  factory HistoryReport.fromJson(Map<String, dynamic> j) => HistoryReport(
    id: j['id'] as String,
    status: j['status'] as String? ?? '',
    reason: j['reason'] as String? ?? '',
    field: j['field'] as String?,
    proposed: j['proposed'] as Map<String, dynamic>?,
    note: j['note'] as String? ?? '',
    evidenceUrl: j['evidence_url'] as String?,
    resolutionNote: j['resolution_note'] as String? ?? '',
    resolutionKind: j['resolution_kind'] as String?,
    createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
  );
}

class HistoryEntry {
  const HistoryEntry({
    required this.at,
    required this.kind,
    this.action = '',
    this.created = false,
    this.changes = const [],
    this.actorName,
    this.note = '',
    this.sourceName,
    this.report,
  });
  final DateTime at;
  final HistoryKind kind;

  /// The audit action (`update_spot`, `import_spot`, `resolve_report`…);
  /// empty in the app's entries.
  final String action;

  /// Whether the entry created the spot; it lists no changes then.
  final bool created;
  final List<HistoryChange> changes;

  /// The administrator's display name; null where no administrator acted
  /// (a rider's new spot) or in the app.
  final String? actorName;
  final String note;

  /// The data source an import names (「臺北市停管處」).
  final String? sourceName;
  final HistoryReport? report;

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
    at: DateTime.parse(j['at'] as String),
    kind: HistoryKind.parse(j['kind']),
    action: j['action'] as String? ?? '',
    created: j['created'] == true,
    changes: [
      for (final c in j['changes'] as List<dynamic>? ?? const [])
        HistoryChange.fromJson(c as Map<String, dynamic>),
    ],
    actorName: j['actor_name'] as String?,
    note: j['note'] as String? ?? '',
    sourceName: j['source_name'] as String?,
    report: switch (j['report']) {
      final Map<String, dynamic> r => HistoryReport.fromJson(r),
      _ => null,
    },
  );

  /// Entries from an RPC's JSON array; an entry this build cannot read is
  /// skipped rather than failing the list.
  static List<HistoryEntry> list(Object? rows) => [
    for (final row in rows is List ? rows : const []) ?_tryParse(row),
  ];

  static HistoryEntry? _tryParse(Object? row) {
    try {
      return HistoryEntry.fromJson(row as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// The kinds of data the entry changed, as one heading (「總格數、地址」);
  /// [app] uses the app's words (費率 rather than 收費).
  String title({bool app = false}) {
    if (created) return '建立點位';
    if (action == 'promote_spot') return '改為官方點';
    final groups = historyGroups(changes.map((c) => c.field), app: app);
    if (groups.isNotEmpty) return groups.join('、');
    return switch (action) {
      'hide_spot' => '隱藏點位',
      'restore_spot' => '恢復顯示',
      _ when report != null && !report!.accepted => '駁回回報',
      _ => '沒有欄位變更',
    };
  }
}

/// The kinds of data, in display order, and the fields each covers. The
/// labels follow DESIGN.md's field list; 收費 is 費率 in the app.
const historyFieldGroups = <(String, List<String>)>[
  ('名稱', ['name']),
  ('位置', ['lat', 'lng']),
  ('地址', ['city', 'district', 'address', 'road_segment']),
  ('格位類型', ['space_type', 'condition']),
  ('場站與分區', ['facility_type', 'parking_zones', 'zones_complete']),
  ('停放車種', ['scooter_allowed', 'heavy_allowed', 'parking_access']),
  ('車種確認', ['scooter_verified_at', 'heavy_verified_at']),
  ('收費', ['fee', 'fee_note', 'fee_plan', 'fee_plans', 'fee_source_text']),
  ('總格數', ['scooter_total']),
  ('入口與停車指引', ['entrance_note', 'parking_guide']),
  ('特殊規則', ['special_rules']),
  ('照片', ['photo_urls']),
  ('備註', ['note']),
  ('顯示狀態', ['status', 'hidden']),
  ('資料來源', ['source_name', 'source_url', 'effective_date', 'license_note']),
  ('回報者名稱', ['contributor_name']),
];

/// The groups [fields] fall in, in display order.
List<String> historyGroups(Iterable<String> fields, {bool app = false}) {
  final set = fields.toSet();
  return [
    for (final (label, members) in historyFieldGroups)
      if (members.any(set.contains)) app && label == '收費' ? '費率' : label,
  ];
}

/// One field's own name, where a group has several (「普通機車」 in 停放車種).
const historyFieldLabels = <String, String>{
  'name': '名稱',
  'lat': '緯度',
  'lng': '經度',
  'city': '縣市',
  'district': '行政區',
  'address': '地址',
  'road_segment': '路段',
  'space_type': '格位',
  'condition': '停放條件',
  'facility_type': '場站型式',
  'parking_zones': '分區',
  'zones_complete': '分區涵蓋全場',
  'scooter_allowed': '普通機車',
  'heavy_allowed': '大型重機',
  'parking_access': '停放分類',
  'scooter_verified_at': '普通機車確認',
  'heavy_verified_at': '大型重機確認',
  'fee': '費率',
  'fee_note': '收費說明',
  'fee_plan': '計費規則',
  'fee_plans': '計費規則',
  'fee_source_text': '原始公告文字',
  'scooter_total': '機車格',
  'entrance_note': '入口',
  'parking_guide': '停車指引',
  'special_rules': '特殊規則',
  'photo_urls': '照片',
  'note': '備註',
  'status': '狀態',
  'hidden': '顯示',
  'source_name': '資料來源',
  'source_url': '資料網址',
  'effective_date': '生效日期',
  'license_note': '授權說明',
  'contributor_name': '回報者名稱',
};

String historyFieldLabel(String field) => historyFieldLabels[field] ?? field;

/// [value] of [field] as one short line, the way the spot pages word it.
String historyValueText(String field, Object? value) {
  String clip(String s) => s.length > 80 ? '${s.substring(0, 80)}…' : s;
  return switch ((field, value)) {
    (_, null) when field == 'scooter_allowed' || field == 'heavy_allowed' =>
      '未確認',
    ('scooter_allowed' || 'heavy_allowed', true) => '可停',
    ('scooter_allowed' || 'heavy_allowed', false) => '不可停',
    ('fee', _) => feeNoteOf(structuredFee(value)),
    ('condition', _) => conditionSummary(ParkingCondition.fromJson(value)),
    ('space_type', final String v) =>
      SpaceType.values.asNameMap()[v]?.label ?? v,
    ('facility_type', final String v) =>
      FacilityType.values.asNameMap()[v]?.label ?? v,
    ('parking_access', final String v) =>
      ParkingAccess.values.asNameMap()[v]?.description ?? v,
    ('scooter_total', final num v) => '$v 格',
    ('parking_zones', final List<dynamic> v) =>
      v.isEmpty ? '沒有分區' : '${v.length} 個分區',
    ('photo_urls', final List<dynamic> v) =>
      v.isEmpty ? '沒有照片' : '${v.length} 張照片',
    ('zones_complete', final bool v) => v ? '是' : '否',
    ('hidden', final bool v) => v ? '隱藏' : '顯示',
    ('status', 'pending') => '待確認',
    ('status', 'confirmed') => '已確認存在',
    ('status', 'hidden') => '隱藏',
    ('scooter_verified_at' || 'heavy_verified_at', final String v) =>
      DateTime.tryParse(v)?.toLocal().toString().substring(0, 10) ?? v,
    (_, null) => '未提供',
    (_, final String v) => v.trim().isEmpty ? '（空白）' : clip(v),
    (_, final num v) => '$v',
    (_, final bool v) => v ? '是' : '否',
    _ => clip(jsonEncode(value)),
  };
}

/// What the app says an entry changed (AppHistory): each new value the spot
/// still holds, joined with 「；」; fields without one are only named in the
/// title. The fee speaks for itself as its sentence; free text is quoted.
String historySummary(HistoryEntry entry) {
  final fields = {for (final c in entry.changes) c.field};
  final parts = <String>[];
  for (final c in entry.changes) {
    if (!c.hasAfter) continue;
    final v = c.after;
    switch (c.field) {
      case 'fee' when fields.contains('fee_note'):
        continue; // fee_note is the same fee in words.
      case 'fee':
        parts.add(feeNoteOf(structuredFee(v)));
      case 'fee_note' when v is String && v.trim().isNotEmpty:
        parts.add(v.trim());
      case 'scooter_total' when v is num:
        parts.add('機車格改為 $v 格');
      case 'scooter_allowed' || 'heavy_allowed':
        parts.add(
          '${historyFieldLabel(c.field)}改為${historyValueText(c.field, v)}',
        );
      case 'space_type' || 'facility_type' || 'parking_access':
        parts.add('改為${historyValueText(c.field, v)}');
      case 'name' ||
              'address' ||
              'road_segment' ||
              'entrance_note' ||
              'parking_guide' ||
              'special_rules' ||
              'note'
          when v is String:
        final text = v.trim();
        final shown = text.length > 40 ? '${text.substring(0, 40)}…' : text;
        parts.add(
          text.isEmpty
              ? '移除${historyFieldLabel(c.field)}'
              : '${historyFieldLabel(c.field)}改為「$shown」',
        );
    }
  }
  return parts.join('；');
}

/// Who an app entry came from, without naming anyone (AppHistory):
/// 「車友建議，管理員已確認」「政府公開資料更新」….
String historySourceText(HistoryEntry entry, {required bool official}) =>
    switch ((entry.kind, entry.created)) {
      (HistoryKind.report, true) => '車友新增',
      (HistoryKind.report, false) => '車友建議，管理員已確認',
      (HistoryKind.import, true) => official ? '政府公開資料' : '匯入資料',
      (HistoryKind.import, false) => official ? '政府公開資料更新' : '匯入資料更新',
      (HistoryKind.admin, true) => '管理員新增',
      (HistoryKind.admin, false) => '管理員更新',
    };

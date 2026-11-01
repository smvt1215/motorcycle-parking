/// The words of the explore map's filter row (design canvas Main) and the
/// space kind sheet (P1, multiple choice). Pure Dart.
library;

import '../models/space_kind.dart';

/// 「現在可停」: keeps only the spots the rider's vehicle may park in now
/// (#244): the four signs' 能不能停 open now.
const parkableNowLabel = '現在可停';

/// Clears every filter but the vehicle.
const clearFiltersLabel = '清除篩選';

/// The P1 sheet's title, its line under it, and its group's name.
const spaceKindSheetTitle = '格位類型';
const spaceKindSheetLead = '可複選，只顯示選定類型的停車點。';
const spaceKindGroupLabel = '格位類型，可複選';

/// The row that stands for no kind picked.
const allSpaceKindsLabel = '全部格位';
const allSpaceKindsDetail = '顯示所有類型的停車點';

/// The space chip: 全部格位 with nothing picked, the kind's name for one,
/// and how many kinds otherwise.
String spaceKindChipLabel(Set<SpaceKind> kinds) => switch (kinds.length) {
  0 => allSpaceKindsLabel,
  1 => kinds.single.label,
  final n => '格位 $n 類',
};

/// The line under the P1 list.
String spaceKindSummary(Set<SpaceKind> kinds) =>
    '${kinds.isEmpty ? '顯示全部格位。' : '已選 ${kinds.length} 類。'}'
    '　數字是目前地圖範圍內的數量。';

/// A P1 row as a screen reader reads it.
String spaceKindRowLabel(String label, int? count) =>
    count == null ? label : '$label，目前範圍 $count 個';

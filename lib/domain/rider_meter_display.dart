/// The rider-report map badge (design canvas Ver.154 A0, P3): a light grey
/// pill with a 3-bar meter, two meters side by side when reports disagree.
/// Display only; the reports reach the map in a later change (PR-E). Pure
/// Dart.
library;

import 'availability_display.dart';

/// How much space riders report, by the bars the meter fills.
enum RiderLevel {
  full(0, '已停滿'),
  almostFull(1, '快滿了'),
  some(2, '還有一些'),
  plenty(3, '很多空位');

  const RiderLevel(this.bars, this.label);

  /// Filled bars of 3: more bars, more space (as on the details plate).
  final int bars;
  final String label;
}

const riderConflictLabel = '說法不一';
const riderConflictDetail = '回報對不上，到場再確認';

/// One badge: a level, or for 說法不一 the two extremes reported.
class RiderMeter {
  const RiderMeter(this.level) : other = null;

  /// Reports disagree: [level] and [other] are the extremes, drawn in that
  /// order.
  const RiderMeter.conflict(this.level, RiderLevel this.other);

  final RiderLevel level;
  final RiderLevel? other;

  bool get conflicting => other != null;

  String get label => conflicting ? riderConflictLabel : level.label;

  /// What a screen reader says.
  String get semantics => conflicting
      ? '車友回報$riderConflictLabel：${level.label}到${other!.label}，'
            '$riderConflictDetail'
      : '車友回報：${level.label}';

  @override
  bool operator ==(Object other) =>
      other is RiderMeter && other.level == level && other.other == this.other;

  @override
  int get hashCode => Object.hash(level, other);
}

/// Whether a rider badge may show beside [capsules]: never next to an
/// official pill, which rider reports do not override.
bool riderMeterShown(List<AvailabilityCapsule> capsules) => capsules.isEmpty;

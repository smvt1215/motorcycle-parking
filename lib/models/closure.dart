/// A spot's temporary closure (#116, decision 41; closure canvas): works
/// (施工中) or a closure (暫時封閉), since a date, until the date its notice
/// gives — or, without one, 7 days after it began. The server judges by
/// date whether it is still on (`closure_state`, Asia/Taipei); once it is
/// over the spot shows again and asks riders to confirm. Never deletes the
/// spot. Mirrors `valid_closure()` in
/// supabase/migrations/202610270091_spot_closures.sql.
library;

enum ClosureReason {
  works('施工中'),
  closed('暫時封閉');

  const ClosureReason(this.label);
  final String label;

  static ClosureReason? parse(Object? value) =>
      values.where((r) => r.name == value).firstOrNull;
}

/// Whether the closure still holds ([active]) or its date has passed and
/// nobody has confirmed the spot since ([expired]).
enum ClosureState { active, expired }

/// Days a closure without a date lasts.
const closureDefaultDays = 7;

final _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime? parseClosureDate(Object? value) {
  if (value is! String || !_date.hasMatch(value)) return null;
  final d = DateTime.tryParse(value);
  // 2026-02-30 parses as March 2nd: not a real date.
  return d != null && closureDate(d) == value ? d : null;
}

/// [d] as `YYYY-MM-DD`.
String closureDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Today in Taiwan, as the server judges closures.
DateTime taiwanToday(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 8));
  return DateTime(t.year, t.month, t.day);
}

class SpotClosure {
  const SpotClosure({
    required this.reason,
    required this.since,
    this.until,
    this.basis = '',
    this.state,
  });

  final ClosureReason reason;
  final DateTime since;

  /// The reopening date the notice gives; null when unknown.
  final DateTime? until;

  /// What the closure rests on: a rider's report and their words, or the
  /// admin's note.
  final String basis;

  /// The server's judgement; null when the row did not say (then
  /// [stateOn] judges the same way).
  final ClosureState? state;

  /// The last day it holds: [until], or 7 days after [since].
  DateTime get endsOn =>
      until ?? since.add(const Duration(days: closureDefaultDays));

  /// The server's judgement, unless the date has passed since it was read
  /// (an app left open overnight, a saved favorite): a closure never holds
  /// past [endsOn].
  ClosureState stateOn(DateTime now) =>
      state == ClosureState.expired || taiwanToday(now).isAfter(endsOn)
      ? ClosureState.expired
      : ClosureState.active;

  /// The stored closure in [json], or null when there is none or it breaks
  /// the column's shape (`valid_closure()`).
  static SpotClosure? fromJson(Object? json, {Object? state}) {
    if (!validClosure(json) || json == null) return null;
    final j = json as Map;
    return SpotClosure(
      reason: ClosureReason.parse(j['reason'])!,
      since: parseClosureDate(j['since'])!,
      until: parseClosureDate(j['until']),
      basis: j['basis'] as String? ?? '',
      state: switch (state) {
        'active' => ClosureState.active,
        'expired' => ClosureState.expired,
        _ => null,
      },
    );
  }

  Map<String, Object> toJson() => {
    'reason': reason.name,
    'since': closureDate(since),
    if (until case final d?) 'until': closureDate(d),
    if (basis.isNotEmpty) 'basis': basis,
  };

  SpotClosure copyWith({DateTime? Function()? until, ClosureReason? reason}) =>
      SpotClosure(
        reason: reason ?? this.reason,
        since: since,
        until: until == null ? this.until : until(),
        basis: basis,
      );
}

/// Whether [json] is a closure the column accepts (or none).
bool validClosure(Object? json) {
  if (json == null) return true;
  if (json is! Map) return false;
  if (json.keys.any(
    (k) => !const {'reason', 'since', 'until', 'basis'}.contains(k),
  )) {
    return false;
  }
  if (ClosureReason.parse(json['reason']) == null) return false;
  final since = parseClosureDate(json['since']);
  if (since == null) return false;
  if (json.containsKey('until')) {
    final until = parseClosureDate(json['until']);
    if (until == null || until.isBefore(since)) return false;
  }
  final basis = json['basis'];
  if (json.containsKey('basis') && (basis is! String || basis.length > 200)) {
    return false;
  }
  return true;
}

/// `M 月 D 日（一）`, as notices write a date.
String closureDayLabel(DateTime d) =>
    '${d.month} 月 ${d.day} 日（${const ['一', '二', '三', '四', '五', '六', '日'][d.weekday - 1]}）';

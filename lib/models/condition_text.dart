/// A parking condition as riders and admins read it in one line (design
/// §1.2): what a suggestion changes, in the app's 你要改的內容 and on the
/// admin review page.
library;

import 'fee.dart' show FeeWords;
import 'parking.dart' show SpaceType, SpaceLabel;
import 'parking_condition.dart';

const _slotVehicleLabels = {
  SlotVehicle.scooter: '普通機車',
  SlotVehicle.heavy: '大型重機',
  SlotVehicle.car: '汽車',
};

/// One period of a 汽機共用 bay: its days, its time and who may park.
String scheduleSlotText(ScheduleSlot slot) {
  final days = FeeWords.dayLabel(FeeWords.dayMask(slot.days));
  final time = _periodTime(slot.from, slot.to);
  final who = slot.vehicles.map((v) => _slotVehicleLabels[v]).join('、');
  return '$days $time $who';
}

String _periodTime(String? from, String? to) => from == null || to == null
    ? '全天'
    : '$from–${to.compareTo(from) < 0 ? '隔日 ' : ''}$to';

/// One period of a time limit or a no-parking limit (#188 layer 2): its days
/// and time, then for a time limit 每次限停 N，可延長 M 次 (不能延長 for 0;
/// nothing when an old limit does not say).
String limitPeriodText(LimitPeriod p) {
  final when =
      '${FeeWords.dayLabel(FeeWords.dayMask(p.days))} ${_periodTime(p.from, p.to)}';
  if (p.maxMinutes == null) return when;
  final ext = switch (p.extensions) {
    null => '',
    0 => '，不能延長',
    final n => '，可延長 $n 次',
  };
  return '$when 每次限停 ${FeeWords.span(p.maxMinutes!)}$ext';
}

/// A time limit or a no-parking limit as words: 限時（…；…） or
/// 禁停（…）; 限時 alone when the minutes are unconfirmed.
String limitText(ParkingLimit l) => switch (l.kind) {
  LimitKind.timeLimit => switch (l.timePeriods) {
    [] => '限時',
    // Every day, all day: 限停 20 分鐘（，可延長 1 次）.
    [final p] when p.days == 'all' && p.from == null =>
      '限停 ${FeeWords.span(p.maxMinutes!)}${switch (p.extensions) {
        null => '',
        0 => '，不能延長',
        final n => '，可延長 $n 次',
      }}',
    final periods => '限時（${periods.map(limitPeriodText).join('；')}）',
  },
  LimitKind.noParking => '禁停（${l.periods.map(limitPeriodText).join('；')}）',
  LimitKind.evOnly => '限電動機車',
  LimitKind.specialVehicle => '限身障特製機車',
};

/// A condition as one line: charge, 普大共用, the time limit and each
/// period, each only when known; 未提供 without one.
String conditionSummary(ParkingCondition? c) {
  if (c == null) return '未提供';
  final parts = [
    switch (c.charge) {
      Charge.toll => '收費',
      Charge.free => '免費',
      null => '收費未確認',
    },
    if (c.share == ShareKind.scooterHeavy) '普通、大型重機共用',
    for (final l in c.limits)
      if (l.kind == LimitKind.timeLimit || l.kind == LimitKind.noParking)
        limitText(l),
    for (final slot in c.schedule) '共用時段 ${scheduleSlotText(slot)}',
  ];
  return parts.join('、');
}

/// What the map leads with for a street bay of [type] under [c] (C6 canvas
/// AppForm「App 會顯示」): 有條件 and its limits when any applies,
/// otherwise the kind, 普大共用 and whether it charges.
String conditionHeadline(SpaceType type, ParkingCondition? c) {
  if (c == null) return type.label;
  final shared = c.share == ShareKind.scooterHeavy;
  final limits = [
    for (final l in c.limits) limitText(l),
    if (c.share == ShareKind.carMotorcycle)
      c.schedule.isEmpty ? '汽機共用時段未確認' : '依告示時段汽機共用',
  ];
  if (limits.isNotEmpty) {
    return '有條件・${[...limits, if (shared) '普通、大型重機共用'].join('、')}';
  }
  final plain =
      type == SpaceType.paidMotorcycle || type == SpaceType.freeMotorcycle;
  return [
    if (shared && plain) '普大共用機車格' else type.label,
    if (shared && !plain) '普通、大型重機共用',
    if (!plain || shared)
      switch (c.charge) {
        Charge.toll => '收費',
        Charge.free => '免費',
        null => '收費未確認',
      },
  ].join('・');
}

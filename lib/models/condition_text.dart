/// A parking condition as riders and admins read it in one line (design
/// §1.2): what a suggestion changes, in the app's 你要改的內容 and on the
/// admin review page.
library;

import 'fee.dart' show FeeWords;
import 'parking_condition.dart';

const _slotVehicleLabels = {
  SlotVehicle.scooter: '普通機車',
  SlotVehicle.heavy: '大型重機',
  SlotVehicle.car: '汽車',
};

/// One period of a 汽機共用 bay: its days, its time and who may park.
String scheduleSlotText(ScheduleSlot slot) {
  final days = FeeWords.dayLabel(FeeWords.dayMask(slot.days));
  final time = slot.from == null || slot.to == null
      ? '全天'
      : '${slot.from}–${slot.to!.compareTo(slot.from!) < 0 ? '隔日 ' : ''}${slot.to}';
  final who = slot.vehicles.map((v) => _slotVehicleLabels[v]).join('、');
  return '$days $time $who';
}

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
      if (l.kind == LimitKind.timeLimit)
        l.maxMinutes == null ? '限時' : '限停 ${l.maxMinutes} 分鐘',
    for (final slot in c.schedule) '共用時段 ${scheduleSlotText(slot)}',
  ];
  return parts.join('、');
}

import 'package:material_ui/material_ui.dart';

import '../../models/parking.dart';
import '../../models/fee.dart' show FeeWords;
import '../../models/parking_condition.dart';

export '../../models/condition_text.dart' show conditionSummary;
import 'report_sheet.dart' show ChoiceField;

/// The bay kinds whose painted markings already say whether they charge:
/// the rider picks 收費 or 免費 through the kind itself.
const _chargeByType = {SpaceType.paidMotorcycle, SpaceType.freeMotorcycle};

/// Motorcycle bays a notice may open to both classes (普大共用, §1.1).
const _shareable = {
  SpaceType.paidMotorcycle,
  SpaceType.freeMotorcycle,
  SpaceType.timedMotorcycle,
};

/// One period of a 汽機共用 bay while it is being reported (§1.2 schedule).
class SlotDraft {
  SlotDraft();

  SlotDraft.of(ScheduleSlot slot)
    : days = slot.days,
      allDay = slot.from == null && slot.to == null,
      vehicles = slot.vehicles.toSet() {
    from.text = slot.from ?? '';
    to.text = slot.to ?? '';
  }

  /// `all`, `weekday` or `holiday`, or weekdays one by one (`["mon"]`) as
  /// stored: the app picks presets only, but keeps picked days it loaded
  /// rather than widening them to every day.
  Object days = 'all';
  bool allDay = true;
  final from = TextEditingController(), to = TextEditingController();
  Set<SlotVehicle> vehicles = {};

  void dispose() {
    from.dispose();
    to.dispose();
  }

  /// The slot as the contract takes it; null until it is complete.
  ScheduleSlot? get slot {
    final f = from.text.trim(), t = to.text.trim();
    final time = RegExp(timePattern);
    if (vehicles.isEmpty) return null;
    if (!allDay && (!time.hasMatch(f) || !time.hasMatch(t) || f == t)) {
      return null;
    }
    return ScheduleSlot(
      days: days,
      from: allDay ? null : f,
      to: allDay ? null : t,
      vehicles: [
        for (final v in SlotVehicle.values)
          if (vehicles.contains(v)) v,
      ],
    );
  }
}

/// What a rider adds to the bay kind they picked (design §8.4, C5): whether
/// it charges, a 普大共用 notice, how long a 限時 bay allows, and when a
/// 汽機共用 bay takes which vehicles. The kind decides the rest.
class ConditionDraft {
  ConditionDraft() : loadedType = null;

  /// The rider's values from a stored [condition] of a bay of [type].
  ConditionDraft.of(ParkingCondition? condition, SpaceType type)
    : loadedType = type {
    final c = condition ?? conditionOf(type);
    if (c == null) return;
    if (!_chargeByType.contains(type)) charge = c.charge;
    shared = c.share == ShareKind.scooterHeavy;
    for (final l in c.limits) {
      if (l.kind == LimitKind.timeLimit && l.maxMinutes != null) {
        maxMinutes.text = '${l.maxMinutes}';
      }
    }
    slots.addAll(c.schedule.map(SlotDraft.of));
    loadedLimits = c.limits;
  }

  /// The stored limits, kept as they are while the kind does: the form
  /// edits only a 限時 bay's minutes, never drops one it cannot show.
  List<ParkingLimit> loadedLimits = const [];

  /// The kind the stored condition came with: its periods stay as they
  /// are while the kind does, even where this form cannot edit them.
  final SpaceType? loadedType;

  Charge? charge;
  bool shared = false;
  final maxMinutes = TextEditingController();
  final slots = <SlotDraft>[];

  void dispose() {
    maxMinutes.dispose();
    for (final s in slots) {
      s.dispose();
    }
  }

  /// The condition a street bay of [type] is sent with; null for a lot,
  /// whose zones carry theirs. Its space type is always [type] (§1.3).
  ParkingCondition? conditionFor(SpaceType type) {
    final base = conditionOf(type);
    if (base == null) return null;
    final share = shared && _shareable.contains(type);
    final minutes = int.tryParse(maxMinutes.text.trim());
    return ParkingCondition(
      bay: base.bay,
      use: share ? BayUse.share : base.use,
      share: share ? ShareKind.scooterHeavy : base.share,
      charge: _chargeByType.contains(type) ? base.charge : charge,
      limits: [
        for (final l in type == loadedType ? loadedLimits : base.limits)
          // The minutes field shows on 限時 bays only; elsewhere a stored
          // time limit stays as it is.
          l.kind == LimitKind.timeLimit && type == SpaceType.timedMotorcycle
              ? ParkingLimit(LimitKind.timeLimit, maxMinutes: minutes)
              : l,
      ],
      schedule: type == SpaceType.flexShared || type == loadedType
          ? [for (final s in slots) ?s.slot]
          : const [],
    );
  }
}

/// The fields of [ConditionDraft] that a bay of [type] asks for, under the
/// bay kind picker. [hint] is a precheck fix about them; [holdHint] a note
/// that the report will wait for review.
class ConditionFields extends StatelessWidget {
  const ConditionFields({
    super.key,
    required this.type,
    required this.draft,
    required this.onChanged,
    this.holdHint,
  });
  final SpaceType type;
  final ConditionDraft draft;
  final VoidCallback onChanged;
  final String? holdHint;

  static const maxSlots = scheduleMaxEntries;

  @override
  Widget build(BuildContext context) {
    if (conditionOf(type) == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        if (!_chargeByType.contains(type))
          ChoiceField<Charge?>(
            key: const ValueKey('condition-charge'),
            label: '收費格還是免費格',
            value: draft.charge,
            options: const [
              (Charge.toll, '收費'),
              (Charge.free, '免費'),
              (null, '未確認'),
            ],
            onChanged: (v) {
              draft.charge = v;
              onChanged();
            },
          ),
        if (_shareable.contains(type))
          CheckboxListTile(
            key: const ValueKey('condition-shared'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: draft.shared,
            title: const Text('標示「普通、大型重機共用」'),
            subtitle: const Text('地面或告示牌寫明兩種機車都能停時才勾選'),
            onChanged: (v) {
              draft.shared = v ?? false;
              onChanged();
            },
          ),
        if (holdHint case final hint?)
          _Note(key: const ValueKey('condition-hold'), text: hint),
        if (type == SpaceType.timedMotorcycle) ...[
          const SizedBox(height: 8),
          TextFormField(
            key: const ValueKey('condition-max-minutes'),
            controller: draft.maxMinutes,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '限停幾分鐘（選填）',
              hintText: '例：20',
              suffixText: '分鐘',
              errorMaxLines: 3,
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (v) {
              final text = v?.trim() ?? '';
              if (text.isEmpty) return null;
              final n = int.tryParse(text);
              return n == null || n < 1 || n > 1440
                  ? '請填 1 到 1440 的整數；牌面沒寫就留空'
                  : null;
            },
            onChanged: (_) => onChanged(),
          ),
        ],
        if (type == SpaceType.flexShared) ...[
          const SizedBox(height: 8),
          Text('汽機共用的時段（選填）', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            '照告示牌填每段時間可停的車種；沒填的時間 App 會顯示未確認。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          for (final (i, slot) in draft.slots.indexed)
            _SlotCard(
              key: ObjectKey(slot),
              index: i,
              slot: slot,
              onChanged: onChanged,
              onRemove: () {
                draft.slots.remove(slot);
                slot.dispose();
                onChanged();
              },
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const ValueKey('condition-slot-add'),
              onPressed: draft.slots.length >= maxSlots
                  ? null
                  : () {
                      draft.slots.add(SlotDraft());
                      onChanged();
                    },
              icon: const Icon(Icons.add),
              label: Text(
                draft.slots.length >= maxSlots ? '最多 $maxSlots 個時段' : '加一個時段',
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// A note that the report goes on but waits for review: an info icon and
/// the sentence, in the page's muted ink rather than the error colour.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text, style: TextStyle(color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

/// A precheck hold under the field it is about; nothing when [text] is null.
class PrecheckHoldText extends StatelessWidget {
  const PrecheckHoldText(this.text, {super.key});
  final String? text;

  @override
  Widget build(BuildContext context) =>
      text == null ? const SizedBox.shrink() : _Note(text: text!);
}

String? _time(String? v) =>
    RegExp(timePattern).hasMatch(v?.trim() ?? '') ? null : '請用 24 小時制，例如 08:00';

const _dayLabels = [('all', '每天'), ('weekday', '平日'), ('holiday', '假日')];
const _slotVehicles = [
  (SlotVehicle.scooter, '普通機車'),
  (SlotVehicle.heavy, '大型重機'),
  (SlotVehicle.car, '汽車'),
];

class _SlotCard extends StatelessWidget {
  const _SlotCard({
    super.key,
    required this.index,
    required this.slot,
    required this.onChanged,
    required this.onRemove,
  });
  final int index;
  final SlotDraft slot;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final k = 'condition-slot-$index';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: colors.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '時段 ${index + 1}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    key: ValueKey('$k-remove'),
                    tooltip: '刪除時段 ${index + 1}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemove,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (slot.days case final List<Object?> picked)
                          ChoiceChip(
                            key: ValueKey('$k-days-picked'),
                            label: Text(
                              FeeWords.dayLabel(FeeWords.dayMask(picked)),
                            ),
                            selected: true,
                            onSelected: (_) {},
                          ),
                        for (final (value, label) in _dayLabels)
                          ChoiceChip(
                            key: ValueKey('$k-days-$value'),
                            label: Text(label),
                            selected: slot.days == value,
                            onSelected: (_) {
                              slot.days = value;
                              onChanged();
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (value, label) in [
                          (true, '全天'),
                          (false, '指定時間'),
                        ])
                          ChoiceChip(
                            key: ValueKey('$k-all-day-$value'),
                            label: Text(label),
                            selected: slot.allDay == value,
                            onSelected: (_) {
                              slot.allDay = value;
                              if (!value && slot.from.text.isEmpty) {
                                slot.from.text = '07:00';
                                slot.to.text = '20:00';
                              }
                              onChanged();
                            },
                          ),
                      ],
                    ),
                    if (!slot.allDay) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          for (final (field, label, controller) in [
                            ('from', '開始', slot.from),
                            ('to', '結束', slot.to),
                          ])
                            SizedBox(
                              width: 140,
                              child: TextFormField(
                                key: ValueKey('$k-$field'),
                                controller: controller,
                                keyboardType: TextInputType.datetime,
                                decoration: InputDecoration(
                                  labelText: label,
                                  hintText: field == 'from' ? '07:00' : '20:00',
                                  helperText: field == 'to'
                                      ? '比開始早表示到隔日'
                                      : null,
                                  helperMaxLines: 2,
                                  errorMaxLines: 3,
                                ),
                                autovalidateMode:
                                    AutovalidateMode.onUserInteraction,
                                validator: (v) =>
                                    _time(v) ??
                                    (field == 'to' &&
                                            v?.trim() == slot.from.text.trim()
                                        ? '結束和開始不能相同'
                                        : null),
                                onChanged: (_) => onChanged(),
                              ),
                            ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    FormField<Set<SlotVehicle>>(
                      validator: (_) =>
                          slot.vehicles.isEmpty ? '請選這段時間可停的車種，或刪除這個時段' : null,
                      builder: (state) => Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '這段時間可停',
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (value, label) in _slotVehicles)
                                FilterChip(
                                  key: ValueKey('$k-vehicle-${value.name}'),
                                  label: Text(label),
                                  selected: slot.vehicles.contains(value),
                                  onSelected: (on) {
                                    slot.vehicles = {
                                      ...slot.vehicles.where((v) => v != value),
                                      if (on) value,
                                    };
                                    state.didChange(slot.vehicles);
                                    onChanged();
                                  },
                                ),
                            ],
                          ),
                          if (state.errorText case final error?)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                error,
                                style: TextStyle(color: colors.error),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

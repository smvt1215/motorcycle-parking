import 'package:material_ui/material_ui.dart';

import '../../models/condition_text.dart' show limitText;
import '../../ui/option_pill.dart';
import '../../models/parking.dart';
import '../../models/fee.dart' show FeeWords;
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';

export '../../models/condition_text.dart'
    show conditionHeadline, conditionSummary, limitText;

/// The limits a rider may add to a kind beyond its own (C6 canvas AppForm
/// 「還有其他限制嗎？」): a motorcycle bay's sign may add a time limit. Each
/// stays one the contract and the legacy space type agree on (§1.3); 電動
/// only is its own kind (充電格, #188).
Set<LimitKind> extraLimits(SpaceKind kind) => switch (kind) {
  SpaceKind.motorcycle ||
  SpaceKind.scooterHeavy ||
  SpaceKind.ev => {LimitKind.timeLimit},
  _ => const {},
};

/// Whether the follow-ups ask 收費格還是免費格 for [kind]: every painted kind.
bool asksCharge(SpaceKind kind) => kind != SpaceKind.offStreet;

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

/// What a rider adds to the bay kind they picked (design §8.4, C5; C6
/// canvas AppForm): whether it charges, the limits it adds, how long a
/// time limit allows, and when a 汽機車共用 bay takes which vehicles. The
/// kind decides the rest.
class ConditionDraft {
  ConditionDraft() : loadedKind = null;

  /// The rider's values from a stored [condition] of a bay of [type].
  ConditionDraft.of(ParkingCondition? condition, SpaceType type)
    : loadedKind = SpaceKind.of(type, condition) {
    final c = condition ?? conditionOf(type);
    if (c == null) return;
    charge = c.charge;
    for (final l in c.limits) {
      if (extraLimits(loadedKind!).contains(l.kind)) extras.add(l.kind);
      if (l.kind == LimitKind.timeLimit) {
        final first = l.timePeriods.firstOrNull;
        if (first?.maxMinutes case final m?) maxMinutes.text = '$m';
        if (first?.extensions case final n?) extensions.text = '$n';
      }
    }
    _loadedTimes = (maxMinutes.text, extensions.text);
    slots.addAll(c.schedule.map(SlotDraft.of));
    loaded = c;
  }

  /// The stored condition: what the form does not show stays as stored
  /// while the kind does.
  ParkingCondition? loaded;

  /// The kind the stored condition came with.
  final SpaceKind? loadedKind;

  /// The charge picked, or the stored one until the rider picks.
  Charge? charge;

  /// Whether the rider picked [charge] in the form.
  bool chargePicked = false;

  /// The charge a bay of [kind] is sent with: the rider's pick, else the
  /// stored one while the bay stays the kind it was, or another toll-or-free
  /// motorcycle kind (一般機車格 ↔ 普大共用格: the same painted bays).
  Charge? chargeFor(SpaceKind kind) =>
      chargePicked ||
          loadedKind == null ||
          kind == loadedKind ||
          (kind.asksCharge && loadedKind!.asksCharge)
      ? charge
      : null;

  /// The limits ticked under 還有其他限制嗎？, kept across kinds; only those
  /// [extraLimits] offers for the kind are sent.
  final extras = <LimitKind>{};
  final maxMinutes = TextEditingController();

  /// 可以延長幾次 (#188 layer 2); 0 is 不能延長.
  final extensions = TextEditingController(text: '0');

  /// The two fields as the stored time limit filled them: while they read
  /// so, the stored limit is sent as it was, whatever its shape.
  (String, String)? _loadedTimes;
  final slots = <SlotDraft>[];

  void dispose() {
    maxMinutes.dispose();
    extensions.dispose();
    for (final s in slots) {
      s.dispose();
    }
  }

  /// Whether a bay of [kind] asks how many minutes it allows.
  bool asksMinutes(SpaceKind kind) =>
      extras.contains(LimitKind.timeLimit) &&
      extraLimits(kind).contains(LimitKind.timeLimit);

  /// Whether a bay of [kind] must say 收費 or 免費: a 一般機車格 or 普大共用格
  /// is stored as a toll or a free bay, unless a time limit makes it a 限時
  /// one (§1.3, `street_charge_optional_with`).
  bool chargeRequired(SpaceKind kind) => kind.asksCharge && !asksMinutes(kind);

  /// The condition a street bay of [kind] is sent with; null for a lot,
  /// whose zones carry theirs. While the kind stays the one loaded, every
  /// facet the form does not show stays as stored; only what the form
  /// edits changes. A basis is never sent: riders attach a notice as
  /// evidence (§1.4).
  ParkingCondition? conditionFor(SpaceKind kind) {
    final base = conditionOf(kind.baseType);
    if (base == null) return null;
    final same = kind == loadedKind;
    final from = same ? loaded ?? base : base;
    final minutes = int.tryParse(maxMinutes.text.trim());
    final times = int.tryParse(extensions.text.trim());
    // A time limit is sent with its period (#188 layer 2): all day, the
    // minutes and the extensions asked here. A stored one the rider left as
    // it was stays whole (its other periods too).
    final stored = same
        ? from.limits.where((l) => l.kind == LimitKind.timeLimit).firstOrNull
        : null;
    final timeLimit =
        stored != null && _loadedTimes == (maxMinutes.text, extensions.text)
        ? stored
        : minutes == null
        ? const ParkingLimit(LimitKind.timeLimit)
        : ParkingLimit(
            LimitKind.timeLimit,
            periods: [
              LimitPeriod(days: 'all', maxMinutes: minutes, extensions: times),
            ],
          );
    final (use, share) = switch (kind) {
      SpaceKind.scooterHeavy => (BayUse.share, ShareKind.scooterHeavy),
      SpaceKind.motorcycle => (BayUse.usual, null),
      _ => (from.use, from.share),
    };
    final offered = extraLimits(kind);
    return ParkingCondition(
      // A stored 身障 car bay stays a car bay (身障格 counts both, #188).
      bay: from.bay,
      use: use,
      share: share,
      charge: chargeFor(kind),
      limits: [
        for (final k in LimitKind.values)
          if (base.hasLimit(k) || (offered.contains(k) && extras.contains(k)))
            k == LimitKind.timeLimit
                ? timeLimit
                : base.limits.where((l) => l.kind == k).firstOrNull ??
                      ParkingLimit(k)
          // A stored limit the form cannot show stays as it is.
          else if (same && !offered.contains(k) && from.hasLimit(k))
            from.limits.firstWhere((l) => l.kind == k),
      ]..sort((a, b) => _order(from, a).compareTo(_order(from, b))),
      schedule: kind == SpaceKind.carMotorcycle || same
          ? [for (final s in slots) ?s.slot]
          : const [],
    );
  }

  /// A limit's place: where the stored condition had it, so an untouched
  /// condition compares equal whatever order it was stored in; new ones
  /// after, in [LimitKind] order.
  static int _order(ParkingCondition from, ParkingLimit l) {
    final i = from.limits.indexWhere((x) => x.kind == l.kind);
    return i < 0 ? from.limits.length + l.kind.index : i;
  }

  /// The legacy space type a bay of [kind] is sent under: the one its
  /// condition converts to (§1.3), which validate.ts checks.
  SpaceType typeFor(SpaceKind kind) {
    final c = conditionFor(kind);
    return (c == null ? null : legacySpaceType(c, offStreet: false)) ??
        switch (kind) {
          SpaceKind.motorcycle || SpaceKind.scooterHeavy =>
            chargeFor(kind) == Charge.free
                ? SpaceType.freeMotorcycle
                : SpaceType.paidMotorcycle,
          _ => kind.baseType,
        };
  }

  /// What the folded 格位 section says: the kind and what was added.
  String summary(SpaceKind kind) {
    final c = conditionFor(kind);
    return [
      kind.label,
      if (asksCharge(kind) && c?.charge != null)
        c!.charge == Charge.toll ? '收費' : '免費',
      for (final l in c?.limits ?? const <ParkingLimit>[])
        if (l.kind == LimitKind.timeLimit || l.kind == LimitKind.noParking)
          limitText(l),
    ].join('・');
  }
}

/// What the form asks about the bay kind just picked, indented under it
/// (C6 canvas AppForm): 收費格還是免費格, how long a 限時 bay allows, the
/// limits it adds, and a 汽機共用 bay's periods. [holdHint] is a note that
/// the report will wait for review.
class ConditionFields extends StatelessWidget {
  const ConditionFields({
    super.key,
    required this.kind,
    required this.draft,
    required this.onChanged,
    this.holdHint,
  });
  final SpaceKind kind;
  final ConditionDraft draft;
  final VoidCallback onChanged;
  final String? holdHint;

  static const maxSlots = scheduleMaxEntries;

  @override
  Widget build(BuildContext context) {
    if (kind == SpaceKind.offStreet) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final offered = extraLimits(kind);
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    Widget minutes() => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 14), child: Text('最多停')),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: TextFormField(
              key: const ValueKey('condition-max-minutes'),
              controller: draft.maxMinutes,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              decoration: const InputDecoration(
                hintText: '20',
                errorMaxLines: 3,
                isDense: true,
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              // A time limit is written with its minutes (#188 layer 2).
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                return n == null || n < 1 || n > 1440 ? '填 1 到 1440' : null;
              },
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 8),
          const Padding(padding: EdgeInsets.only(top: 14), child: Text('分鐘')),
        ],
      ),
    );
    Widget extensionTimes() => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 14), child: Text('可以延長')),
          const SizedBox(width: 8),
          SizedBox(
            width: 72,
            child: TextFormField(
              key: const ValueKey('condition-extensions'),
              controller: draft.extensions,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.end,
              decoration: const InputDecoration(
                errorMaxLines: 3,
                isDense: true,
              ),
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '');
                return n == null || n < 0 || n > 10 ? '填 0 到 10' : null;
              },
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text('次（0＝不能延長）', style: muted),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (asksCharge(kind))
          FormField<Charge?>(
            // A 一般機車格 or 普大共用格 is stored as toll or free, so it
            // must say (unless it is time limited).
            validator: (_) =>
                draft.chargeRequired(kind) && draft.chargeFor(kind) == null
                ? '請選收費格或免費格'
                : null,
            builder: (state) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('收費格還是免費格？', style: muted),
                  const SizedBox(height: 4),
                  OptionPills<Charge?>(
                    key: const ValueKey('condition-charge'),
                    values: [
                      if (!kind.asksCharge) (null, '未確認'),
                      (Charge.toll, '收費格'),
                      (Charge.free, '免費格'),
                    ],
                    selected: draft.chargeFor(kind),
                    keyOf: (v) => 'condition-charge-${v?.name ?? 'unknown'}',
                    onSelect: (v) {
                      draft
                        ..charge = v
                        ..chargePicked = true;
                      state.didChange(v);
                      onChanged();
                    },
                  ),
                  if (state.errorText case final error?)
                    Text(
                      error,
                      style: TextStyle(fontSize: 13, color: colors.error),
                    ),
                ],
              ),
            ),
          ),
        if (offered.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('還有其他限制嗎？（可複選）', style: muted),
          if (offered.contains(LimitKind.timeLimit)) ...[
            OptionCheck(
              key: const ValueKey('condition-limit-time_limit'),
              label: '限時停車',
              value: draft.extras.contains(LimitKind.timeLimit),
              onChanged: (on) {
                on
                    ? draft.extras.add(LimitKind.timeLimit)
                    : draft.extras.remove(LimitKind.timeLimit);
                onChanged();
              },
            ),
            if (draft.extras.contains(LimitKind.timeLimit))
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 44),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [minutes(), extensionTimes()],
                ),
              ),
          ],
        ],
        if (holdHint case final hint?)
          _Note(key: const ValueKey('condition-hold'), text: hint),
        if (kind == SpaceKind.carMotorcycle) ...[
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
                          OptionPill(
                            key: ValueKey('$k-days-picked'),
                            label: FeeWords.dayLabel(FeeWords.dayMask(picked)),
                            selected: true,
                            onTap: () {},
                          ),
                        for (final (value, label) in _dayLabels)
                          OptionPill(
                            key: ValueKey('$k-days-$value'),
                            label: label,
                            selected: slot.days == value,
                            onTap: () {
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
                          OptionPill(
                            key: ValueKey('$k-all-day-$value'),
                            label: label,
                            selected: slot.allDay == value,
                            onTap: () {
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
                          for (final (value, label) in _slotVehicles)
                            OptionCheck(
                              key: ValueKey('$k-vehicle-${value.name}'),
                              label: label,
                              value: slot.vehicles.contains(value),
                              onChanged: (on) {
                                slot.vehicles = {
                                  ...slot.vehicles.where((v) => v != value),
                                  if (on) value,
                                };
                                state.didChange(slot.vehicles);
                                onChanged();
                              },
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

import 'package:material_ui/material_ui.dart';

import '../../ui/option_pill.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';

export '../../models/condition_text.dart'
    show conditionHeadline, conditionSummary;

/// Whether the follow-ups ask 收費嗎 for [kind]: every painted kind does.
bool asksCharge(SpaceKind kind) => kind != SpaceKind.offStreet;

/// One period while it is being reported: a 汽機共用 slot (§1.2 schedule)
/// or a 時段性禁停 period (decision 62), which has no vehicles.
class SlotDraft {
  SlotDraft({this.allDay = true});

  SlotDraft.of(ScheduleSlot slot)
    : days = slot.days,
      allDay = slot.from == null && slot.to == null,
      vehicles = slot.vehicles.toSet() {
    from.text = slot.from ?? '';
    to.text = slot.to ?? '';
  }

  SlotDraft.ofPeriod(TimePeriod period)
    : days = period.days,
      allDay = period.from == null && period.to == null {
    from.text = period.from ?? '';
    to.text = period.to ?? '';
  }

  /// `all`, `weekday` or `holiday`, or weekdays one by one (`["mon"]`).
  Object days = 'all';
  bool allDay;
  final from = TextEditingController(), to = TextEditingController();
  Set<SlotVehicle> vehicles = {};

  void dispose() {
    from.dispose();
    to.dispose();
  }

  /// The days and times as the contract takes them; null until complete.
  ({Object days, String? from, String? to})? get _times {
    final f = from.text.trim(), t = to.text.trim();
    final time = RegExp(timePattern);
    if (days is List && (days as List).isEmpty) return null;
    if (!allDay && (!time.hasMatch(f) || !time.hasMatch(t) || f == t)) {
      return null;
    }
    return (days: days, from: allDay ? null : f, to: allDay ? null : t);
  }

  /// The slot as the contract takes it; null until it is complete.
  ScheduleSlot? get slot {
    final t = _times;
    if (t == null || vehicles.isEmpty) return null;
    return ScheduleSlot(
      days: t.days,
      from: t.from,
      to: t.to,
      vehicles: [
        for (final v in SlotVehicle.values)
          if (vehicles.contains(v)) v,
      ],
    );
  }

  /// The 禁停 period as the contract takes it; null until it is complete.
  TimePeriod? get period {
    final t = _times;
    return t == null ? null : TimePeriod(days: t.days, from: t.from, to: t.to);
  }
}

/// What a rider adds to the bay kind they picked (decision 62; C6 canvas
/// SpaceTaxonomy): 誰共用 for 共用格, 收費嗎, a 汽機共用 bay's 共用與專用時段,
/// and the added conditions 限時 and 時段性禁停. The kind decides the rest.
class ConditionDraft {
  ConditionDraft() : loadedKind = null;

  /// The rider's values from a stored [condition] of a bay of [type].
  ConditionDraft.of(ParkingCondition? condition, SpaceType type)
    : loadedKind = SpaceKind.of(type, condition) {
    _load(condition ?? conditionOf(type));
  }

  /// The values of a lot zone's stored [condition] (decision 62: zones use
  /// the same kinds); its kind is null while its bay is unconfirmed.
  ConditionDraft.zone(ParkingCondition? condition)
    : loadedKind = zoneKindOf(condition) {
    _load(condition);
  }

  /// The kind a zone's condition reads as; null when it names no bay, no
  /// share and no reserved use.
  static SpaceKind? zoneKindOf(ParkingCondition? c) =>
      c == null ||
          (c.bay == null &&
              c.share == null &&
              !c.hasLimit(LimitKind.evOnly) &&
              !c.hasLimit(LimitKind.specialVehicle))
      ? null
      : SpaceKind.of(SpaceType.paidMotorcycle, c);

  void _load(ParkingCondition? c) {
    if (c == null) return;
    share = c.share;
    _charges[loadedKind] = c.charge;
    for (final l in c.limits) {
      if (l.kind == LimitKind.timeLimit) {
        timed = true;
        if (l.maxMinutes != null) maxMinutes.text = '${l.maxMinutes}';
      }
      if (l.kind == LimitKind.noParking) {
        banned = true;
        bans.addAll(l.periods.map(SlotDraft.ofPeriod));
      }
    }
    slots.addAll(c.schedule.map(SlotDraft.of));
    loaded = c;
  }

  /// A lot zone's condition for [kind] (null: bay unconfirmed): what the
  /// form builds, with [current]'s `allow` and notice kept. A heavy bay
  /// never opens to scooters.
  ParkingCondition zoneConditionFor(SpaceKind? kind, ParkingCondition current) {
    final built = kind == null
        ? ParkingCondition(
            // The form asks 收費嗎 as for a plain motorcycle bay.
            charge: chargeFor(SpaceKind.motorcycle),
            limits: [
              for (final l in _added.values) l,
              for (final l in current.limits)
                if (!addedLimits.contains(l.kind)) l,
            ],
          )
        : conditionFor(kind)!;
    final allow = current.allow;
    return ParkingCondition(
      bay: built.bay,
      use: built.use,
      share: built.share,
      charge: built.charge,
      limits: built.limits,
      schedule: built.schedule,
      basis: current.basis,
      allow: built.bay == Bay.heavy && allow?.scooter == true
          ? ZoneAllow(scooter: false, heavy: allow!.heavy)
          : allow,
    );
  }

  /// The added conditions as ticked, in [LimitKind] order.
  Map<LimitKind, ParkingLimit> get _added {
    final minutes = int.tryParse(maxMinutes.text.trim());
    final periods = [for (final b in bans) ?b.period];
    return {
      if (timed)
        LimitKind.timeLimit: ParkingLimit(
          LimitKind.timeLimit,
          maxMinutes: minutes,
        ),
      if (banned && periods.isNotEmpty)
        LimitKind.noParking: ParkingLimit(
          LimitKind.noParking,
          periods: periods,
        ),
    };
  }

  /// The stored condition: what the form does not show stays as stored
  /// while the kind does.
  ParkingCondition? loaded;

  /// The kind the stored condition came with.
  final SpaceKind? loadedKind;

  /// 共用格: who shares it; null until picked.
  ShareKind? share;

  /// 收費嗎 as answered for each kind: a charge belongs to the bay it was
  /// answered for, so another kind asks again; null keys the answer for
  /// every kind not answered on its own (the [charge] setter).
  final _charges = <SpaceKind?, Charge?>{};

  /// The answer for any kind not answered on its own.
  set charge(Charge? value) => _charges[null] = value;

  /// 收費嗎 for [kind]: its own answer, else the stored one (for the kind
  /// loaded), else the shared one.
  Charge? chargeFor(SpaceKind? kind) =>
      _charges.containsKey(kind) ? _charges[kind] : _charges[null];

  void setCharge(SpaceKind? kind, Charge? value) => _charges[kind] = value;

  /// 限時停車, and how many minutes (empty: the sign does not say).
  bool timed = false;
  final maxMinutes = TextEditingController();

  /// 時段性禁停 and its periods.
  bool banned = false;
  final bans = <SlotDraft>[];

  /// A 汽機共用 bay's periods.
  final slots = <SlotDraft>[];

  void dispose() {
    maxMinutes.dispose();
    for (final s in [...slots, ...bans]) {
      s.dispose();
    }
  }

  /// Whether a bay of [kind] has periods: 汽車＆機車 only (decision 64).
  bool asksSlots(SpaceKind kind) =>
      kind == SpaceKind.shared && share == ShareKind.carMotorcycle;

  /// Whether 收費嗎 must be answered: a motorcycle bay is stored as a toll
  /// or a free one unless a time limit decides its space type (§1.3).
  bool needsCharge(SpaceKind kind) =>
      !timed &&
      (kind == SpaceKind.motorcycle ||
          (kind == SpaceKind.shared && share == ShareKind.scooterHeavy));

  /// The condition a street bay of [kind] is sent with; null for a lot,
  /// whose zones carry theirs. While the kind stays the one loaded, every
  /// facet the form does not show stays as stored. A basis is never sent:
  /// riders attach a notice as evidence (§1.4).
  ParkingCondition? conditionFor(SpaceKind kind) {
    if (kind == SpaceKind.offStreet) return null;
    final base = conditionOf(kind.baseType)!;
    final same = kind == loadedKind;
    final from = same ? loaded ?? base : base;
    final shareKind = kind == SpaceKind.shared
        ? share ?? ShareKind.carMotorcycle
        : null;
    final added = _added;
    // A reserved bay (充電, 身障) keeps the bay, use and share it was
    // stored with: the form does not ask them.
    final reserved =
        kind == SpaceKind.evMotorcycle || kind == SpaceKind.disabledMotorcycle;
    return ParkingCondition(
      bay: reserved ? from.bay : shareKind?.bay ?? base.bay,
      use: reserved
          ? from.use
          : shareKind != null
          ? BayUse.share
          : BayUse.usual,
      share: reserved ? from.share : shareKind,
      charge: chargeFor(kind),
      limits: [
        for (final k in LimitKind.values)
          if (base.hasLimit(k))
            from.limits.where((l) => l.kind == k).firstOrNull ??
                base.limits.firstWhere((l) => l.kind == k)
          else if (added[k] case final limit?)
            limit
          // A stored limit the form cannot show stays as it is.
          else if (same && !addedLimits.contains(k) && from.hasLimit(k))
            from.limits.firstWhere((l) => l.kind == k),
      ]..sort((a, b) => _order(from, a).compareTo(_order(from, b))),
      schedule: shareKind == ShareKind.carMotorcycle
          ? [for (final s in slots) ?s.slot]
          // 普大共用 is shared all the time (decision 64); other kinds
          // keep the periods stored with them.
          : same && shareKind == null
          ? from.schedule
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
        kind.baseType;
  }

  /// What the folded 格位 section says: the kind and what was added.
  String summary(SpaceKind kind) {
    final c = conditionFor(kind);
    return [
      kind.label,
      if (kind == SpaceKind.shared && share != null) share!.label,
      if (c?.charge != null) c!.charge == Charge.toll ? '收費' : '免費',
      for (final l in c?.limits ?? const <ParkingLimit>[])
        if (l.kind == LimitKind.timeLimit)
          l.maxMinutes == null ? '限時' : '限時 ${l.maxMinutes} 分鐘'
        else if (l.kind == LimitKind.noParking)
          '時段性禁停',
    ].join('・');
  }
}

/// What the form asks about the bay kind just picked, indented under it
/// (C6 canvas SpaceTaxonomy): 誰共用 (共用格), 收費嗎, a 汽機共用 bay's
/// 共用與專用時段, and the added conditions. [holdHint] is a note that the
/// report will wait for review.
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
  static const maxBans = limitPeriodsMaxEntries;

  @override
  Widget build(BuildContext context) {
    if (kind == SpaceKind.offStreet) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    Widget error(FormFieldState<Object?> state) => state.errorText == null
        ? const SizedBox.shrink()
        : Text(
            state.errorText!,
            style: TextStyle(fontSize: 13, color: colors.error),
          );
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
              validator: (v) {
                final text = v?.trim() ?? '';
                if (text.isEmpty) return null;
                final n = int.tryParse(text);
                return n == null || n < 1 || n > 1440 ? '填 1 到 1440' : null;
              },
              onChanged: (_) => onChanged(),
            ),
          ),
          const SizedBox(width: 8),
          const Padding(padding: EdgeInsets.only(top: 14), child: Text('分鐘')),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text('牌面沒寫就留空', style: muted),
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (kind == SpaceKind.shared)
          FormField<ShareKind?>(
            validator: (_) => draft.share == null ? '請選誰共用' : null,
            builder: (state) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('誰共用？', style: muted),
                  const SizedBox(height: 4),
                  OptionPills<ShareKind?>(
                    key: const ValueKey('condition-share'),
                    values: [for (final s in ShareKind.values) (s, s.label)],
                    selected: draft.share,
                    keyOf: (v) => 'condition-share-${v?.wire}',
                    onSelect: (v) {
                      draft.share = v;
                      state.didChange(v);
                      onChanged();
                    },
                  ),
                  if (draft.share == ShareKind.scooterHeavy)
                    Text('普通機車與大型重機全時段都能停', style: muted),
                  error(state),
                ],
              ),
            ),
          ),
        FormField<Charge?>(
          validator: (_) =>
              draft.needsCharge(kind) && draft.chargeFor(kind) == null
              ? '機車格請選收費或免費'
              : null,
          builder: (state) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('收費嗎？', style: muted),
                const SizedBox(height: 4),
                OptionPills<Charge?>(
                  key: const ValueKey('condition-charge'),
                  values: const [
                    (null, '未確認'),
                    (Charge.toll, '收費'),
                    (Charge.free, '免費'),
                  ],
                  selected: draft.chargeFor(kind),
                  keyOf: (v) => 'condition-charge-${v?.name ?? 'unknown'}',
                  onSelect: (v) {
                    draft.setCharge(kind, v);
                    state.didChange(v);
                    onChanged();
                  },
                ),
                error(state),
              ],
            ),
          ),
        ),
        if (draft.asksSlots(kind)) ...[
          const SizedBox(height: 8),
          Text('共用時段與專用時段', style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 4),
          Text(
            '照告示牌填每段時間：汽機車共用，或汽車專用、機車專用；沒填的時間 App 會顯示未確認。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          for (final (i, slot) in draft.slots.indexed)
            _PeriodCard(
              key: ObjectKey(slot),
              keyPrefix: 'condition-slot-$i',
              title: '時段 ${i + 1}',
              slot: slot,
              ban: false,
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
        const SizedBox(height: 4),
        Text('加註條件（可複選）', style: muted),
        OptionCheck(
          key: const ValueKey('condition-limit-time_limit'),
          label: '限時停車',
          value: draft.timed,
          onChanged: (on) {
            draft.timed = on;
            onChanged();
          },
        ),
        if (draft.timed)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 44),
            child: minutes(),
          ),
        OptionCheck(
          key: const ValueKey('condition-limit-no_parking'),
          label: '時段性禁停',
          value: draft.banned,
          onChanged: (on) {
            draft.banned = on;
            if (on && draft.bans.isEmpty) {
              draft.bans.add(SlotDraft(allDay: false));
            }
            onChanged();
          },
        ),
        if (draft.banned)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 44),
            child: FormField<int>(
              validator: (_) => draft.bans.any((b) => b.period != null)
                  ? null
                  : '請填禁停的時間，或取消勾選時段性禁停',
              builder: (state) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, ban) in draft.bans.indexed)
                    _PeriodCard(
                      key: ObjectKey(ban),
                      keyPrefix: 'condition-ban-$i',
                      title: '禁停 ${i + 1}',
                      slot: ban,
                      ban: true,
                      onChanged: () {
                        state.didChange(i);
                        onChanged();
                      },
                      onRemove: draft.bans.length == 1
                          ? null
                          : () {
                              draft.bans.remove(ban);
                              ban.dispose();
                              onChanged();
                            },
                    ),
                  Text('選「平日」＝假日（含國定假日）除外。', style: muted),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('condition-ban-add'),
                      onPressed: draft.bans.length >= maxBans
                          ? null
                          : () {
                              draft.bans.add(SlotDraft(allDay: false));
                              onChanged();
                            },
                      icon: const Icon(Icons.add),
                      label: Text(
                        draft.bans.length >= maxBans
                            ? '最多 $maxBans 段禁停時間'
                            : '加一段禁停時間',
                      ),
                    ),
                  ),
                  error(state),
                ],
              ),
            ),
          ),
        if (holdHint case final hint?)
          _Note(key: const ValueKey('condition-hold'), text: hint),
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
const _weekdayLabels = [
  ('mon', '一'),
  ('tue', '二'),
  ('wed', '三'),
  ('thu', '四'),
  ('fri', '五'),
  ('sat', '六'),
  ('sun', '日'),
];

/// Who a 汽機共用 period is for (decision 62): both, or one side only.
const _shareUses = [
  ('both', '汽機車共用', {SlotVehicle.scooter, SlotVehicle.heavy, SlotVehicle.car}),
  ('car', '汽車專用', {SlotVehicle.car}),
  ('bike', '機車專用', {SlotVehicle.scooter, SlotVehicle.heavy}),
];

/// One period: its days (每天、平日、假日 or 指定 weekdays), all day or a
/// time, and — for a 汽機共用 slot — who parks then. A 禁停 period has no
/// vehicles.
class _PeriodCard extends StatelessWidget {
  const _PeriodCard({
    super.key,
    required this.keyPrefix,
    required this.title,
    required this.slot,
    required this.ban,
    required this.onChanged,
    required this.onRemove,
  });
  final String keyPrefix;
  final String title;
  final SlotDraft slot;
  final bool ban;
  final VoidCallback onChanged;

  /// Null when the period cannot be removed (the only 禁停 period).
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final k = keyPrefix;
    final picked = slot.days is List;
    final use = _shareUses
        .where(
          (u) =>
              u.$3.length == slot.vehicles.length &&
              u.$3.containsAll(slot.vehicles),
        )
        .firstOrNull;
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
                      title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  if (onRemove != null)
                    IconButton(
                      key: ValueKey('$k-remove'),
                      tooltip: '刪除$title',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: onRemove,
                    )
                  else
                    const SizedBox(height: 48),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '哪些天',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
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
                        OptionPill(
                          key: ValueKey('$k-days-picked'),
                          label: '指定',
                          selected: picked,
                          onTap: () {
                            if (!picked) slot.days = <String>[];
                            onChanged();
                          },
                        ),
                      ],
                    ),
                    if (picked)
                      FormField<Object>(
                        validator: (_) =>
                            (slot.days as List).isEmpty ? '請選星期幾' : null,
                        builder: (state) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final (value, label) in _weekdayLabels)
                                  OptionPill(
                                    key: ValueKey('$k-weekday-$value'),
                                    label: label,
                                    tooltip: '週$label',
                                    selected: (slot.days as List).contains(
                                      value,
                                    ),
                                    onTap: () {
                                      final days = slot.days as List;
                                      slot.days = [
                                        for (final (w, _) in _weekdayLabels)
                                          if (w == value
                                              ? !days.contains(w)
                                              : days.contains(w))
                                            w,
                                      ];
                                      state.didChange(slot.days);
                                      onChanged();
                                    },
                                  ),
                              ],
                            ),
                            if (state.errorText case final error?)
                              Text(
                                error,
                                style: TextStyle(color: colors.error),
                              ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
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
                              if (!value && !ban && slot.from.text.isEmpty) {
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
                            ('from', ban ? '禁停開始' : '開始', slot.from),
                            ('to', ban ? '禁停結束' : '結束', slot.to),
                          ])
                            SizedBox(
                              width: 140,
                              child: TextFormField(
                                key: ValueKey('$k-$field'),
                                controller: controller,
                                keyboardType: TextInputType.datetime,
                                decoration: InputDecoration(
                                  labelText: label,
                                  hintText: field == 'from'
                                      ? '07:00'
                                      : (ban ? '09:00' : '20:00'),
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
                    if (!ban) ...[
                      const SizedBox(height: 8),
                      FormField<Set<SlotVehicle>>(
                        validator: (_) => slot.vehicles.isEmpty
                            ? '請選這段時間是共用還是專用，或刪除這個時段'
                            : null,
                        builder: (state) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '這段時間',
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                // Vehicles stored in another mix stay as
                                // they are until the rider picks.
                                if (use == null && slot.vehicles.isNotEmpty)
                                  OptionPill(
                                    key: ValueKey('$k-use-stored'),
                                    label: _storedVehicles(slot.vehicles),
                                    selected: true,
                                    onTap: () {},
                                  ),
                                for (final (value, label, vehicles)
                                    in _shareUses)
                                  OptionPill(
                                    key: ValueKey('$k-use-$value'),
                                    label: label,
                                    selected: use?.$1 == value,
                                    onTap: () {
                                      slot.vehicles = {...vehicles};
                                      state.didChange(slot.vehicles);
                                      onChanged();
                                    },
                                  ),
                              ],
                            ),
                            if (state.errorText case final error?)
                              Text(
                                error,
                                style: TextStyle(color: colors.error),
                              ),
                          ],
                        ),
                      ),
                    ],
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

String _storedVehicles(Set<SlotVehicle> vehicles) => [
  for (final v in SlotVehicle.values)
    if (vehicles.contains(v))
      switch (v) {
        SlotVehicle.scooter => '普通機車',
        SlotVehicle.heavy => '大型重機',
        SlotVehicle.car => '汽車',
      },
].join('、');

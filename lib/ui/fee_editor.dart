import 'package:material_ui/material_ui.dart';

import '../models/fee.dart';
import '../models/parking_condition.dart'
    show feeContract, scheduleWeekdays, timePattern;
import 'fee_board.dart';
import 'vehicle_marks.dart';

export 'vehicle_marks.dart' show FeeVehicle;

/// The editor shows the vehicle list, the fields and the preview side by
/// side from this width (design §8.4, wide screens); below it the vehicles
/// stack and one is open at a time (§7 item 9).
const feeEditorWideWidth = 840.0;

Rate? _rateOf(Fee fee, FeeVehicle v) => switch (v) {
  FeeVehicle.scooter => fee.scooter,
  FeeVehicle.heavy => fee.heavy,
  FeeVehicle.car => fee.car,
};

Fee _withRate(Fee fee, FeeVehicle v, Rate? rate) => switch (v) {
  FeeVehicle.scooter => fee.copyWith(scooter: () => rate),
  FeeVehicle.heavy => fee.copyWith(heavy: () => rate),
  FeeVehicle.car => fee.copyWith(car: () => rate),
};

/// Whether [rate] has every amount, in range, as the column takes it.
bool _rateValid(Rate rate, FeeVehicle v) => validRate(rate.toJson(), v.wire);

/// [fee] without the vehicles still being filled in, so a draft never
/// reads back as 0 元.
Fee _known(Fee fee) {
  Rate? keep(FeeVehicle v) {
    final rate = _rateOf(fee, v);
    return rate != null && _rateValid(rate, v) ? rate : null;
  }

  return Fee(
    scooter: keep(FeeVehicle.scooter),
    heavy: keep(FeeVehicle.heavy),
    car: keep(FeeVehicle.car),
  );
}

/// One vehicle's collapsed summary: the sentence riders read, or why there
/// is none yet; the flag marks one still being filled in.
(String, bool) _summary(Fee fee, FeeVehicle v) {
  final rate = _rateOf(fee, v);
  if (rate == null) return ('未確認', false);
  if (!_rateValid(rate, v)) return ('還沒填完', true);
  return (_known(fee).textOf(v.wire) ?? '費率未提供', false);
}

/// The vehicle a heavy follow names when its rate is not known (design
/// §8.6): such a follow would read 費率未提供, so it is not stored. The check
/// lives on [Fee.followGap] so forms outside the editor's [Form] block it too.
String? _followGap(Fee fee) =>
    _known(fee).copyWith(heavy: () => fee.heavy).followGap;

/// Whether a heavy bike has a vehicle to follow: one whose rate is known.
bool _canFollow(Fee fee) {
  final known = _known(fee);
  return known.textOf('scooter') != null || known.textOf('car') != null;
}

/// Edits a [Fee] per vehicle (普通機車, 大型重機, 汽車), shared by the app's
/// report forms and the admin site (design §2.5, §8.4–8.5). One vehicle is
/// open at a time; the others collapse to the sentence riders read. The
/// fields join the enclosing [Form], and a vehicle chosen but not filled in
/// blocks it too. Every choice starts unconfirmed.
class FeeEditor extends StatefulWidget {
  const FeeEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.showPreview = true,
    this.initialVehicle,
  });
  final Fee value;
  final ValueChanged<Fee> onChanged;

  /// A whole-fee error from the caller's own check, shown under the preview.
  final String? errorText;

  /// Off when the caller shows the notice board itself.
  final bool showPreview;

  /// The vehicle open at first: the rider's in the app; by default the
  /// first one with a rate.
  final FeeVehicle? initialVehicle;

  @override
  State<FeeEditor> createState() => _FeeEditorState();
}

class _FeeEditorState extends State<FeeEditor> {
  late FeeVehicle? open =
      widget.initialVehicle ??
      FeeVehicle.values
          .where((v) => _rateOf(widget.value, v) != null)
          .firstOrNull ??
      FeeVehicle.scooter;

  Fee get fee => widget.value;

  void setRate(FeeVehicle v, Rate? rate) =>
      widget.onChanged(_withRate(fee, v, rate));

  /// Vehicles chosen but not filled in, which the fields of a collapsed
  /// vehicle or period cannot flag themselves.
  String? _incomplete() {
    final bad = [
      for (final v in FeeVehicle.values)
        if (_rateOf(fee, v) case final rate? when !_rateValid(rate, v)) v.label,
    ];
    if (bad.isNotEmpty) return '${bad.join('、')}的費率還沒填完，請填好或改回「未確認」';
    return _followGap(fee);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= feeEditorWideWidth;
        final preview = widget.showPreview
            ? _Preview(fee: fee, first: open)
            : null;
        final trailing = [
          FormField<Fee>(
            key: const ValueKey('fee-complete'),
            validator: (_) => _incomplete(),
            builder: (state) => state.errorText == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      state.errorText!,
                      style: TextStyle(color: colors.error),
                    ),
                  ),
          ),
          if (widget.errorText case final error?) ...[
            const SizedBox(height: 8),
            Text(error, style: TextStyle(color: colors.error)),
          ],
        ];
        if (wide) {
          final current = open ?? FeeVehicle.scooter;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 220,
                    child: _VehicleList(
                      fee: fee,
                      selected: current,
                      onSelect: (v) => setState(() => open = v),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _Card(
                      child: _OpenVehicle(
                        vehicle: current,
                        fee: fee,
                        onChanged: (rate) => setRate(current, rate),
                      ),
                    ),
                  ),
                  if (preview != null) ...[
                    const SizedBox(width: 16),
                    SizedBox(width: 300, child: preview),
                  ],
                ],
              ),
              ...trailing,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, v) in FeeVehicle.values.indexed)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: i < FeeVehicle.values.length - 1
                            ? Border(
                                bottom: BorderSide(
                                  color: colors.outlineVariant,
                                ),
                              )
                            : null,
                      ),
                      child: v == open
                          ? _OpenVehicle(
                              vehicle: v,
                              fee: fee,
                              onChanged: (rate) => setRate(v, rate),
                              onCollapse: () => setState(() => open = null),
                            )
                          : _ClosedVehicle(
                              vehicle: v,
                              fee: fee,
                              onOpen: () => setState(() => open = v),
                            ),
                    ),
                ],
              ),
            ),
            if (preview != null) ...[const SizedBox(height: 14), preview],
            ...trailing,
          ],
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // A Material, so the list tiles and ink inside paint on the card.
    return Material(
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// A collapsed vehicle: its mark, name, the sentence riders read, 修改.
class _ClosedVehicle extends StatelessWidget {
  const _ClosedVehicle({
    required this.vehicle,
    required this.fee,
    required this.onOpen,
  });
  final FeeVehicle vehicle;
  final Fee fee;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (text, error) = _summary(fee, vehicle);
    return InkWell(
      key: ValueKey('fee-row-${vehicle.wire}'),
      onTap: onOpen,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          child: Row(
            children: [
              VehicleMark(vehicle),
              const SizedBox(width: 10),
              Text(
                vehicle.label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    color: error ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(
                onPressed: onOpen,
                child: Text('修改', semanticsLabel: '修改${vehicle.label}費率'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The open vehicle: its name, 收合 on phones, then its rate's fields.
class _OpenVehicle extends StatelessWidget {
  const _OpenVehicle({
    required this.vehicle,
    required this.fee,
    required this.onChanged,
    this.onCollapse,
  });
  final FeeVehicle vehicle;
  final Fee fee;
  final ValueChanged<Rate?> onChanged;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) => Padding(
    key: ValueKey('fee-open-${vehicle.wire}'),
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              VehicleMark(vehicle),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  vehicle.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onCollapse != null)
                TextButton(
                  onPressed: onCollapse,
                  child: Text('收合', semanticsLabel: '收合${vehicle.label}費率'),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        RateEditor(
          key: ValueKey('fee-${vehicle.wire}'),
          vehicle: vehicle,
          value: _rateOf(fee, vehicle),
          fee: fee,
          onChanged: onChanged,
        ),
      ],
    ),
  );
}

/// The vehicles in a column beside the fields on wide screens; the chosen
/// one is the one being edited.
class _VehicleList extends StatelessWidget {
  const _VehicleList({
    required this.fee,
    required this.selected,
    required this.onSelect,
  });
  final Fee fee;
  final FeeVehicle selected;
  final ValueChanged<FeeVehicle> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final v in FeeVehicle.values)
            Semantics(
              selected: v == selected,
              button: true,
              child: InkWell(
                key: ValueKey('fee-row-${v.wire}'),
                onTap: () => onSelect(v),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  color: v == selected ? colors.primaryContainer : null,
                  child: Row(
                    children: [
                      VehicleMark(v),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              v.label,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: v == selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: v == selected
                                    ? colors.onPrimaryContainer
                                    : null,
                              ),
                            ),
                            Text(
                              _summary(fee, v).$1,
                              style: TextStyle(
                                fontSize: 13,
                                color: _summary(fee, v).$2
                                    ? colors.error
                                    : v == selected
                                    ? colors.onPrimaryContainer
                                    : colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「App 會顯示」: the notice board riders will read, the editor's one
/// prominent element (design §8.4).
class _Preview extends StatelessWidget {
  const _Preview({required this.fee, required this.first});
  final Fee fee;
  final FeeVehicle? first;

  @override
  Widget build(BuildContext context) {
    final board = FeeBoardTheme.of(context);
    final pending = [
      for (final v in FeeVehicle.values)
        if (_rateOf(fee, v) case final rate? when !_rateValid(rate, v)) v.label,
    ];
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('fee-preview'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: board.paper,
          border: Border.all(color: board.ink, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'App 會顯示',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: board.accent,
              ),
            ),
            const SizedBox(height: 8),
            FeeBoard(fee: _known(fee), first: first, framed: false),
            if (pending.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                '${pending.join('、')}的金額填好後才會顯示',
                style: TextStyle(fontSize: 12, color: board.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A pill choice (canvas 收費方式): 40 px tall inside a 48 px target.
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;

  /// Null when the choice is not available now.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? colors.primaryContainer : colors.surface,
                border: Border.all(
                  color: selected ? colors.primary : colors.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  // As wide as its label; long labels wrap at 320 px.
                  child: Align(
                    widthFactor: 1,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w400,
                        color: selected
                            ? colors.onPrimaryContainer
                            : enabled
                            ? colors.onSurface
                            : colors.onSurface.withValues(alpha: .38),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled group of pills; [values] pairs each choice with its label.
class _Choices<T> extends StatelessWidget {
  const _Choices({
    required this.label,
    required this.values,
    required this.selected,
    required this.onSelect,
    required this.keyOf,
    this.disabled = const {},
  });
  final String label;
  final List<(T, String)> values;
  final T selected;
  final ValueChanged<T> onSelect;
  final String Function(T) keyOf;

  /// Choices shown but not available now.
  final Set<T> disabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _Legend(label),
      Wrap(
        spacing: 8,
        children: [
          for (final (value, text) in values)
            _Pill(
              key: ValueKey(keyOf(value)),
              label: text,
              selected: value == selected,
              onTap: disabled.contains(value) ? null : () => onSelect(value),
            ),
        ],
      ),
    ],
  );
}

class _Legend extends StatelessWidget {
  const _Legend(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// A three-way choice whose last answer is 未確認 (design §2.5): a radio
/// per answer, 未確認 chosen while nothing is known.
class _ThreeWay extends StatelessWidget {
  const _ThreeWay({
    required this.legend,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.keyPrefix,
  });
  final String legend;
  final List<(String, String)> options;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _Legend(legend),
      RadioGroup<String>(
        groupValue: value ?? 'unknown',
        onChanged: (v) => onChanged(v == 'unknown' ? null : v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (wire, text) in [...options, ('unknown', '未確認')])
              // A 48 px row, the whole of it a target (canvas: one radio
              // and its words per line).
              MergeSemantics(
                child: InkWell(
                  key: ValueKey('$keyPrefix-$wire'),
                  onTap: () => onChanged(wire == 'unknown' ? null : wire),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Row(
                      children: [
                        Radio<String>(value: wire),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            text,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// Fields side by side when there is room, stacked on phones.
class _FieldRow extends StatelessWidget {
  const _FieldRow(this.fields);
  final List<Widget> fields;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = 12.0;
      final wide = constraints.maxWidth >= 520;
      final width = wide
          ? (constraints.maxWidth - gap * (fields.length - 1)) / fields.length
          : constraints.maxWidth;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final field in fields) SizedBox(width: width, child: field),
        ],
      );
    },
  );
}

String _modeLabel(FeeMode? mode) => switch (mode) {
  null || FeeMode.posted => '未確認',
  FeeMode.free => '免費',
  FeeMode.hourly => '計時',
  FeeMode.perVisit => '計次',
  FeeMode.daily => '每日',
  FeeMode.byTime => '依時段不同',
  FeeMode.sameAsScooter || FeeMode.sameAsCar => '比照其他車種',
};

const _keep = Object();

/// [r] with the given values replaced; [_keep] leaves one as it is.
Rate _edit(
  Rate r, {
  FeeMode? mode,
  Object? amount = _keep,
  Object? perMinutes = _keep,
  Object? dailyCap = _keep,
  Object? maxMinutes = _keep,
  Object? unitMinutes = _keep,
  Object? freeMinutes = _keep,
  Object? capReset = _keep,
  Object? renew = _keep,
  Object? extension = _keep,
  Object? periods = _keep,
  Object? crossPeriod = _keep,
  Object? factorPct = _keep,
}) {
  T? pick<T>(Object? v, T? old) => identical(v, _keep) ? old : v as T?;
  return Rate(
    mode ?? r.mode,
    amount: pick(amount, r.amount),
    perMinutes: pick(perMinutes, r.perMinutes),
    dailyCap: pick(dailyCap, r.dailyCap),
    maxMinutes: pick(maxMinutes, r.maxMinutes),
    unitMinutes: pick(unitMinutes, r.unitMinutes),
    freeMinutes: pick(freeMinutes, r.freeMinutes),
    capReset: pick(capReset, r.capReset),
    renew: pick(renew, r.renew),
    extension: pick(extension, r.extension),
    periods: pick(periods, r.periods),
    crossPeriod: pick(crossPeriod, r.crossPeriod),
    factorPct: pick(factorPct, r.factorPct),
  );
}

bool _simple(FeeMode? m) =>
    m == FeeMode.free ||
    m == FeeMode.hourly ||
    m == FeeMode.perVisit ||
    m == FeeMode.daily;

/// The rate a mode starts from, keeping what [old] already has.
Rate _switchTo(FeeMode mode, Rate? old, Fee fee) {
  if (mode.follows) {
    // Follow a vehicle that has a rate; the scooter's when both or neither.
    final known = _known(fee);
    final scooter = known.textOf('scooter') != null;
    final car = known.textOf('car') != null;
    return Rate(
      !scooter && car ? FeeMode.sameAsCar : FeeMode.sameAsScooter,
      factorPct: old?.factorPct,
    );
  }
  if (mode == FeeMode.byTime) {
    return const Rate(
      FeeMode.byTime,
      periods: [
        FeePeriod(days: 'all', rate: Rate(FeeMode.hourly, perMinutes: 60)),
      ],
    );
  }
  final base = old != null && _simple(old.mode) ? old : Rate(mode);
  return _edit(
    base,
    mode: mode,
    perMinutes: mode == FeeMode.hourly ? base.perMinutes ?? 60 : _keep,
    // An hourly cap's reset is not a daily charge's: each mode answers it.
    capReset: base.mode == mode ? _keep : null,
  );
}

/// One vehicle's rate: how it pays (收費方式), then only the fields that
/// mode needs. Heavy bikes may also follow another vehicle (比照其他車種),
/// whose rate [fee] gives.
class RateEditor extends StatelessWidget {
  const RateEditor({
    super.key,
    required this.vehicle,
    required this.value,
    required this.onChanged,
    this.fee = const Fee(),
  });
  final FeeVehicle vehicle;
  final Rate? value;
  final ValueChanged<Rate?> onChanged;
  final Fee fee;

  @override
  Widget build(BuildContext context) {
    final mode = value?.mode;
    final follows = mode?.follows ?? false;
    final w = vehicle.wire;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Choices<FeeMode?>(
          label: '收費方式',
          values: [
            for (final m in [
              null,
              FeeMode.free,
              FeeMode.hourly,
              FeeMode.perVisit,
              FeeMode.daily,
              FeeMode.byTime,
              if (vehicle == FeeVehicle.heavy) FeeMode.sameAsScooter,
            ])
              (m, _modeLabel(m)),
          ],
          // Both follows are one choice; which vehicle comes below.
          selected: follows ? FeeMode.sameAsScooter : mode,
          // Nothing to follow until another vehicle has a rate.
          disabled: {if (!follows && !_canFollow(fee)) FeeMode.sameAsScooter},
          keyOf: (m) =>
              'fee-mode-$w-${switch (m) {
                null => 'unknown',
                final m when m.follows => 'same_as',
                final m => m.wire,
              }}',
          onSelect: (m) {
            if (m == null) return onChanged(null);
            if (m == mode || (m.follows && follows)) return;
            onChanged(_switchTo(m, value, fee));
          },
        ),
        if (vehicle == FeeVehicle.heavy && !follows && !_canFollow(fee))
          Text(
            '普通機車或汽車有費率後，才能選「比照其他車種」。',
            key: const ValueKey('fee-follow-hint'),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        if (_simple(mode)) ...[
          const SizedBox(height: 8),
          SimpleRateFields(
            key: ValueKey('fee-simple-$w'),
            keyPrefix: w,
            rate: value!,
            onChanged: onChanged,
          ),
        ],
        if (mode == FeeMode.byTime) ...[
          const SizedBox(height: 8),
          _ByTimeFields(
            key: ValueKey('fee-by-time-$w'),
            keyPrefix: w,
            rate: value!,
            onChanged: onChanged,
          ),
        ],
        if (follows) ...[
          const SizedBox(height: 8),
          _FollowFields(rate: value!, fee: fee, onChanged: onChanged),
        ],
      ],
    );
  }
}

/// Billing periods offered for hourly rates, in minutes.
const _periods = [15, 30, 60, 120, 180, 240, 360, 480, 720, 1440];

/// Valid times, billing units and extensions offered, in minutes.
const _spans = [10, 15, 20, 30, 60, 120, 180, 240, 360, 480, 720, 1440];

/// [options] plus the stored [current] value when it is another valid one
/// (the column takes any 1–1440 minutes), so it shows as chosen.
List<int> _withCurrent(Iterable<int> options, int? current) => [
  ...{...options, ?current},
]..sort();

/// An optional whole number: none when empty. Text that is not one stays out
/// of range instead of reading as none, so a caller that checks only the
/// [Fee] still refuses it rather than silently dropping the value.
int? _optional(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? -1;
}

String? _yuan(String? v, {required bool required}) {
  final text = v?.trim() ?? '';
  if (text.isEmpty) return required ? '請填寫金額' : null;
  final n = int.tryParse(text);
  if (n == null || n < 0 || n > 10000) return '請填 0 到 10000 的整數';
  return null;
}

/// The fields of a free, hourly, per-visit or daily rate (design §8.5): the
/// amount and what the mode needs up front, the 跨日怎麼收 choice always in
/// view, optional rules under 更多收費規則.
class SimpleRateFields extends StatefulWidget {
  const SimpleRateFields({
    super.key,
    required this.keyPrefix,
    required this.rate,
    required this.onChanged,
  });

  /// Keys of the fields end with this (`heavy`, `car-p1`), for tests.
  final String keyPrefix;
  final Rate rate;
  final ValueChanged<Rate> onChanged;

  @override
  State<SimpleRateFields> createState() => _SimpleRateFieldsState();
}

class _SimpleRateFieldsState extends State<SimpleRateFields> {
  late final amount = TextEditingController(text: _shown(widget.rate.amount));
  late final cap = TextEditingController(text: _shown(widget.rate.dailyCap));
  late final free = TextEditingController(
    text: _shown(widget.rate.freeMinutes),
  );
  late final extAmount = TextEditingController(
    text: _shown(widget.rate.extension?.amount),
  );
  bool more = false;

  /// A stored value as its field shows it; the out-of-range mark that
  /// unreadable text left ([_optional]) shows as an empty field.
  static String _shown(int? v) => v == null || v < 0 ? '' : '$v';

  @override
  void initState() {
    super.initState();
    // Reopened after unreadable text in an optional field: the field shows
    // empty, so the rate drops the mark too instead of staying unfinished.
    if ((rate.dailyCap ?? 0) < 0 || (rate.freeMinutes ?? 0) < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        emit(
          _edit(
            rate,
            dailyCap: (rate.dailyCap ?? 0) < 0 ? null : _keep,
            capReset: (rate.dailyCap ?? 0) < 0 ? null : _keep,
            freeMinutes: (rate.freeMinutes ?? 0) < 0 ? null : _keep,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    amount.dispose();
    cap.dispose();
    free.dispose();
    extAmount.dispose();
    super.dispose();
  }

  Rate get rate => widget.rate;
  String get k => widget.keyPrefix;

  void emit(Rate r) => widget.onChanged(r);

  Widget numberField(
    String key,
    String label,
    TextEditingController c, {
    required String suffix,
    required String? Function(String?) validator,
    required ValueChanged<String> onChanged,
    String? helper,
  }) => TextFormField(
    key: ValueKey('fee-$key-$k'),
    controller: c,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(
      labelText: label,
      suffixText: suffix,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
    ),
    validator: validator,
    onChanged: onChanged,
  );

  Widget dropdown<T>(
    String key,
    String label,
    T value,
    List<(T, String)> items,
    ValueChanged<T?> onChanged,
  ) => DropdownButtonFormField<T>(
    key: ValueKey('fee-$key-$k'),
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      for (final (v, text) in items)
        DropdownMenuItem(
          value: v,
          child: Text(text, overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: onChanged,
  );

  List<(CapReset?, String)> get resets => [
    for (final r in CapReset.values) (r, FeeWords.reset(r)!),
    (null, '未確認'),
  ];

  Widget amountField(String label) => numberField(
    'amount',
    label,
    amount,
    suffix: '元',
    validator: (v) => _yuan(v, required: true),
    onChanged: (t) => emit(_edit(rate, amount: int.tryParse(t.trim()))),
  );

  FeeExtension _ext({
    Object? amount = _keep,
    int? maxTimes,
    Object? minutes = _keep,
  }) {
    final e = rate.extension!;
    return FeeExtension(
      amount: identical(amount, _keep) ? e.amount : amount! as int,
      maxTimes: maxTimes ?? e.maxTimes,
      minutes: identical(minutes, _keep) ? e.minutes : minutes as int?,
    );
  }

  /// The optional rules already set, named under 更多收費規則 so a closed
  /// section never hides data (§8.5 item 3).
  List<String> get setRules => [
    if (rate.mode == FeeMode.hourly) ...[
      if (rate.freeMinutes case final m? when m > 0)
        '首 ${FeeWords.span(m)} 0 元',
      if (rate.unitMinutes case final m? when m > 0) '以 ${FeeWords.span(m)}計',
      if (rate.dailyCap case final c? when c >= 0) '當日上限 $c 元',
    ],
    if (rate.mode == FeeMode.perVisit) ...[
      if (rate.maxMinutes case final m?) '有效時間 ${FeeWords.span(m)}',
      if (rate.extension != null) '可延長',
    ],
    if (rate.mode == FeeMode.daily && rate.capReset != null)
      FeeWords.reset(rate.capReset)!,
  ];

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 13,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final up = <Widget>[], rules = <Widget>[];
    switch (rate.mode) {
      case FeeMode.hourly:
        final per = rate.perMinutes ?? 60;
        up.add(
          _FieldRow([
            amountField('金額'),
            dropdown<int>(
              'per',
              '計費時間',
              per,
              [
                for (final m in _withCurrent(_periods, rate.perMinutes))
                  (m, FeeWords.every(m)),
              ],
              (v) => emit(
                _edit(
                  rate,
                  perMinutes: v,
                  // A unit longer than the period is out of range.
                  unitMinutes: (rate.unitMinutes ?? 0) > (v ?? 60)
                      ? null
                      : _keep,
                ),
              ),
            ),
          ]),
        );
        rules.addAll([
          numberField(
            'free',
            '前幾分鐘 0 元',
            free,
            suffix: '分鐘',
            helper: '公告寫「首 20 分鐘 0 元」時填這裡，這不是免費格',
            validator: (v) {
              final n = _optional(v ?? '');
              return n == null || (n >= 1 && n <= 1440)
                  ? null
                  : '請填 1 到 1440 的整數';
            },
            onChanged: (t) => emit(_edit(rate, freeMinutes: _optional(t))),
          ),
          dropdown<int?>('unit', '計費單位', rate.unitMinutes, [
            for (final m in _withCurrent(
              _spans.where((m) => m <= per),
              rate.unitMinutes,
            ))
              (m, '以 ${FeeWords.span(m)}計'),
            (null, '未確認'),
          ], (v) => emit(_edit(rate, unitMinutes: v))),
          _FieldRow([
            numberField(
              'cap',
              '當日上限',
              cap,
              suffix: '元',
              validator: (v) => _yuan(v, required: false),
              onChanged: (t) {
                final cap = _optional(t);
                // Without a cap there is nothing to reset.
                emit(
                  _edit(
                    rate,
                    dailyCap: cap,
                    capReset: cap == null ? null : _keep,
                  ),
                );
              },
            ),
            if (rate.dailyCap != null)
              dropdown<CapReset?>(
                'cap-reset',
                '上限何時重新計算',
                rate.capReset,
                resets,
                (v) => emit(_edit(rate, capReset: v)),
              ),
          ]),
        ]);
      case FeeMode.perVisit:
        up.addAll([
          amountField('每次金額'),
          _ThreeWay(
            legend: '跨日怎麼收',
            keyPrefix: 'fee-renew-$k',
            options: [
              ('midnight', '隔日另計'),
              ('none', rate.maxMinutes == null ? '停多久都只收一次' : '有效時間內只收一次'),
            ],
            value: rate.renew?.wire,
            onChanged: (v) => emit(
              _edit(
                rate,
                renew: Renew.values.where((r) => r.wire == v).firstOrNull,
              ),
            ),
          ),
        ]);
        final ext = rate.extension;
        rules.addAll([
          dropdown<int?>('max', '有效時間（一次可停多久）', rate.maxMinutes, [
            for (final m in _withCurrent(_spans, rate.maxMinutes))
              (m, FeeWords.span(m)),
            (null, '未確認'),
          ], (v) => emit(_edit(rate, maxMinutes: v))),
          CheckboxListTile(
            key: ValueKey('fee-ext-$k'),
            value: ext != null,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('可付費延長', style: TextStyle(fontSize: 14)),
            onChanged: (on) => emit(
              _edit(
                rate,
                extension: on ?? false
                    ? FeeExtension(
                        amount: _optional(extAmount.text) ?? -1,
                        maxTimes: 1,
                      )
                    : null,
              ),
            ),
          ),
          if (ext != null)
            _FieldRow([
              numberField(
                'ext-amount',
                '每次延長金額',
                extAmount,
                suffix: '元',
                validator: (v) => _yuan(v, required: true),
                onChanged: (t) => emit(
                  _edit(rate, extension: _ext(amount: _optional(t) ?? -1)),
                ),
              ),
              dropdown<int>('ext-times', '最多延長幾次', ext.maxTimes, [
                for (var n = 1; n <= 10; n++) (n, '$n 次'),
              ], (v) => emit(_edit(rate, extension: _ext(maxTimes: v)))),
              dropdown<int?>('ext-minutes', '每次延長多久', ext.minutes, [
                for (final m in _withCurrent(_spans, ext.minutes))
                  (m, FeeWords.span(m)),
                (null, '未確認'),
              ], (v) => emit(_edit(rate, extension: _ext(minutes: v)))),
            ]),
        ]);
      case FeeMode.daily:
        up.add(amountField('每日金額'));
        rules.add(
          dropdown<CapReset?>(
            'cap-reset',
            '何時重新計算',
            rate.capReset,
            resets,
            (v) => emit(_edit(rate, capReset: v)),
          ),
        );
      default:
    }
    final set = setRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, w) in up.indexed) ...[
          if (i > 0) const SizedBox(height: 12),
          w,
        ],
        if (rules.isNotEmpty) ...[
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('fee-more-$k'),
              onPressed: () => setState(() => more = !more),
              iconAlignment: IconAlignment.end,
              icon: Icon(more ? Icons.expand_less : Icons.chevron_right),
              label: const Text('更多收費規則'),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
            ),
          ),
          if (!more && set.isNotEmpty)
            Text('已設：${set.join('、')}', style: muted),
          if (more)
            for (final w in rules) ...[const SizedBox(height: 12), w],
        ],
      ],
    );
  }
}

String _factorText(int? pct) {
  final p = pct ?? 100;
  if (p % 100 == 0) return '${p ~/ 100}';
  return p % 10 == 0
      ? (p / 100).toStringAsFixed(1)
      : (p / 100).toStringAsFixed(2);
}

/// The factor typed as 1–10 with at most two decimals, as `factor_pct`:
/// null for once, -1 when out of range.
int? _factorPct(String text) {
  final t = text.trim();
  if (t.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(t)) return -1;
  final pct = (double.parse(t) * 100).round();
  if (pct < 100 || pct > 1000) return -1;
  return pct == 100 ? null : pct;
}

/// 比照其他車種 (canvas FeeSameAs): which vehicle the heavy bike pays the
/// same as, only one whose rate is known, and how many times it.
class _FollowFields extends StatefulWidget {
  const _FollowFields({
    required this.rate,
    required this.fee,
    required this.onChanged,
  });
  final Rate rate;
  final Fee fee;
  final ValueChanged<Rate> onChanged;

  @override
  State<_FollowFields> createState() => _FollowFieldsState();
}

class _FollowFieldsState extends State<_FollowFields> {
  late final factor = TextEditingController(
    text: _factorText(widget.rate.factorPct),
  );

  @override
  void dispose() {
    factor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final known = _known(widget.fee);
    const sources = [
      (FeeMode.sameAsScooter, FeeVehicle.scooter),
      (FeeMode.sameAsCar, FeeVehicle.car),
    ];
    final source = widget.rate.mode == FeeMode.sameAsCar
        ? FeeVehicle.car
        : FeeVehicle.scooter;
    final any = sources.any((s) => known.textOf(s.$2.wire) != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Legend('和哪個車種收一樣的錢'),
        RadioGroup<FeeMode>(
          groupValue: widget.rate.mode,
          onChanged: (m) =>
              widget.onChanged(_edit(widget.rate, mode: m ?? widget.rate.mode)),
          child: Column(
            children: [
              for (final (mode, v) in sources)
                RadioListTile<FeeMode>(
                  key: ValueKey('fee-follow-${v.wire}'),
                  value: mode,
                  // An unconfirmed vehicle cannot be followed (canvas).
                  enabled: known.textOf(v.wire) != null,
                  contentPadding: EdgeInsets.zero,
                  title: Text(v.label, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    known.textOf(v.wire) ?? '費率未確認，不能選',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: const ValueKey('fee-factor'),
          controller: factor,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: '是${source.label}費率的幾倍',
            suffixText: '倍',
            errorMaxLines: 3,
          ),
          validator: (v) =>
              _factorPct(v ?? '') == -1 ? '請填 1 到 10 的數字，最多兩位小數' : null,
          onChanged: (t) =>
              widget.onChanged(_edit(widget.rate, factorPct: _factorPct(t))),
        ),
        const SizedBox(height: 8),
        Text(
          any ? '${source.label}的費率之後改了，大型重機會跟著變。' : '請先填普通機車或汽車的費率，才能比照。',
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

const _dayPresets = [('all', '每天'), ('weekday', '平日'), ('holiday', '假日')];

/// 依時段不同 (canvas FeeDays): up to six periods, each with its days, its
/// time and its own rate; what no period covers is written out, and with two
/// per-visit periods the 停到下一個時段時 choice appears.
class _ByTimeFields extends StatefulWidget {
  const _ByTimeFields({
    super.key,
    required this.keyPrefix,
    required this.rate,
    required this.onChanged,
  });
  final String keyPrefix;
  final Rate rate;
  final ValueChanged<Rate> onChanged;

  @override
  State<_ByTimeFields> createState() => _ByTimeFieldsState();
}

class _ByTimeFieldsState extends State<_ByTimeFields> {
  /// A stable id per period, so each keeps its fields when one is removed.
  final ids = <int>[];
  int next = 0;
  int? open = 0;

  List<FeePeriod> get periods => widget.rate.periods ?? const [];

  void emit(List<FeePeriod> list) {
    final visits = list.where((p) => p.rate.mode == FeeMode.perVisit).length;
    widget.onChanged(
      _edit(
        widget.rate,
        periods: list,
        // The choice shows only with two per-visit periods; it never stays
        // behind once hidden.
        crossPeriod: visits >= 2 ? _keep : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final list = periods;
    while (ids.length < list.length) {
      ids.add(next++);
    }
    final gaps = feeGaps(list);
    final visits = list.where((p) => p.rate.mode == FeeMode.perVisit).length;
    final maxEntries =
        (feeContract['periods']! as Map<String, Object?>)['max_entries']!
            as int;
    final k = widget.keyPrefix;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, p) in list.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          _PeriodCard(
            key: ValueKey('fee-period-$k-${ids[i]}'),
            keyPrefix: '$k-p${ids[i]}',
            period: p,
            open: open == i,
            onToggle: () => setState(() => open = open == i ? null : i),
            onRemove: list.length > 1
                ? () {
                    setState(() {
                      ids.removeAt(i);
                      open = null;
                    });
                    emit([...list]..removeAt(i));
                  }
                : null,
            onChanged: (np) => emit([...list]..[i] = np),
          ),
        ],
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: ValueKey('fee-period-add-$k'),
            onPressed: list.length >= maxEntries
                ? null
                : () {
                    setState(() => open = list.length);
                    emit([
                      ...list,
                      const FeePeriod(
                        days: 'all',
                        from: '08:00',
                        to: '20:00',
                        rate: Rate(FeeMode.hourly, perMinutes: 60),
                      ),
                    ]);
                  },
            icon: const Icon(Icons.add),
            label: Text(
              list.length >= maxEntries ? '最多 $maxEntries 個時段' : '加一個時段',
            ),
          ),
        ),
        if (gaps.isNotEmpty) ...[
          Text(
            '${gaps.join('、')} 還沒有費率，會顯示未確認',
            key: ValueKey('fee-gaps-$k'),
            style: muted.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
        ],
        Text('國定假日依當天是星期幾計費。沒有被設定包含到的日子和時間，App 顯示「未確認」。', style: muted),
        if (visits >= 2) ...[
          const SizedBox(height: 8),
          _ThreeWay(
            legend: '停到下一個時段時',
            keyPrefix: 'fee-cross-$k',
            options: const [
              ('each_period', '進入新時段再收一次'),
              ('entry_only', '只依進場時段收'),
            ],
            value: widget.rate.crossPeriod?.wire,
            onChanged: (v) => widget.onChanged(
              _edit(
                widget.rate,
                crossPeriod: CrossPeriod.values
                    .where((c) => c.wire == v)
                    .firstOrNull,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _PeriodCard extends StatefulWidget {
  const _PeriodCard({
    super.key,
    required this.keyPrefix,
    required this.period,
    required this.open,
    required this.onToggle,
    required this.onRemove,
    required this.onChanged,
  });
  final String keyPrefix;
  final FeePeriod period;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback? onRemove;
  final ValueChanged<FeePeriod> onChanged;

  @override
  State<_PeriodCard> createState() => _PeriodCardState();
}

String? _time(String? v) =>
    RegExp(timePattern).hasMatch(v?.trim() ?? '') ? null : '請用 24 小時制，例如 08:00';

class _PeriodCardState extends State<_PeriodCard> {
  late final from = TextEditingController(text: widget.period.from ?? '');
  late final to = TextEditingController(text: widget.period.to ?? '');

  /// 指定: the weekdays are picked one by one even when they match a preset.
  late bool pickDays = widget.period.days is List;

  @override
  void dispose() {
    from.dispose();
    to.dispose();
    super.dispose();
  }

  FeePeriod get p => widget.period;

  void emit({
    Object? days,
    String? f,
    String? t,
    bool allDay = false,
    Rate? rate,
  }) => widget.onChanged(
    FeePeriod(
      days: days ?? p.days,
      from: allDay ? null : f ?? p.from,
      to: allDay ? null : t ?? p.to,
      rate: rate ?? p.rate,
    ),
  );

  List<String> _days(int mask) => [
    for (var d = 0; d < 7; d++)
      if (mask & (1 << d) != 0) scheduleWeekdays[d],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final mask = FeeWords.dayMask(p.days);
    final allDay = p.from == null && p.to == null;
    final valid = validRate(p.rate.toJson(), 'car', nested: true);
    final summary = valid ? (Fee(car: p.rate).textOf('car') ?? '未確認') : '還沒填完';
    final k = widget.keyPrefix;
    final dayChoice = pickDays ? 'pick' : p.days as String;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: ValueKey('fee-period-head-$k'),
            onTap: widget.onToggle,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            if (mask != 127)
                              TextSpan(text: '${FeeWords.dayLabel(mask)} '),
                            TextSpan(
                              text: feePeriodTime(p.from, p.to),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        summary,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 14,
                          color: valid ? null : colors.error,
                        ),
                      ),
                    ),
                    Icon(
                      widget.open ? Icons.expand_less : Icons.expand_more,
                      semanticLabel: widget.open ? '收合這段' : '展開這段',
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.open)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Choices<String>(
                    label: '哪幾天',
                    values: [..._dayPresets, ('pick', '指定')],
                    selected: dayChoice,
                    keyOf: (v) => 'fee-days-$k-$v',
                    onSelect: (v) {
                      setState(() => pickDays = v == 'pick');
                      emit(days: v == 'pick' ? _days(mask) : v);
                    },
                  ),
                  const SizedBox(height: 4),
                  _WeekRow(
                    keyPrefix: k,
                    mask: mask,
                    editable: pickDays,
                    onToggle: (i) {
                      final next = mask ^ (1 << i);
                      // At least one day stays: a period covers some day.
                      if (next != 0) emit(days: _days(next));
                    },
                  ),
                  const SizedBox(height: 8),
                  _Choices<bool>(
                    label: '時間',
                    values: const [(true, '全天'), (false, '指定時間')],
                    selected: allDay,
                    keyOf: (v) => 'fee-all-day-$k-$v',
                    onSelect: (v) {
                      if (v) return emit(allDay: true);
                      if (from.text.isEmpty) from.text = '08:00';
                      if (to.text.isEmpty) to.text = '20:00';
                      emit(f: from.text.trim(), t: to.text.trim());
                    },
                  ),
                  if (!allDay) ...[
                    const SizedBox(height: 8),
                    _FieldRow([
                      TextFormField(
                        key: ValueKey('fee-from-$k'),
                        controller: from,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: '開始',
                          hintText: '08:00',
                          errorMaxLines: 2,
                        ),
                        validator: _time,
                        onChanged: (v) => emit(f: v.trim()),
                      ),
                      TextFormField(
                        key: ValueKey('fee-to-$k'),
                        controller: to,
                        keyboardType: TextInputType.datetime,
                        decoration: const InputDecoration(
                          labelText: '結束',
                          hintText: '20:00',
                          helperText: '比開始早表示到隔日',
                          errorMaxLines: 2,
                        ),
                        validator: (v) =>
                            _time(v) ??
                            (v?.trim() == from.text.trim()
                                ? '結束和開始不能相同'
                                : null),
                        onChanged: (v) => emit(t: v.trim()),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 8),
                  _Choices<FeeMode>(
                    label: '這段怎麼收',
                    values: [
                      for (final m in [
                        FeeMode.free,
                        FeeMode.hourly,
                        FeeMode.perVisit,
                        FeeMode.daily,
                      ])
                        (m, _modeLabel(m)),
                    ],
                    selected: p.rate.mode,
                    keyOf: (m) => 'fee-mode-$k-${m.wire}',
                    onSelect: (m) {
                      if (m != p.rate.mode) {
                        emit(rate: _switchTo(m, p.rate, const Fee()));
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  SimpleRateFields(
                    keyPrefix: k,
                    rate: p.rate,
                    onChanged: (r) => emit(rate: r),
                  ),
                  if (widget.onRemove != null)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: ValueKey('fee-period-remove-$k'),
                        onPressed: widget.onRemove,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('刪除這段'),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

const _weekNames = '一二三四五六日';

/// The week under a period's days: which days a preset covers, or seven
/// toggles when the days are picked (指定).
class _WeekRow extends StatelessWidget {
  const _WeekRow({
    required this.keyPrefix,
    required this.mask,
    required this.editable,
    required this.onToggle,
  });
  final String keyPrefix;
  final int mask;
  final bool editable;
  final ValueChanged<int> onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget cell(int i) {
      final on = mask & (1 << i) != 0;
      final box = Container(
        height: editable ? 48 : 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on
              ? colors.primary
              : editable
              ? colors.surface
              : colors.surfaceContainerHigh,
          border: editable && !on
              ? Border.all(color: colors.outlineVariant)
              : null,
          borderRadius: BorderRadius.circular(editable ? 8 : 6),
        ),
        child: Text(
          _weekNames[i],
          style: TextStyle(
            fontSize: 14,
            fontWeight: on ? FontWeight.w700 : FontWeight.w400,
            color: on ? colors.onPrimary : colors.onSurfaceVariant,
          ),
        ),
      );
      if (!editable) return box;
      return Semantics(
        button: true,
        selected: on,
        label: '週${_weekNames[i]}',
        child: InkWell(
          key: ValueKey('fee-day-$keyPrefix-$i'),
          onTap: () => onToggle(i),
          borderRadius: BorderRadius.circular(8),
          child: ExcludeSemantics(child: box),
        ),
      );
    }

    const gap = 4.0, target = 48.0;
    final row = LayoutBuilder(
      builder: (context, constraints) {
        // Seven toggles share the row while each stays 48 px wide;
        // narrower, they wrap at 48 × 48 (touch targets, design §8.5).
        if (editable && constraints.maxWidth < target * 7 + gap * 6) {
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < 7; i++)
                SizedBox(width: target, child: cell(i)),
            ],
          );
        }
        return Row(
          children: [
            for (var i = 0; i < 7; i++) ...[
              if (i > 0) const SizedBox(width: gap),
              Expanded(child: cell(i)),
            ],
          ],
        );
      },
    );
    return editable
        ? Semantics(container: true, label: '指定星期幾', child: row)
        : ExcludeSemantics(child: row);
  }
}

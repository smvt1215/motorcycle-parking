import '../models/fee.dart';
import '../models/parking_condition.dart'
    show feeContract, scheduleWeekdays, timePattern;
import 'adaptive/adaptive.dart';
import 'fee_board.dart';
import 'option_pill.dart';
import 'time_range_field.dart';
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
  if (rate == null) return ('未提供', false);
  if (!_rateValid(rate, v)) return ('還沒填完', true);
  if (rate.mode == FeeMode.notApplicable) return ('不適用', false);
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

/// The minutes a vehicle cannot park, Monday first: each day's `[start, end)`
/// from its 00:00 (C7).
typedef FeeClosedWeek = List<List<(int, int)>>;

/// What a report form (F1, F2) adds to the editor: its cards, 24-hour bar,
/// time fields and preview. The admin site's editor goes without.
class FeeFormStyle {
  const FeeFormStyle({
    this.original,
    this.why = const {},
    this.closed = const {},
    this.summary,
    this.addButton,
    this.now,
  });

  /// The rates a suggestion starts from; a vehicle that differs reads 修改中.
  /// Null in a new spot (C14).
  final Fee? original;

  /// Why 不適用 applies: 這區沒有汽車格.
  final Map<FeeVehicle, String> why;

  /// When each vehicle cannot park; left out when it cannot be worked out
  /// (C7), and then nothing is greyed.
  final Map<FeeVehicle, FeeClosedWeek> closed;

  /// 你要改的內容, above the preview.
  final Widget? summary;

  /// The row that adds a period.
  final Widget Function(String label, VoidCallback? onPressed)? addButton;

  /// The preview's 現在 (tests); null is the clock.
  final DateTime? now;

  bool changed(Fee fee, FeeVehicle v) =>
      original != null && _rateOf(fee, v) != _rateOf(original!, v);
}

/// [week] in words: 23:00–07:00、假日; null when nothing is closed. The one
/// part-closed group drops its days when the other days close whole.
String? feeClosedText(FeeClosedWeek week) {
  bool whole(List<(int, int)> day) =>
      day.length == 1 && day.single == (0, 1440);
  var full = 0;
  final partial = <String, int>{};
  for (final (d, spans) in week.indexed) {
    if (spans.isEmpty) continue;
    if (whole(spans)) {
      full |= 1 << d;
    } else {
      final time = _closedTime(spans);
      partial[time] = (partial[time] ?? 0) | (1 << d);
    }
  }
  if (full == 0 && partial.isEmpty) return null;
  final bare = partial.length == 1 && (partial.values.single | full) == 127;
  return [
    for (final MapEntry(key: time, value: mask) in partial.entries)
      bare || mask == 127 ? time : '${FeeWords.dayLabel(mask)} $time',
    if (full != 0) FeeWords.dayLabel(full),
  ].join('、');
}

String _clockText(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:'
    '${(m % 60).toString().padLeft(2, '0')}';

/// A day's closed spans; the evening and the morning read as one night.
String _closedTime(List<(int, int)> spans) {
  final list = [...spans];
  if (list.length >= 2 && list.first.$1 == 0 && list.last.$2 == 1440) {
    final morning = list.removeAt(0), night = list.removeLast();
    list.add((night.$1, morning.$2));
  }
  return [for (final (a, b) in list) '${_clockText(a)}–${_clockText(b % 1440)}']
      .join('、');
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
    this.requireComplete = true,
    this.form,
  });
  final Fee value;

  /// The report forms' look (F1, F2); null is the admin site's.
  final FeeFormStyle? form;

  /// Whether a fee with any vehicle must name all three and answer every
  /// rule (a new write, #188 layer 2). Off where an import's partial fee is
  /// shown as it is.
  final bool requireComplete;
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
    if (bad.isNotEmpty) return '${bad.join('、')}的費率還沒填完，請填好';
    // A fee written at all names every vehicle and answers every rule
    // (#188 layer 2, fee.write; PM_ANS_20261101_55): 不適用 for one without
    // bays here.
    if (widget.requireComplete && !fee.isEmpty) {
      final missing = [
        for (final v in FeeVehicle.values)
          if (_rateOf(fee, v) == null) v.label,
      ];
      if (missing.isNotEmpty) {
        return '請選${missing.join('、')}的收費方式；這裡沒有這種車的格位就選「不適用」';
      }
      final open = [
        for (final v in FeeVehicle.values)
          if (_rateOf(fee, v) case final rate? when !rate.writeComplete)
            v.label,
      ];
      if (open.isNotEmpty) {
        final reset = widget.form == null ? '上限何時重新計算' : '何時重算';
        return '${open.join('、')}還有規則沒選（跨日怎麼收、$reset或停到下一個時段時）';
      }
    }
    return _followGap(fee);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= feeEditorWideWidth;
        final form = widget.form;
        final previewed = open ?? FeeVehicle.scooter;
        final preview = !widget.showPreview
            ? null
            : form != null
            ? _FormPreview(
                fee: fee,
                vehicle: previewed,
                closed: form.closed[previewed],
                now: form.now ?? DateTime.now(),
              )
            : _Preview(fee: fee, first: open);
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
                        form: form,
                      ),
                    ),
                  ),
                  if (preview != null) ...[
                    const SizedBox(width: 16),
                    SizedBox(width: 300, child: preview),
                  ],
                ],
              ),
              if (form?.summary case final summary?) ...[
                const SizedBox(height: 14),
                summary,
              ],
              ...trailing,
            ],
          );
        }
        if (form != null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final v in FeeVehicle.values) ...[
                _FormCard(
                  open: v == open,
                  child: v == open
                      ? _OpenVehicle(
                          vehicle: v,
                          fee: fee,
                          onChanged: (rate) => setRate(v, rate),
                          onCollapse: () => setState(() => open = null),
                          form: form,
                        )
                      : _FormClosedVehicle(
                          vehicle: v,
                          fee: fee,
                          form: form,
                          onOpen: () => setState(() => open = v),
                        ),
                ),
                const SizedBox(height: 8),
              ],
              if (form.summary case final summary?) ...[
                const SizedBox(height: 6),
                summary,
                const SizedBox(height: 8),
              ],
              if (preview != null) ...[const SizedBox(height: 6), preview],
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

/// A vehicle's own card in a report form.
class _FormCard extends StatelessWidget {
  const _FormCard({required this.open, required this.child});
  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: open ? brand : colors.outlineVariant,
          width: open ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

/// F1's collapsed vehicle: its name on one line (C17), what it pays, why it
/// does not apply.
class _FormClosedVehicle extends StatelessWidget {
  const _FormClosedVehicle({
    required this.vehicle,
    required this.fee,
    required this.form,
    required this.onOpen,
  });
  final FeeVehicle vehicle;
  final Fee fee;
  final FeeFormStyle form;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (text, error) = _summary(fee, vehicle);
    final why = form.why[vehicle];
    final shown =
        _rateOf(fee, vehicle)?.mode == FeeMode.notApplicable && why != null
        ? '$text：$why'
        : text;
    return Semantics(
      button: true,
      expanded: false,
      child: InkWell(
        key: ValueKey('fee-row-${vehicle.wire}'),
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            child: Row(
              children: [
                ExcludeSemantics(child: VehicleMark(vehicle)),
                const SizedBox(width: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 96),
                  child: Text(
                    vehicle.label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        shown,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 13,
                          color: error ? colors.error : colors.onSurfaceVariant,
                        ),
                      ),
                      if (form.changed(fee, vehicle))
                        Text(
                          '修改中',
                          style: TextStyle(fontSize: 12, color: colors.primary),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.expand_more, color: colors.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
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
    this.form,
  });
  final FeeVehicle vehicle;
  final Fee fee;
  final ValueChanged<Rate?> onChanged;
  final VoidCallback? onCollapse;
  final FeeFormStyle? form;

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
                  maxLines: form == null ? null : 1,
                  overflow: form == null ? null : TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (form?.changed(fee, vehicle) ?? false)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    '修改中',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              if (onCollapse != null && form != null)
                IconButton(
                  onPressed: onCollapse,
                  tooltip: '收合${vehicle.label}費率',
                  icon: const Icon(Icons.expand_less),
                )
              else if (onCollapse != null)
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
          form: form,
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

/// A pill choice (canvas 收費方式), the site-wide [OptionPill].
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
  Widget build(BuildContext context) =>
      OptionPill(label: label, selected: selected, onTap: onTap);
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
    this.aside,
  });
  final String label;

  /// A small line beside [label].
  final String? aside;
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
      _Legend(aside == null ? label : '$label　$aside'),
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

/// A choice of answers, none chosen while nothing is known (design §2.5;
/// #188 layer 2 drops the 未確認 answer: an old value without one must be
/// answered before saving).
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
        groupValue: value,
        onChanged: onChanged,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (wire, text) in options)
              // A 48 px row, the whole of it a target (canvas: one radio
              // and its words per line).
              MergeSemantics(
                child: InkWell(
                  key: ValueKey('$keyPrefix-$wire'),
                  onTap: () => onChanged(wire),
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
  null => '未提供',
  FeeMode.notApplicable => '不適用',
  FeeMode.free => '免費',
  FeeMode.hourly => '計時',
  FeeMode.perVisit => '計次',
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
  Object? capReset = _keep,
  Object? renew = _keep,
  Object? extensionAmount = _keep,
  Object? periods = _keep,
  Object? crossPeriod = _keep,
}) {
  T? pick<T>(Object? v, T? old) => identical(v, _keep) ? old : v as T?;
  return Rate(
    mode ?? r.mode,
    amount: pick(amount, r.amount),
    perMinutes: pick(perMinutes, r.perMinutes),
    dailyCap: pick(dailyCap, r.dailyCap),
    capReset: pick(capReset, r.capReset),
    renew: pick(renew, r.renew),
    extensionAmount: pick(extensionAmount, r.extensionAmount),
    periods: pick(periods, r.periods),
    crossPeriod: pick(crossPeriod, r.crossPeriod),
  );
}

bool _simple(FeeMode? m) =>
    m == FeeMode.free || m == FeeMode.hourly || m == FeeMode.perVisit;

/// The rate a mode starts from, keeping what [old] already has.
Rate _switchTo(FeeMode mode, Rate? old, Fee fee) {
  if (mode.follows) {
    // Follow a vehicle that has a rate; the scooter's when both or neither.
    final known = _known(fee);
    final scooter = known.textOf('scooter') != null;
    final car = known.textOf('car') != null;
    return Rate(!scooter && car ? FeeMode.sameAsCar : FeeMode.sameAsScooter);
  }
  if (mode == FeeMode.byTime) {
    return const Rate(
      FeeMode.byTime,
      periods: [
        FeePeriod(days: 'all', rate: Rate(FeeMode.hourly, perMinutes: 60)),
      ],
    );
  }
  if (mode == FeeMode.notApplicable) return const Rate(FeeMode.notApplicable);
  final base = old != null && _simple(old.mode) ? old : Rate(mode);
  return _edit(
    base,
    mode: mode,
    perMinutes: mode == FeeMode.hourly ? base.perMinutes ?? 60 : _keep,
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
    this.form,
  });
  final FeeVehicle vehicle;
  final Rate? value;
  final ValueChanged<Rate?> onChanged;
  final Fee fee;
  final FeeFormStyle? form;

  @override
  Widget build(BuildContext context) {
    final mode = value?.mode;
    final follows = mode?.follows ?? false;
    final w = vehicle.wire;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Choices<FeeMode?>(
          label: form == null ? '收費方式' : '公告牌怎麼寫？',
          aside: form == null ? null : '這裡沒有這種車的格位就選「不適用」',
          values: [
            // F1 公告牌怎麼寫 (#188 layer 2): 未確認 is gone; 不適用 first.
            for (final m in [
              FeeMode.notApplicable,
              FeeMode.free,
              FeeMode.hourly,
              FeeMode.perVisit,
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
            if (m == null) return;
            if (m == mode || (m.follows && follows)) return;
            onChanged(_switchTo(m, value, fee));
          },
        ),
        if (mode == null && form == null)
          Text(
            '這裡沒有這種車的格位就選「不適用」。',
            key: ValueKey('fee-not-applicable-hint-$w'),
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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
            form: form != null,
          ),
        ],
        if (mode == FeeMode.byTime) ...[
          const SizedBox(height: 8),
          _ByTimeFields(
            key: ValueKey('fee-by-time-$w'),
            keyPrefix: w,
            rate: value!,
            onChanged: onChanged,
            form: form,
            vehicle: vehicle,
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
    this.form = false,
  });

  /// Keys of the fields end with this (`heavy`, `car-p1`), for tests.
  final String keyPrefix;
  final Rate rate;
  final ValueChanged<Rate> onChanged;

  /// The report forms' layout (F1, F2).
  final bool form;

  @override
  State<SimpleRateFields> createState() => _SimpleRateFieldsState();
}

class _SimpleRateFieldsState extends State<SimpleRateFields> {
  late final amount = TextEditingController(text: _shown(widget.rate.amount));
  late final cap = TextEditingController(text: _shown(widget.rate.dailyCap));
  late final extAmount = TextEditingController(
    text: _shown(widget.rate.extensionAmount),
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
    if ((rate.dailyCap ?? 0) < 0 || (rate.extensionAmount ?? 0) < 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        emit(
          _edit(
            rate,
            dailyCap: (rate.dailyCap ?? 0) < 0 ? null : _keep,
            capReset: (rate.dailyCap ?? 0) < 0 ? null : _keep,
            extensionAmount: (rate.extensionAmount ?? 0) < 0 ? null : _keep,
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    amount.dispose();
    cap.dispose();
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
    String? suffix,
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
    ValueChanged<T?>? onChanged,
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
  ];

  Widget amountField(String label) => numberField(
    'amount',
    label,
    amount,
    // F1 and F2 say 元 in the label.
    suffix: widget.form ? null : '元',
    validator: (v) => _yuan(v, required: true),
    onChanged: (t) => emit(_edit(rate, amount: int.tryParse(t.trim()))),
  );

  /// The optional rules already set, named under 更多收費規則 so a closed
  /// section never hides data (§8.5 item 3).
  List<String> get setRules => [
    if (rate.mode == FeeMode.hourly)
      if (rate.dailyCap case final c? when c >= 0) '當日上限 $c 元',
    if (rate.mode == FeeMode.perVisit)
      if (rate.extensionAmount case final a? when a >= 0) '延長每次 $a 元',
  ];

  /// 每多久收一次 offers these (F1); a stored other value stays offered.
  static const _formPeriods = [10, 15, 20, 30, 60];

  static String _formEvery(int m) =>
      m % 60 == 0 ? '每 ${m ~/ 60} 小時' : '每 $m 分鐘';

  static String _resetLabel(CapReset r) => switch (r.wire) {
    'calendar_day' => '每天 0 點',
    'rolling_24h' => '進場滿 24 小時',
    _ => '每次進場',
  };

  /// Two fields side by side when each fits.
  Widget _pair(Widget a, Widget b) => LayoutBuilder(
    builder: (context, box) =>
        box.maxWidth < 240 || MediaQuery.textScalerOf(context).scale(16) > 20
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [a, const SizedBox(height: 12), b],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: a),
              const SizedBox(width: 12),
              Expanded(child: b),
            ],
          ),
  );

  Widget _head(String text) =>
      Text(text, style: const TextStyle(fontWeight: FontWeight.w600));

  /// F1 and F2: what must be filled in up front, the optional rules under
  /// 更多收費規則, and 跨日怎麼收 always in view.
  Widget _formBody(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final up = <Widget>[], rules = <Widget>[], down = <Widget>[];
    switch (rate.mode) {
      case FeeMode.hourly:
        up.add(
          _pair(
            amountField('金額（元）'),
            dropdown<int>('per', '每多久收一次', rate.perMinutes ?? 60, [
              for (final m in _withCurrent(
                _formPeriods,
                rate.perMinutes,
              ).reversed)
                (m, _formEvery(m)),
            ], (v) => emit(_edit(rate, perMinutes: v))),
          ),
        );
        rules.addAll([
          _head('當日上限'),
          const SizedBox(height: 8),
          _pair(
            numberField(
              'cap',
              '金額（元）',
              cap,
              validator: (v) => _yuan(v, required: false),
              onChanged: (t) {
                final cap = _optional(t);
                emit(
                  _edit(
                    rate,
                    dailyCap: cap,
                    capReset: cap == null ? null : _keep,
                  ),
                );
              },
            ),
            dropdown<CapReset?>(
              'cap-reset',
              '何時重算',
              rate.capReset,
              [for (final r in CapReset.values) (r, _resetLabel(r))],
              rate.dailyCap == null
                  ? null
                  : (v) => emit(_edit(rate, capReset: v)),
            ),
          ),
        ]);
      case FeeMode.perVisit:
        up.addAll([
          Text('只填錢；限停時間在「限時／禁停／共用時段」設定', style: muted),
          const SizedBox(height: 8),
          _head('首次多少錢'),
          const SizedBox(height: 8),
          amountField('金額（元）'),
        ]);
        rules.addAll([
          _head('延長每次多少錢'),
          const SizedBox(height: 8),
          numberField(
            'ext-amount',
            '金額（元）',
            extAmount,
            helper: '公告寫「第 1 次 0 元、第 2 次 20 元」就填首次 0、延長 20。',
            validator: (v) => _yuan(v, required: false),
            onChanged: (t) => emit(_edit(rate, extensionAmount: _optional(t))),
          ),
          const SizedBox(height: 8),
          const FormInfoNote(
            icon: Icons.timer_outlined,
            text: '每次限停多久、可延長幾次是停放規定，不在費率裡；到「限時／禁停／共用時段」設定。',
          ),
        ]);
        down.add(
          _PickSegments(
            legend: '跨日怎麼收',
            keyPrefix: 'fee-renew-$k',
            options: const [('midnight', '隔日另計'), ('none', '停多久都只收一次')],
            value: rate.renew?.wire,
            onChanged: (v) => emit(
              _edit(
                rate,
                renew: Renew.values.where((r) => r.wire == v).firstOrNull,
              ),
            ),
          ),
        );
      default:
    }
    final set = setRules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...up,
        if (rules.isNotEmpty) ...[
          const SizedBox(height: 4),
          Semantics(
            button: true,
            expanded: more,
            child: InkWell(
              key: ValueKey('fee-more-$k'),
              onTap: () => setState(() => more = !more),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: isCupertino ? 44 : 48),
                child: Row(
                  children: [
                    Icon(
                      more ? Icons.expand_less : Icons.expand_more,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text('更多收費規則', style: TextStyle(color: colors.primary)),
                    const SizedBox(width: 12),
                    if (!more && set.isNotEmpty)
                      Expanded(
                        child: Text(
                          '已設：${set.join('、')}',
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (more) ...[const SizedBox(height: 8), ...rules],
        ],
        if (down.isNotEmpty) ...[const SizedBox(height: 8), ...down],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.form) return _formBody(context);
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
            dropdown<int>('per', '計費時間', per, [
              for (final m in _withCurrent(_periods, rate.perMinutes))
                (m, FeeWords.every(m)),
            ], (v) => emit(_edit(rate, perMinutes: v))),
          ]),
        );
        rules.addAll([
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
          amountField('首次多少錢'),
          _ThreeWay(
            legend: '跨日怎麼收',
            keyPrefix: 'fee-renew-$k',
            options: const [('midnight', '隔日另計'), ('none', '停多久都只收一次')],
            value: rate.renew?.wire,
            onChanged: (v) => emit(
              _edit(
                rate,
                renew: Renew.values.where((r) => r.wire == v).firstOrNull,
              ),
            ),
          ),
        ]);
        rules.addAll([
          numberField(
            'ext-amount',
            '延長每次多少錢',
            extAmount,
            suffix: '元',
            helper: '每次限停多久、可延長幾次在「限時」設定，不在費率裡',
            validator: (v) => _yuan(v, required: false),
            onChanged: (t) => emit(_edit(rate, extensionAmount: _optional(t))),
          ),
        ]);
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

/// 比照其他車種 (canvas FeeSameAs): which vehicle the heavy bike pays the
/// same as, only one whose rate is known; no factor (#188 layer 2).
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
                    known.textOf(v.wire) ?? '費率未提供，不能選',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          ),
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
    required this.vehicle,
    this.form,
  });
  final String keyPrefix;
  final Rate rate;
  final ValueChanged<Rate> onChanged;
  final FeeVehicle vehicle;
  final FeeFormStyle? form;

  @override
  State<_ByTimeFields> createState() => _ByTimeFieldsState();
}

class _ByTimeFieldsState extends State<_ByTimeFields> {
  /// A stable id per period, so each keeps its fields when one is removed.
  final ids = <int>[];
  int next = 0;
  int? open = 0;

  List<FeePeriod> get periods => widget.rate.periods ?? const [];

  /// 停到下一個時段時 is asked once a per-visit period has another period to
  /// cross into (#188 layer 2, C7: 有計次且時段 ≥2 段).
  static bool _asksCross(List<FeePeriod> list) =>
      list.length >= 2 && list.any((p) => p.rate.mode == FeeMode.perVisit);

  void emit(List<FeePeriod> list) {
    widget.onChanged(
      _edit(
        widget.rate,
        periods: list,
        // It never stays behind once hidden.
        crossPeriod: _asksCross(list) ? _keep : null,
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
    final maxEntries =
        (feeContract['periods']! as Map<String, Object?>)['max_entries']!
            as int;
    final k = widget.keyPrefix;
    final form = widget.form;
    final closed = form?.closed[widget.vehicle];
    final closedText = closed == null ? null : feeClosedText(closed);
    void addPeriod() {
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
    }

    final full = list.length >= maxEntries;
    final addLabel = full ? '最多 $maxEntries 個時段' : '加一個時段';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (form != null) ...[
          Row(
            children: [
              const Text('時段', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  closedText == null ? '點色塊編輯' : '點色塊編輯；灰色是非開放時段',
                  textAlign: TextAlign.end,
                  style: muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FeeTimeline(
            key: ValueKey('fee-timeline-$k'),
            periods: list,
            closed: closed,
            onTap: (i) => setState(() => open = i),
          ),
          if (closedText != null) ...[
            const SizedBox(height: 8),
            FormInfoNote(
              key: ValueKey('fee-closed-$k'),
              icon: Icons.info_outline,
              tone: FormNoteTone.warning,
              text: '$closedText是${widget.vehicle.label}非開放時段，不用填費率。',
            ),
          ],
          const SizedBox(height: 8),
        ],
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
            form: form != null,
          ),
        ],
        if (form?.addButton case final button?) ...[
          const SizedBox(height: 8),
          KeyedSubtree(
            key: ValueKey('fee-period-add-$k'),
            child: button(addLabel, full ? null : addPeriod),
          ),
          const SizedBox(height: 8),
        ] else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: ValueKey('fee-period-add-$k'),
              onPressed: full ? null : addPeriod,
              icon: const Icon(Icons.add),
              label: Text(addLabel),
            ),
          ),
        if (gaps.isNotEmpty && form == null) ...[
          _GapsNote(keyPrefix: k, gaps: gaps, brief: feeGapsBrief(list)),
          const SizedBox(height: 4),
        ],
        Text('假日含國定假日。沒有被設定包含到的日子和時間，App 顯示「未提供」。', style: muted),
        if (_asksCross(list) && form != null) ...[
          const SizedBox(height: 8),
          _PickSegments(
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
        ] else if (_asksCross(list)) ...[
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

/// What no period covers (decision 55): a short line first (「平日夜間、假日
/// 全天沒有費率」), the full list of times under 看完整時段.
class _GapsNote extends StatefulWidget {
  const _GapsNote({
    required this.keyPrefix,
    required this.gaps,
    required this.brief,
  });
  final String keyPrefix;
  final List<String> gaps, brief;

  @override
  State<_GapsNote> createState() => _GapsNoteState();
}

class _GapsNoteState extends State<_GapsNote> {
  bool full = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(
      fontSize: 12,
      height: 1.5,
      color: colors.onSurfaceVariant,
    );
    final k = widget.keyPrefix;
    final brief = widget.brief.join('、');
    // The full list adds nothing when the short line already gives every
    // time.
    final more = brief != widget.gaps.join('、');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$brief沒有費率',
          key: ValueKey('fee-gaps-$k'),
          style: muted.copyWith(fontWeight: FontWeight.w700),
        ),
        if (more) ...[
          if (full)
            for (final gap in widget.gaps)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('・$gap', style: muted),
              ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: ValueKey('fee-gaps-more-$k'),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              onPressed: () => setState(() => full = !full),
              child: Text(full ? '收起完整時段' : '看完整時段'),
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
    this.form = false,
  });
  final String keyPrefix;
  final FeePeriod period;
  final bool open;
  final VoidCallback onToggle;
  final VoidCallback? onRemove;
  final ValueChanged<FeePeriod> onChanged;

  /// The report forms' layout (F1, F2).
  final bool form;

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

  /// A period's rate in few words: 每小時 20 元, 首次 30 元.
  String get _brief => switch (p.rate.mode) {
    _ when !validRate(p.rate.toJson(), 'car', nested: true) => '還沒填完',
    FeeMode.hourly =>
      '${FeeWords.every(p.rate.perMinutes)} ${FeeWords.money(p.rate.amount)} 元',
    FeeMode.perVisit => '首次 ${FeeWords.money(p.rate.amount)} 元',
    FeeMode.free => '免費',
    _ => '未提供',
  };

  /// F1's period: the head with its delete, 適用哪幾天, the times with their
  /// picker, 這個時段怎麼收, and the rate's fields.
  Widget _formCard(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final k = widget.keyPrefix;
    final mask = FeeWords.dayMask(p.days);
    final allDay = p.from == null && p.to == null;
    final dayChoice = pickDays ? 'pick' : p.days as String;
    final title = '${FeeWords.dayLabel(mask)} ${feePeriodTime(p.from, p.to)}';
    final valid = validRate(p.rate.toJson(), 'car', nested: true);
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: widget.open ? brand : colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: widget.open,
            child: InkWell(
              key: ValueKey('fee-period-head-$k'),
              onTap: widget.onToggle,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: isCupertino ? 44 : 48),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!widget.open) ...[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _brief,
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 14,
                              color: valid ? null : colors.error,
                            ),
                          ),
                        ),
                      ],
                      if (widget.open && widget.onRemove != null)
                        IconButton(
                          key: ValueKey('fee-period-remove-$k'),
                          onPressed: widget.onRemove,
                          tooltip: '刪除這段',
                          icon: const Icon(Icons.delete_outline),
                        )
                      else
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            widget.open ? Icons.expand_less : Icons.expand_more,
                            semanticLabel: widget.open ? '收合這段' : '展開這段',
                          ),
                        ),
                    ],
                  ),
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
                    label: '適用哪幾天',
                    values: [..._dayPresets, ('pick', '自選星期')],
                    selected: dayChoice,
                    keyOf: (v) => 'fee-days-$k-$v',
                    onSelect: (v) {
                      setState(() => pickDays = v == 'pick');
                      emit(days: v == 'pick' ? _days(mask) : v);
                    },
                  ),
                  if (pickDays) ...[
                    const SizedBox(height: 4),
                    _WeekRow(
                      keyPrefix: k,
                      mask: mask,
                      editable: true,
                      onToggle: (i) {
                        final next = mask ^ (1 << i);
                        if (next != 0) emit(days: _days(next));
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  TimeRangeField(
                    keyPrefix: 'fee-time-$k',
                    labelled: true,
                    inlineWheel: true,
                    from: p.from,
                    to: p.to,
                    allDay: allDay,
                    help: isCupertino
                        ? '上下滑選時、分，分鐘 00–59 都可以選。結束早於開始（例 23:00–07:00）會自動標「隔日」。'
                        : '24 小時制，分鐘 00–59 都可以填。結束早於開始（例 23:00–07:00）會自動標「隔日」。',
                    onChanged: (r) => r.allDay
                        ? emit(allDay: true)
                        : emit(f: r.from ?? '08:00', t: r.to ?? '20:00'),
                  ),
                  FormField<void>(
                    key: ValueKey('fee-time-check-$k'),
                    validator: (_) =>
                        !allDay && p.from == p.to ? '結束和開始不能相同' : null,
                    builder: (state) => state.errorText == null
                        ? const SizedBox.shrink()
                        : Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              state.errorText!,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.error,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(height: 8),
                  _Choices<FeeMode>(
                    label: '這個時段怎麼收',
                    values: [
                      for (final m in [
                        FeeMode.hourly,
                        FeeMode.perVisit,
                        FeeMode.free,
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
                    key: ValueKey('fee-simple-$k-${p.rate.mode.wire}'),
                    keyPrefix: k,
                    rate: p.rate,
                    form: true,
                    onChanged: (r) => emit(rate: r),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.form) return _formCard(context);
    final colors = Theme.of(context).colorScheme;
    final mask = FeeWords.dayMask(p.days);
    final allDay = p.from == null && p.to == null;
    final valid = validRate(p.rate.toJson(), 'car', nested: true);
    final summary = valid ? (Fee(car: p.rate).textOf('car') ?? '未提供') : '還沒填完';
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

/// One of a few answers side by side, none picked until the rider picks
/// (C8): [AdaptiveSegmented] always holds a value, so it cannot ask these.
class _PickSegments extends StatelessWidget {
  const _PickSegments({
    required this.legend,
    required this.options,
    required this.value,
    required this.onChanged,
    required this.keyPrefix,
  });
  final String legend;
  final List<(String, String)> options;
  final String? value;
  final ValueChanged<String> onChanged;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cupertino = isCupertino;
    final radius = BorderRadius.circular(cupertino ? 10 : 24);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(legend, style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Semantics(
          label: legend,
          container: true,
          child: Container(
            padding: EdgeInsets.all(cupertino ? 2 : 0),
            decoration: BoxDecoration(
              color: cupertino ? colors.surfaceContainerHigh : null,
              border: cupertino ? null : Border.all(color: colors.outline),
              borderRadius: radius,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, (wire, text)) in options.indexed) ...[
                      if (i > 0 && !cupertino)
                        VerticalDivider(width: 1, color: colors.outline),
                      Expanded(
                        child: Semantics(
                          button: true,
                          inMutuallyExclusiveGroup: true,
                          selected: wire == value,
                          child: Material(
                            color: wire != value
                                ? Colors.transparent
                                : cupertino
                                ? colors.surface
                                : colors.primaryContainer,
                            borderRadius: BorderRadius.circular(
                              cupertino ? 8 : 0,
                            ),
                            child: InkWell(
                              key: ValueKey('$keyPrefix-$wire'),
                              onTap: () => onChanged(wire),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: cupertino ? 40 : 48,
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (!cupertino && wire == value) ...[
                                        Icon(
                                          Icons.check,
                                          size: 16,
                                          color: colors.onPrimaryContainer,
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Flexible(
                                        child: Text(
                                          text,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: wire == value
                                                ? FontWeight.w700
                                                : FontWeight.w400,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One stretch of a [FeeTimeline] day.
typedef _TimelineBlock = ({int start, int end, int period});

/// 時段 (F1): a bar of 24 hours for each kind of day; days that read alike
/// share one. A period's block opens it; closed time is grey and hatched,
/// and says so where it fits (never colour alone).
class FeeTimeline extends StatelessWidget {
  const FeeTimeline({
    super.key,
    required this.periods,
    required this.onTap,
    this.closed,
  });
  final List<FeePeriod> periods;
  final ValueChanged<int> onTap;
  final FeeClosedWeek? closed;

  static const _plate = Color(0xff16313a);

  List<_TimelineBlock> _blocksOn(int day) {
    final start = day * 1440, end = start + 1440;
    final out = <_TimelineBlock>[];
    for (final (i, p) in periods.indexed) {
      for (final (a, b) in feePeriodSpans(p.days, p.from, p.to)) {
        for (final shift in const [0, -weekMinutes]) {
          final from = a + shift, to = b + shift;
          if (to <= start || from >= end) continue;
          out.add((
            start: from.clamp(start, end) - start,
            end: to.clamp(start, end) - start,
            period: i,
          ));
        }
      }
    }
    return out;
  }

  String _label(Rate r) => switch (r.mode) {
    FeeMode.hourly when r.amount != null => '計時 ${r.amount}',
    FeeMode.perVisit when r.amount != null => '計次 ${r.amount}',
    FeeMode.hourly => '計時',
    FeeMode.perVisit => '計次',
    _ => '免費',
  };

  String _spoken(FeePeriod p) {
    final time = feePeriodTime(p.from, p.to);
    final rate = p.rate;
    final words = switch (rate.mode) {
      FeeMode.hourly =>
        '計時，${FeeWords.every(rate.perMinutes)} ${FeeWords.money(rate.amount)} 元',
      FeeMode.perVisit => '計次，首次 ${FeeWords.money(rate.amount)} 元',
      _ => '免費',
    };
    return '$time $words，編輯這段';
  }

  Widget _bar(
    BuildContext context,
    List<_TimelineBlock> blocks,
    List<(int, int)> shut,
    double height,
  ) {
    final colors = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Container(
        height: height,
        color: colors.surfaceContainerLow,
        child: LayoutBuilder(
          builder: (context, box) {
            final per = box.maxWidth / 1440;
            return Stack(
              children: [
                for (final (a, b) in shut)
                  Positioned(
                    left: a * per,
                    width: (b - a) * per,
                    top: 0,
                    bottom: 0,
                    child: CustomPaint(
                      painter: _HatchPainter(colors.outlineVariant),
                      child: Center(
                        child: (b - a) * per >= 48
                            ? const FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  '非開放',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                for (final b in blocks)
                  Positioned(
                    left: b.start * per,
                    width: (b.end - b.start) * per,
                    top: 0,
                    bottom: 0,
                    child: _block(b, periods[b.period], per),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _block(_TimelineBlock b, FeePeriod p, double per) {
    final width = (b.end - b.start) * per;
    return Semantics(
      button: true,
      label: _spoken(p),
      excludeSemantics: true,
      child: Material(
        color: p.rate.mode == FeeMode.perVisit
            ? _plate
            : p.rate.mode == FeeMode.free
            ? allowedColor
            : brand,
        shape: const Border(
          left: BorderSide(color: Colors.white),
          right: BorderSide(color: Colors.white),
        ),
        child: InkWell(
          key: ValueKey('fee-block-${b.period}-${b.start}'),
          onTap: () => onTap(b.period),
          child: Center(
            child: width < 24
                ? null
                : Padding(
                    padding: const EdgeInsets.all(2),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        width < 56
                            ? _label(p.rate).replaceFirst(' ', '\n')
                            : _label(p.rate),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final height = isCupertino ? 44.0 : 48.0;
    final muted = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final rows =
        <
          String,
          ({int mask, List<_TimelineBlock> blocks, List<(int, int)> shut})
        >{};
    for (var d = 0; d < 7; d++) {
      final blocks = _blocksOn(d);
      final shut = closed?[d] ?? const <(int, int)>[];
      final key = '$blocks|$shut';
      final row = rows[key];
      rows[key] = (
        mask: (row?.mask ?? 0) | (1 << d),
        blocks: blocks,
        shut: shut,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final row in rows.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Builder(
              builder: (context) {
                final label = FeeWords.dayLabel(row.mask);
                final bar = _bar(context, row.blocks, row.shut, height);
                return label.length > 3
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(label, style: muted),
                          const SizedBox(height: 2),
                          bar,
                        ],
                      )
                    : Row(
                        children: [
                          SizedBox(width: 44, child: Text(label, style: muted)),
                          Expanded(child: bar),
                        ],
                      );
              },
            ),
          ),
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(left: 44),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final t in const [0, 6, 12, 18, 24])
                  Text('$t', style: muted),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HatchPainter extends CustomPainter {
  const _HatchPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = color.withValues(alpha: .6),
    );
    final line = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (var x = -size.height; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), line);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter old) => old.color != color;
}

/// F1's 「App 會顯示」: the vehicle being edited as riders read it. The rate
/// in force at [now] leads a time-of-day fee, its other periods and the
/// closed hours follow, and 請以現場公告為準 closes it (C16).
class _FormPreview extends StatelessWidget {
  const _FormPreview({
    required this.fee,
    required this.vehicle,
    required this.closed,
    required this.now,
  });
  final Fee fee;
  final FeeVehicle vehicle;
  final FeeClosedWeek? closed;
  final DateTime now;

  /// The minute of the week in Taiwan, Monday 00:00 first.
  int get _minute {
    final t = now.toUtc().add(const Duration(hours: 8));
    return (t.weekday - 1) * 1440 + t.hour * 60 + t.minute;
  }

  int? _current(List<FeePeriod> periods) {
    final at = _minute;
    for (final (i, p) in periods.indexed) {
      for (final (a, b) in feePeriodSpans(p.days, p.from, p.to)) {
        if ((a <= at && at < b) || at + weekMinutes < b) return i;
      }
    }
    return null;
  }

  static String _lines(Rate rate) =>
      feeRateLines(rate).map((l) => l.text).join('，');

  @override
  Widget build(BuildContext context) {
    final board = FeeBoardTheme.of(context);
    final known = _known(fee);
    var rate = _rateOf(known, vehicle);
    if (rate?.mode == FeeMode.sameAsScooter) rate = known.scooter;
    if (rate?.mode == FeeMode.sameAsCar) rate = known.car;
    final pending =
        _rateOf(fee, vehicle) != null && _rateOf(known, vehicle) == null;
    final periods = rate?.mode == FeeMode.byTime
        ? rate!.periods ?? const <FeePeriod>[]
        : const <FeePeriod>[];
    final current = _current(periods);
    final lead = periods.isEmpty ? null : periods[current ?? 0];
    final leadRate = lead?.rate ?? rate;
    final lines = leadRate == null || leadRate.mode == FeeMode.notApplicable
        ? const <FeeLine>[]
        : feeRateLines(leadRate);
    final main = pending
        ? '未提供'
        : rate == null
        ? '未提供'
        : rate.mode == FeeMode.notApplicable
        ? '不適用'
        : lines.isEmpty
        ? '未提供'
        : lines.first.text;
    String when(FeePeriod p) =>
        '${FeeWords.dayLabel(FeeWords.dayMask(p.days))} ${feePeriodTime(p.from, p.to)}';
    final sub = [
      if (lead != null) when(lead),
      for (final l in lines.skip(1)) l.text,
    ].join('，');
    final others = [
      for (final p in periods)
        if (!identical(p, lead)) p,
    ];
    final closedText = closed == null ? null : feeClosedText(closed!);
    final small = TextStyle(fontSize: 12, color: board.muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'App 會顯示',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: board.muted,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          key: const ValueKey('fee-preview'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: board.paper,
            border: Border.all(color: board.ink),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: board.ink),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: vehicle.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (current != null) const TextSpan(text: '　現在適用'),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(child: VehicleMark(vehicle)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        main,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                if (sub.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(sub, style: const TextStyle(fontSize: 14)),
                ],
                if (pending) ...[
                  const SizedBox(height: 4),
                  Text('${vehicle.label}的金額填好後才會顯示', style: small),
                ],
                if (others.isNotEmpty) ...[
                  Divider(height: 16, color: board.divider),
                  Text('其他開放時段', style: small),
                  for (final p in others)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              when(p),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _lines(p.rate),
                              textAlign: TextAlign.end,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                if (closedText != null) ...[
                  const SizedBox(height: 8),
                  Text('非開放時段', style: small),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: board.divider.withValues(alpha: .5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.block, size: 18, color: deniedColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            closedText,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${vehicle.label}不能停',
                            textAlign: TextAlign.end,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text('請以現場公告為準', style: small),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

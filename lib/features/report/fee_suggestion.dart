import 'package:material_ui/material_ui.dart';

import '../../models/fee.dart';
import '../../ui/fee_editor.dart';
import '../../ui/vehicle_marks.dart';

/// What riders read for a rate that is not known (decision 29).
const unconfirmedFeeText = '費率未確認，請依現場公告';

/// What a fee suggestion does to each vehicle it names (design §5.4): a new
/// rate, or null to clear it (改成未確認). A vehicle left out keeps its rate.
typedef FeeEdits = Map<FeeVehicle, Rate?>;

Rate? rateOf(Fee fee, FeeVehicle v) => switch (v) {
  FeeVehicle.scooter => fee.scooter,
  FeeVehicle.heavy => fee.heavy,
  FeeVehicle.car => fee.car,
};

/// [current] with [edits] applied: the fee the spot would have.
Fee feeAfter(Fee current, FeeEdits edits) => Fee(
  scooter: edits.containsKey(FeeVehicle.scooter)
      ? edits[FeeVehicle.scooter]
      : current.scooter,
  heavy: edits.containsKey(FeeVehicle.heavy)
      ? edits[FeeVehicle.heavy]
      : current.heavy,
  car: edits.containsKey(FeeVehicle.car) ? edits[FeeVehicle.car] : current.car,
);

/// The edits that change something: a vehicle set to its current rate, or
/// cleared when it had none, is no change.
FeeEdits effectiveEdits(Fee current, FeeEdits edits) => {
  for (final MapEntry(key: v, value: rate) in edits.entries)
    if (rate != rateOf(current, v)) v: rate,
};

/// `proposed.fee` for [edits]: only the vehicles that change, null for a
/// cleared one (§7 item 3); the others keep their rates on review.
Map<String, Object?> proposedFee(Fee current, FeeEdits edits) => {
  for (final MapEntry(key: v, value: rate) in effectiveEdits(
    current,
    edits,
  ).entries)
    v.wire: rate?.toJson(),
};

/// One vehicle's rate as riders read it in [fee], or [unconfirmedFeeText].
String rateText(Fee fee, FeeVehicle v) =>
    fee.riderText(v.wire) ?? unconfirmedFeeText;

/// The lines of 你要改的內容: one per changed vehicle, from today's rate to
/// the suggested one. A rate not filled in yet is left out, so it never
/// reads as 0 元.
List<String> feeChangeLines(Fee current, FeeEdits edits) {
  final after = feeAfter(current, edits);
  final incomplete = incompleteEdits(edits);
  return [
    for (final v in FeeVehicle.values)
      if (effectiveEdits(current, edits).containsKey(v) &&
          !incomplete.contains(v))
        '${v.label}費率：${rateText(current, v)} → ${rateText(after, v)}',
  ];
}

/// The vehicles a suggestion keeps, as one line (普通機車、汽車維持目前).
String? feeKeptLine(Fee current, FeeEdits edits) {
  final changed = effectiveEdits(current, edits);
  if (changed.isEmpty) return null;
  final kept = [
    for (final v in FeeVehicle.values)
      if (!changed.containsKey(v)) v.label,
  ];
  return kept.isEmpty ? null : '${kept.join('、')}維持目前';
}

/// The vehicles whose suggested rate is still missing an amount.
List<FeeVehicle> incompleteEdits(FeeEdits edits) => [
  for (final MapEntry(key: v, value: rate) in edits.entries)
    if (rate != null && !validRate(rate.toJson(), v.wire)) v,
];

/// 修改建議：收費 (design canvas SuggestFee): every vehicle with today's rate
/// and 修改; one open at a time with its rate's fields; 改成未確認 for a
/// vehicle that has a rate. Untouched vehicles read 維持目前 and are not
/// sent. [errors] are precheck hints per vehicle, under its card.
class FeeSuggestionEditor extends StatefulWidget {
  const FeeSuggestionEditor({
    super.key,
    required this.current,
    required this.edits,
    required this.onChanged,
    this.errors = const {},
  });
  final Fee current;
  final FeeEdits edits;
  final ValueChanged<FeeEdits> onChanged;
  final Map<FeeVehicle, String> errors;

  @override
  State<FeeSuggestionEditor> createState() => _FeeSuggestionEditorState();
}

class _FeeSuggestionEditorState extends State<FeeSuggestionEditor> {
  FeeVehicle? open;

  FeeEdits get edits => widget.edits;

  void _set(FeeVehicle v, Rate? rate) => widget.onChanged({...edits, v: rate});

  void _keep(FeeVehicle v) {
    widget.onChanged({...edits}..remove(v));
    setState(() => open = null);
  }

  @override
  Widget build(BuildContext context) {
    final after = feeAfter(widget.current, edits);
    final changed = effectiveEdits(widget.current, edits);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final v in FeeVehicle.values) ...[
          _VehicleCard(
            vehicle: v,
            currentText: rateText(widget.current, v),
            hasCurrent: rateOf(widget.current, v) != null,
            changed: changed.containsKey(v),
            cleared: changed.containsKey(v) && changed[v] == null,
            afterText:
                validRate(rateOf(after, v)?.toJson(), v.wire) ||
                    rateOf(after, v) == null
                ? rateText(after, v)
                : '還沒填完',
            open: open == v,
            error: widget.errors[v],
            onEdit: () => setState(() => open = open == v ? null : v),
            onClear: () {
              _set(v, null);
              setState(() => open = null);
            },
            onKeep: () => _keep(v),
            editor: RateEditor(
              key: ValueKey('suggest-rate-${v.wire}'),
              vehicle: v,
              value: rateOf(after, v),
              fee: after,
              onChanged: (rate) => _set(v, rate),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({
    required this.vehicle,
    required this.currentText,
    required this.hasCurrent,
    required this.changed,
    required this.cleared,
    required this.afterText,
    required this.open,
    required this.error,
    required this.onEdit,
    required this.onClear,
    required this.onKeep,
    required this.editor,
  });
  final FeeVehicle vehicle;
  final String currentText, afterText;
  final bool hasCurrent, changed, cleared, open;
  final String? error;
  final VoidCallback onEdit, onClear, onKeep;
  final Widget editor;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final w = vehicle.wire;
    return Material(
      key: ValueKey('suggest-fee-$w'),
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: changed || open ? colors.primary : colors.outlineVariant,
          width: changed || open ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
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
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey('suggest-edit-$w'),
                    onPressed: onEdit,
                    child: Text(
                      open ? '收合' : '修改',
                      semanticsLabel: '${open ? '收合' : '修改'}${vehicle.label}費率',
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 35, end: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (changed) ...[
                    Text(
                      '改成：$afterText',
                      key: ValueKey('suggest-after-$w'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '目前：$currentText',
                      style: muted.copyWith(fontSize: 12),
                    ),
                  ] else
                    Text(
                      '維持目前：$currentText',
                      key: ValueKey('suggest-kept-$w'),
                      style: muted,
                    ),
                  if (error case final error?) ...[
                    const SizedBox(height: 6),
                    Semantics(
                      liveRegion: true,
                      child: Row(
                        key: ValueKey('suggest-error-$w'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 18,
                            color: colors.error,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              error,
                              style: TextStyle(color: colors.error),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (open) ...[const SizedBox(height: 8), editor],
                  if (hasCurrent && !cleared || changed)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (hasCurrent && !cleared)
                            OutlinedButton(
                              key: ValueKey('suggest-clear-$w'),
                              onPressed: onClear,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 48),
                                foregroundColor: colors.onSurface,
                              ),
                              child: Text(
                                '改成未確認',
                                semanticsLabel: '${vehicle.label}費率改成未確認',
                              ),
                            ),
                          if (changed)
                            TextButton(
                              key: ValueKey('suggest-keep-$w'),
                              onPressed: onKeep,
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 48),
                              ),
                              child: Text(
                                '維持目前',
                                semanticsLabel: '${vehicle.label}費率維持目前',
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
    );
  }
}

import '../../models/fee.dart';
import '../../ui/vehicle_marks.dart';

/// What a suggestion's summary reads for a rate that is not known
/// (PM_ANS_20261101_56).
const unconfirmedFeeText = '未提供';

/// What a fee suggestion does to each vehicle it names (design §5.4): a new
/// rate, or null to clear it. A vehicle left out keeps its rate.
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

/// The vehicles whose suggested rate is still missing an amount, or a
/// rule a new write answers (#188 layer 2: 跨日怎麼收, 上限何時重新計算,
/// 停到下一個時段時).
List<FeeVehicle> incompleteEdits(FeeEdits edits) => [
  for (final MapEntry(key: v, value: rate) in edits.entries)
    if (rate != null &&
        !(validRate(rate.toJson(), v.wire) && rateWriteComplete(rate.toJson())))
      v,
];

/// `proposed` of a suggestion that leaves the spot's fee as [next]: only the
/// vehicles that change, and the text beside the fee, built from it so the
/// two never disagree. Past 200 characters the server takes only the text
/// of the rates sent (the review recomputes it).
Map<String, Object?> feeProposal(Fee current, Fee next) {
  final edits = <FeeVehicle, Rate?>{
    for (final v in FeeVehicle.values) v: rateOf(next, v),
  };
  final fee = proposedFee(current, edits);
  final after = feeNoteOf(next);
  return {
    'fee': fee,
    'fee_note': after.length <= 200
        ? after
        : feeNoteOfJson({
            for (final MapEntry(:key, :value) in fee.entries) key: ?value,
          }),
  };
}

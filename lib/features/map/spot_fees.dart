import 'dart:async';

import '../../domain/eligibility.dart';
import '../../domain/parking_decision.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_board.dart';
import '../../ui/vehicle_marks.dart';
import 'map_legend.dart' show spotMarkerColor;
import 'spot_details.dart';

/// The rider's rate at this moment, as the details' summary row shows it
/// (canvas 「詳情摘要：依目前時間的費率」, decision 26).
@immutable
class FeeNow {
  const FeeNow({required this.label, required this.main, this.caption});

  /// 機車費率, 大型重機費率・20:00–08:00, or 收費資訊 for text that is not
  /// the vehicle's own rate.
  final String label;
  final FeeLine main;
  final String? caption;

  @override
  String toString() => '$label | $main | $caption';
}

const _unconfirmedIcon = Icons.help_outline;
const _seeBoard = '往下看完整收費公告牌';

/// 機車費率 for an ordinary scooter (decision 28), 大型重機費率 for a heavy bike.
String feeNowLabel(VehicleType vehicle) =>
    vehicle == VehicleType.scooter ? '機車費率' : '大型重機費率';

/// The time of day in Taiwan, in minutes, and the weekday bit (Monday 1).
({int minute, int day}) _taipei(DateTime now) {
  final t = now.toUtc().add(const Duration(hours: 8));
  return (minute: t.hour * 60 + t.minute, day: 1 << (t.weekday - 1));
}

int? _minutes(String? hhmm) {
  if (hhmm == null || !RegExp(timePattern).hasMatch(hhmm)) return null;
  return int.parse(hhmm.substring(0, 2)) * 60 + int.parse(hhmm.substring(3));
}

/// Whether [p] covers [minute] of a day it applies to. Days are read by
/// today's weekday (decision 26), as the board groups them, so a period
/// across midnight covers both ends of the same day.
bool _covers(FeePeriod p, int minute) {
  if (p.from == null && p.to == null) return true;
  final from = _minutes(p.from), to = _minutes(p.to);
  if (from == null || to == null || from == to) return false;
  return from < to
      ? minute >= from && minute < to
      : minute >= from || minute < to;
}

/// A caption drops the board's bracketed rule (零時重算, 延長時間未確認): the
/// full board below keeps it.
String _short(String text) => text.replaceFirst(RegExp(r'（[^（）]*）$'), '');

/// [vehicle]'s rate in [fee] with a follow worked out: the rate it reads
/// and the factor; null when unconfirmed.
(Rate, int)? _resolved(Fee fee, FeeVehicle vehicle) {
  if (fee.textOf(vehicle.wire) == null) return null;
  final rate = switch (vehicle) {
    FeeVehicle.scooter => fee.scooter,
    FeeVehicle.heavy => fee.heavy,
    FeeVehicle.car => fee.car,
  }!;
  if (!rate.mode.follows) return (rate, 100);
  final target = rate.mode == FeeMode.sameAsScooter ? fee.scooter : fee.car;
  return (target!, rate.factorPct ?? 100);
}

/// [vehicle]'s rate in [fee] at [now]: a by_time rate's current period
/// (its time without 現在 or 隔日), with the next period's start; a time no
/// period covers reads 此時段費率未確認 and points to the board.
FeeNow feeNowOf(Fee fee, VehicleType vehicle, DateTime now) {
  final label = feeNowLabel(vehicle);
  final v = FeeVehicle.of(vehicle);
  final resolved = _resolved(fee, v);
  if (resolved == null) {
    final follows = v == FeeVehicle.heavy && (fee.heavy?.mode.follows ?? false);
    return FeeNow(
      label: label,
      main: FeeLine(
        follows ? '費率未提供' : '費率未確認，請依現場公告',
        tone: FeeTone.unconfirmed,
        icon: _unconfirmedIcon,
      ),
    );
  }
  final (rate, pct) = resolved;
  if (rate.mode != FeeMode.byTime) {
    final lines = feeRateLines(rate, pct);
    return FeeNow(
      label: label,
      main: lines.first,
      caption: lines.length > 1 ? _short(lines[1].text) : null,
    );
  }
  final at = _taipei(now);
  final today = [
    for (final p in rate.periods ?? const <FeePeriod>[])
      if (FeeWords.dayMask(p.days) & at.day != 0) p,
  ];
  final current = today.where((p) => _covers(p, at.minute)).firstOrNull;
  final lines = current == null
      ? const <FeeLine>[]
      : feeRateLines(current.rate, pct);
  if (current == null || lines.first.tone == FeeTone.unconfirmed) {
    return FeeNow(
      label: label,
      main: const FeeLine(
        '此時段費率未確認',
        tone: FeeTone.unconfirmed,
        icon: _unconfirmedIcon,
      ),
      caption: _seeBoard,
    );
  }
  final time = current.from == null ? '全天' : '${current.from}–${current.to}';
  // The next change: where this period ends, on the day it ends; or, for
  // a period across midnight entered before midnight, 00:00 when the new
  // day's periods differ (days are read by the current weekday, decision
  // 26), whichever comes first (Codex P2).
  final periods = rate.periods ?? const <FeePeriod>[];
  final end = _minutes(current.to);
  final from = _minutes(current.from);
  final tomorrow =
      from != null && end != null && from > end && at.minute >= from;
  final nextDay = at.day == 64 ? 1 : at.day << 1;
  FeePeriod? on(int day, int minute) => periods
      .where((p) => FeeWords.dayMask(p.days) & day != 0 && _covers(p, minute))
      .firstOrNull;
  String? nextAt;
  FeePeriod? next;
  if (tomorrow) {
    final midnight = on(nextDay, 0);
    if (midnight == null || midnight.rate != current.rate) {
      (nextAt, next) = ('00:00', midnight);
    } else {
      (nextAt, next) = (current.to, on(nextDay, end));
    }
  } else if (end != null) {
    (nextAt, next) = (current.to, on(at.day, end));
  }
  final nextLines = next == null ? null : feeRateLines(next.rate, pct);
  final free = current.rate.mode == FeeMode.free;
  final caption = [
    if (!free && lines.length > 1) _short(lines[1].text),
    if (nextLines != null && nextLines.first.tone != FeeTone.unconfirmed)
      '$nextAt 起${next!.rate.mode == FeeMode.free ? '不收費' : nextLines.first.text}',
  ].join('・');
  return FeeNow(
    label: '$label・$time',
    main: free ? const FeeLine('此時段不收費', tone: FeeTone.main) : lines.first,
    caption: caption.isEmpty ? null : caption,
  );
}

/// Text that only says to read the posted notice: read as unconfirmed,
/// which always says 費率未確認，請依現場公告 (decision 29).
bool _placeholder(String text) =>
    const {'', '依現場公告', '請依現場公告'}.contains(text.trim());

/// The summary row's rate for the spot: its own structured rate, a single
/// zone's, or the text riders have read until now.
FeeNow spotFeeNow(ParkingSpot spot, VehicleType vehicle, DateTime now) {
  final fee = hasZoneFees(spot)
      ? (spot.zones.length == 1 ? spot.zones.single.fee : null)
      : spot.fee;
  if (fee != null) return feeNowOf(fee, vehicle, now);
  final text = spotFeeSummary(spot, vehicle);
  if (text == '依分區計費') {
    return const FeeNow(
      label: '收費資訊',
      main: FeeLine('依分區計費', tone: FeeTone.main),
      caption: _seeBoard,
    );
  }
  if (text == '費率未確認' || _placeholder(text)) {
    // Decision 29: an unconfirmed rate always reads the same.
    return FeeNow(
      label: spotFeeIsVehicleRate(spot) ? feeNowLabel(vehicle) : '收費資訊',
      main: const FeeLine(
        '費率未確認，請依現場公告',
        tone: FeeTone.unconfirmed,
        icon: _unconfirmedIcon,
      ),
    );
  }
  return FeeNow(
    label: spotFeeIsVehicleRate(spot) ? feeNowLabel(vehicle) : '收費資訊',
    main: FeeLine(text, tone: FeeTone.main),
  );
}

/// The summary row's fee half (canvas SummaryNow): label, the rate now in
/// bold, one caption line.
class FeeNowSummary extends StatelessWidget {
  const FeeNowSummary({super.key, required this.now});
  final FeeNow now;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    final unconfirmed = now.main.tone == FeeTone.unconfirmed;
    final mainStyle = text.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      height: 1.35,
      color: unconfirmed ? colors.onSurfaceVariant : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Semantics(
      key: const ValueKey('fee-now'),
      container: true,
      label: [now.label, now.main.text, ?now.caption].join('，'),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(now.label, key: const ValueKey('fee-now-label'), style: muted),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                if (now.main.icon case final icon?) ...[
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Icon(
                      icon,
                      size: 17,
                      color: unconfirmed ? colors.onSurfaceVariant : null,
                    ),
                  ),
                  const TextSpan(text: ' '),
                ],
                TextSpan(text: now.main.text),
              ],
            ),
            key: const ValueKey('fee-now-main'),
            style: mainStyle,
          ),
          if (now.caption case final caption?) ...[
            const SizedBox(height: 4),
            Text(caption, key: const ValueKey('fee-now-caption'), style: muted),
          ],
        ],
      ),
    );
  }
}

/// The fee vehicles a zone's board lists (§2.6 projection): a heavy-bike
/// bay only the heavy bike; otherwise the motorcycle classes the zone does
/// not exclude, and the car where the bay is a car's or the fee names it.
/// Null when the zone says nothing about its bays.
List<FeeVehicle>? zoneFeeVehicles(ParkingCondition? c, Fee? fee) {
  if (c == null) return null;
  if (c.bay == Bay.heavy) return const [FeeVehicle.heavy];
  return [
    if ((c.bay != Bay.car && c.allow?.scooter != false) ||
        (c.bay == Bay.car && c.allow?.scooter == true))
      FeeVehicle.scooter,
    if (c.allow?.heavy != false) FeeVehicle.heavy,
    if (c.bay == Bay.car || fee?.car != null) FeeVehicle.car,
  ];
}

/// A street bay's vehicles: its condition's, the spot's flags excluding a
/// class it marks closed.
List<FeeVehicle>? spotFeeVehicles(ParkingSpot spot) {
  final c = spot.condition ?? conditionOf(spot.spaceType);
  if (c == null) return null;
  if (c.bay == Bay.heavy) return const [FeeVehicle.heavy];
  return [
    if ((c.bay != Bay.car && spot.scooterAllowed != false) ||
        spot.fee?.scooter != null)
      FeeVehicle.scooter,
    if (spot.heavyAllowed != false) FeeVehicle.heavy,
    if (c.bay == Bay.car || spot.fee?.car != null) FeeVehicle.car,
  ];
}

/// One board of the section: a zone's (with its name) or the spot's.
@immutable
class FeeSectionBoard {
  const FeeSectionBoard({
    this.title,
    this.fee,
    this.vehicles,
    this.legacy = const [],
    this.trialEnded,
  });

  /// The zone's name, 全場 for a lot-wide rate; null for a street bay.
  final String? title;
  final Fee? fee;
  final List<FeeVehicle>? vehicles;

  /// Text rates from before structured fees: (vehicle or null, text).
  final List<(FeeVehicle?, String)> legacy;

  /// The trial notice this zone's rate belongs to ended on this day.
  final String? trialEnded;
}

/// A zone's text rates; an empty text is a vehicle the zone serves that
/// the texts leave out (費率未確認, never another vehicle's price).
List<(FeeVehicle?, String)> _zoneLegacy(ParkingZone z, {bool carOnly = false}) {
  bool has(String s) => !_placeholder(s);
  final texts = {
    FeeVehicle.scooter: carOnly ? '' : z.scooterFeeNote.trim(),
    FeeVehicle.heavy: carOnly ? '' : z.heavyFeeNote.trim(),
    FeeVehicle.car: z.carFeeNote.trim(),
  };
  final named = texts.values.any(has);
  final serves = carOnly
      ? const [FeeVehicle.car]
      : zoneFeeVehicles(z.condition ?? zoneConditionOf(z.access), null) ??
            const [FeeVehicle.scooter, FeeVehicle.heavy];
  final note = z.feeNote.trim();
  return [
    if (named)
      for (final v in FeeVehicle.values)
        if (has(texts[v]!)) (v, texts[v]!) else if (serves.contains(v)) (v, ''),
    if (!carOnly && has(note) && !texts.values.contains(note)) (null, note),
  ];
}

/// The boards the details' 收費 section lists, in the lot's zone order
/// (design §8.4). A zone's own rate first; the lot's when no zone has one,
/// listed once as 全場 with only zones' own car text after it; text rates
/// where nothing is structured. [decision] marks a zone whose trial ended.
List<FeeSectionBoard> feeSectionBoards(
  ParkingSpot spot,
  ParkingDecision? decision,
) {
  String? ended(int i) {
    final zones = decision?.zones ?? const <ZoneDecision>[];
    if (i >= zones.length) return null;
    final n = zones[i].notice;
    return n != null && n.expired ? n.expiresOn : null;
  }

  String name(ParkingZone z) => z.name.trim().isEmpty ? '分區' : z.name.trim();
  if (spot.zones.isEmpty) {
    final legacy = _placeholder(spot.feeNote) ? '' : spot.feeNote.trim();
    return [
      FeeSectionBoard(
        fee: spot.fee,
        vehicles: spot.fee == null ? null : spotFeeVehicles(spot),
        legacy: [if (spot.fee == null && legacy.isNotEmpty) (null, legacy)],
      ),
    ];
  }
  if (lotWideFee(spot) case final fee?) {
    return [
      FeeSectionBoard(title: '全場', fee: fee),
      for (final (i, z) in spot.zones.indexed)
        if (z.carFeeNote.trim().isNotEmpty)
          FeeSectionBoard(
            title: name(z),
            legacy: _zoneLegacy(z, carOnly: true),
            trialEnded: ended(i),
          ),
    ];
  }
  final boards = [
    for (final (i, z) in spot.zones.indexed)
      if (z.fee != null || _zoneLegacy(z).isNotEmpty)
        FeeSectionBoard(
          title: name(z),
          fee: z.fee,
          vehicles: z.fee == null
              ? null
              : zoneFeeVehicles(
                  z.condition ?? zoneConditionOf(z.access),
                  z.fee,
                ),
          legacy: z.fee == null
              ? _zoneLegacy(z)
              : [
                  // A car price stays as text until the fee has one (as
                  // ParkingZone.carFeeText reads it).
                  if (z.fee!.car == null && !_placeholder(z.carFeeNote))
                    (FeeVehicle.car, z.carFeeNote.trim()),
                ],
          trialEnded: ended(i),
        ),
  ];
  if (boards.isNotEmpty) return boards;
  // No zone states a rate: the spot's text, or 費率未確認.
  final legacy = _placeholder(spot.feeNote) ? '' : spot.feeNote.trim();
  return [
    FeeSectionBoard(legacy: [if (legacy.isNotEmpty) (null, legacy)]),
  ];
}

/// The details' 收費 section (canvas 「詳情：分區收費公告牌」 and
/// 「收費區」): per zone a heading and a notice board, the rider's vehicle
/// first; side by side, two at most, where the sheet is wide.
class SpotFees extends StatelessWidget {
  const SpotFees({
    super.key,
    required this.spot,
    required this.vehicle,
    this.decision,
    this.extraNote = '',
  });
  final ParkingSpot spot;
  final VehicleType vehicle;
  final ParkingDecision? decision;

  /// The spot's own fee text when it adds to the zones' rates.
  final String extraNote;

  @override
  Widget build(BuildContext context) {
    final boards = feeSectionBoards(spot, decision);
    final first = FeeVehicle.of(vehicle);
    final children = [
      for (final b in boards) _SectionBoard(board: b, first: first),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final two = children.length >= 2 && constraints.maxWidth >= 560;
        final width = two
            ? (constraints.maxWidth - 16) / 2
            : constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 14,
              children: [
                for (final c in children) SizedBox(width: width, child: c),
              ],
            ),
            if (extraNote.trim().isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                extraNote,
                key: const ValueKey('fee-extra-note'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(height: 1.5),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _SectionBoard extends StatelessWidget {
  const _SectionBoard({required this.board, required this.first});
  final FeeSectionBoard board;
  final FeeVehicle first;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final vehicles = board.vehicles;
    final shown = vehicles == null || vehicles.contains(first) ? first : null;
    final textCar =
        board.fee != null && board.legacy.any((l) => l.$1 == FeeVehicle.car);
    final Widget plate = board.legacy.isNotEmpty && board.fee == null
        ? _LegacyBoard(board.legacy, first: first)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FeeBoard(
                fee: board.fee ?? const Fee(),
                first: board.fee == null ? null : shown,
                vehicles: board.fee == null || !textCar
                    ? vehicles
                    : [
                        for (final v
                            in vehicles ??
                                const [FeeVehicle.scooter, FeeVehicle.heavy])
                          if (v != FeeVehicle.car) v,
                      ],
              ),
              if (textCar) ...[
                const SizedBox(height: 8),
                _LegacyBoard(board.legacy, first: first),
              ],
            ],
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (board.title case final title?)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        if (board.trialEnded case final day?)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              key: const ValueKey('fee-trial-ended'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.calendar_today_outlined,
                    size: 16,
                    color: spotMarkerColor(EligibilityStatus.conditional),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '試辦期間費率，試辦已於 $day 到期，請看現場公告',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      height: 1.45,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? colors.onSurface
                          : spotMarkerColor(EligibilityStatus.conditional),
                    ),
                  ),
                ),
              ],
            ),
          ),
        plate,
      ],
    );
  }
}

/// Text rates in the board's frame: per vehicle when the text names one,
/// otherwise the spot's or zone's note as it was given.
class _LegacyBoard extends StatelessWidget {
  const _LegacyBoard(this.lines, {required this.first});
  final List<(FeeVehicle?, String)> lines;
  final FeeVehicle first;

  @override
  Widget build(BuildContext context) {
    final colors = FeeBoardTheme.of(context);
    final ordered = [
      ...lines.where((l) => l.$1 == first),
      ...lines.where((l) => l.$1 != first),
    ];
    return Container(
      key: const ValueKey('fee-legacy-board'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border.all(color: colors.ink),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: colors.ink, fontSize: 14, height: 1.4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, (vehicle, text)) in ordered.indexed)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: i < ordered.length - 1
                      ? Border(bottom: BorderSide(color: colors.divider))
                      : null,
                ),
                child: vehicle == null
                    ? Text(text)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: VehicleMark(vehicle, color: colors.ink),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            vehicle.label,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: text.isEmpty
                                ? Text.rich(
                                    TextSpan(
                                      children: [
                                        WidgetSpan(
                                          alignment:
                                              PlaceholderAlignment.middle,
                                          child: Icon(
                                            _unconfirmedIcon,
                                            size: 15,
                                            color: colors.unconfirmed,
                                          ),
                                        ),
                                        const TextSpan(text: ' 費率未確認'),
                                      ],
                                    ),
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: colors.unconfirmed,
                                    ),
                                  )
                                : Text(
                                    text,
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
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

/// Rebuilds [builder] at the start of every minute by [clock], so a rate
/// summary on an open sheet turns to the next period on time (Codex P2).
class MinuteTicker extends StatefulWidget {
  const MinuteTicker({super.key, required this.clock, required this.builder});
  final DateTime Function() clock;
  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<MinuteTicker> {
  Timer? timer;

  void schedule() {
    timer?.cancel();
    final now = widget.clock();
    final wait =
        const Duration(minutes: 1) -
        Duration(seconds: now.second, milliseconds: now.millisecond);
    timer = Timer(wait, () {
      if (!mounted) return;
      setState(() {});
      schedule();
    });
  }

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, widget.clock());
}

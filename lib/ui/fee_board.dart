import 'package:material_ui/material_ui.dart';

import '../models/fee.dart';
import 'vehicle_marks.dart';

/// Colours of the fee notice board: a white plate with ink lines, kept white
/// in dark mode like the posted notice at a lot's entrance (design §8.3).
/// The app uses the defaults; the admin site passes its asphalt and blue.
@immutable
class FeeBoardTheme extends ThemeExtension<FeeBoardTheme> {
  const FeeBoardTheme({
    this.paper = const Color(0xffffffff),
    this.ink = const Color(0xff16313a),
    this.muted = const Color(0xff4a5a61),
    this.unconfirmed = const Color(0xff59646c),
    this.divider = const Color(0xffe3eaed),
    this.accent = const Color(0xff176273),
  });
  final Color paper, ink, muted, unconfirmed, divider;

  /// The editor preview's 「App 會顯示」 label.
  final Color accent;

  static FeeBoardTheme of(BuildContext context) =>
      Theme.of(context).extension<FeeBoardTheme>() ?? const FeeBoardTheme();

  @override
  FeeBoardTheme copyWith({
    Color? paper,
    Color? ink,
    Color? muted,
    Color? unconfirmed,
    Color? divider,
    Color? accent,
  }) => FeeBoardTheme(
    paper: paper ?? this.paper,
    ink: ink ?? this.ink,
    muted: muted ?? this.muted,
    unconfirmed: unconfirmed ?? this.unconfirmed,
    divider: divider ?? this.divider,
    accent: accent ?? this.accent,
  );

  @override
  FeeBoardTheme lerp(FeeBoardTheme? other, double t) => other ?? this;
}

/// How a board line reads: the amount itself, a rule beside it, or a gap
/// written out as unconfirmed (question mark and grey, never colour alone).
enum FeeTone { main, note, unconfirmed }

/// One line of a vehicle's rate on the board.
@immutable
class FeeLine {
  const FeeLine(this.text, {this.tone = FeeTone.note, this.icon});
  final String text;
  final FeeTone tone;
  final IconData? icon;

  @override
  bool operator ==(Object other) =>
      other is FeeLine &&
      other.text == text &&
      other.tone == tone &&
      other.icon == icon;

  @override
  int get hashCode => Object.hash(text, tone, icon);

  @override
  String toString() => '${tone.name}:$text';
}

/// One row of a time-of-day table: the time, then the rate's lines.
@immutable
class FeePeriodRow {
  const FeePeriodRow(this.time, this.lines);
  final String time;
  final List<FeeLine> lines;
}

/// The rows of the days a group of periods covers; [label] (平日, 週六) is
/// null when the only group is every day.
@immutable
class FeeDayGroup {
  const FeeDayGroup(this.label, this.rows);
  final String? label;
  final List<FeePeriodRow> rows;
}

/// One vehicle on the board: [headline] beside its name when the rate fits
/// one line, the other [lines] below; a time-of-day rate as [groups] and
/// the cross-period rule as [footer].
@immutable
class FeeVehicleBoard {
  const FeeVehicleBoard(
    this.vehicle, {
    this.headline,
    this.lines = const [],
    this.groups = const [],
    this.footer,
  });
  final FeeVehicle vehicle;
  final FeeLine? headline;
  final List<FeeLine> lines;
  final List<FeeDayGroup> groups;
  final FeeLine? footer;
}

const _unconfirmedIcon = Icons.help_outline;

/// A vehicle or period without a confirmed rate (decision 54): every line
/// says only this, and the board ends with [feeBoardPostedNote] once. A car
/// without a structured rate reads it too (decision 45): the details never
/// fall back to a zone's old car text.
const feeUnconfirmed = '費率未確認';

/// The board's last line when any line is unconfirmed (decision 54).
const feeBoardPostedNote = '未確認的費率請依現場公告';
const _timerIcon = Icons.timer_outlined;
const _nightIcon = Icons.bedtime_outlined;
const _extendIcon = Icons.add_circle_outline;

/// The vehicles of [fee] as the board lays them out (design §8.3–8.4):
/// [first] (the rider's or the edited vehicle) first, then the known ones in
/// order, and the heavy bike always, since the sentence names it when
/// unknown too; or exactly [vehicles] when given. A follow shows its amounts worked out (#140). Empty when no
/// vehicle is known: the board then reads 費率未確認，請依現場公告.
List<FeeVehicleBoard> feeBoardOf(
  Fee fee, {
  FeeVehicle? first,
  List<FeeVehicle>? vehicles,
}) {
  if (vehicles != null) {
    // The vehicles a zone serves, known or not (canvas 路邊限時格).
    return [
      for (final v in {?first, ...vehicles}) _vehicleBoard(fee, v),
    ];
  }
  final known = [
    for (final v in FeeVehicle.values)
      if (fee.textOf(v.wire) != null) v,
  ];
  // As the sentence: a heavy follow of an unknown rate still reads 未提供.
  final follows = fee.heavy?.mode.follows ?? false;
  if (known.isEmpty && !follows && first == null) return const [];
  final shown = {
    ?first,
    for (final v in FeeVehicle.values)
      if (known.contains(v) || v == FeeVehicle.heavy) v,
  };
  return [for (final v in shown) _vehicleBoard(fee, v)];
}

FeeVehicleBoard _vehicleBoard(Fee fee, FeeVehicle vehicle) {
  final rate = switch (vehicle) {
    FeeVehicle.scooter => fee.scooter,
    FeeVehicle.heavy => fee.heavy,
    FeeVehicle.car => fee.car,
  };
  if (fee.textOf(vehicle.wire) == null) {
    return FeeVehicleBoard(
      vehicle,
      headline: FeeLine(
        rate?.mode.follows ?? false ? '費率未提供' : feeUnconfirmed,
        tone: FeeTone.unconfirmed,
        icon: _unconfirmedIcon,
      ),
    );
  }
  var target = rate!, pct = 100;
  if (rate.mode.follows) {
    target = (rate.mode == FeeMode.sameAsScooter ? fee.scooter : fee.car)!;
    pct = rate.factorPct ?? 100;
  }
  final d = _describe(target, pct);
  return FeeVehicleBoard(
    vehicle,
    headline: d.headline,
    lines: d.lines,
    groups: d.groups,
    footer: d.footer,
  );
}

typedef _Described = ({
  FeeLine? headline,
  List<FeeLine> lines,
  List<FeeDayGroup> groups,
  FeeLine? footer,
});

_Described _plain(FeeLine headline, [List<FeeLine> lines = const []]) =>
    (headline: headline, lines: lines, groups: const [], footer: null);

/// A rate in the words of [feeNoteOf], split into lines.
_Described _describe(Rate r, int pct) {
  String money(int? v) => FeeWords.money(v, pct);
  switch (r.mode) {
    case FeeMode.free:
      return _plain(const FeeLine('免費', tone: FeeTone.main));
    case FeeMode.hourly:
      var base = '${FeeWords.every(r.perMinutes)} ${money(r.amount)} 元';
      if (r.unitMinutes case final unit?) {
        base += '（以 ${FeeWords.span(unit)}計）';
      }
      final cap = <FeeLine>[
        if (r.dailyCap case final cap?) ...[
          FeeLine(
            '當日上限 ${money(cap)} 元'
            '${r.capReset == null ? '' : '（${FeeWords.reset(r.capReset)}）'}',
          ),
          if (r.capReset == null)
            const FeeLine(
              '上限計算方式未確認',
              tone: FeeTone.unconfirmed,
              icon: _unconfirmedIcon,
            ),
        ],
      ];
      if (r.freeMinutes case final free?) {
        return (
          headline: null,
          lines: [
            FeeLine(
              '首 ${FeeWords.span(free)} 0 元',
              tone: FeeTone.main,
              icon: _timerIcon,
            ),
            FeeLine('之後$base', tone: FeeTone.main),
            ...cap,
          ],
          groups: const [],
          footer: null,
        );
      }
      return _plain(FeeLine(base, tone: FeeTone.main), cap);
    case FeeMode.perVisit:
      final ext = r.extension;
      final extension = [
        if (ext != null)
          FeeLine(
            '可付 ${money(ext.amount)} 元延長 ${ext.maxTimes} 次'
            '${ext.minutes == null ? '（延長時間未確認）' : '（每次 ${FeeWords.span(ext.minutes!)}）'}',
            icon: _extendIcon,
          ),
      ];
      if (r.amount == 0 && r.maxMinutes != null) {
        // 首段 0 元: a toll bay's first minutes, never written 免費 (§2.3).
        return (
          headline: null,
          lines: [
            FeeLine(
              '首 ${FeeWords.span(r.maxMinutes!)} 0 元',
              tone: FeeTone.main,
              icon: _timerIcon,
            ),
            ...extension,
          ],
          groups: const [],
          footer: null,
        );
      }
      final limit = r.maxMinutes == null
          ? ''
          : '（${FeeWords.span(r.maxMinutes!)}內）';
      return _plain(
        FeeLine('每次 ${money(r.amount)} 元$limit', tone: FeeTone.main),
        [
          switch (r.renew) {
            Renew.midnight => const FeeLine('隔日另計', icon: _nightIcon),
            Renew.none => FeeLine(
              r.maxMinutes == null ? '停多久都只收一次' : '有效時間內只收一次',
            ),
            null => const FeeLine(
              '隔日是否另計未確認',
              tone: FeeTone.unconfirmed,
              icon: _unconfirmedIcon,
            ),
          },
          ...extension,
        ],
      );
    case FeeMode.daily:
      final reset = FeeWords.reset(r.capReset);
      return _plain(
        FeeLine(
          '每日 ${money(r.amount)} 元${reset == null ? '' : '（$reset）'}',
          tone: FeeTone.main,
        ),
      );
    case FeeMode.byTime:
      final periods = r.periods ?? const [];
      final visits = periods
          .where((p) => p.rate.mode == FeeMode.perVisit)
          .length;
      return (
        headline: null,
        lines: const [],
        groups: _groups(periods, pct),
        footer: switch (r.crossPeriod) {
          CrossPeriod.eachPeriod => const FeeLine('跨時段分別計費'),
          CrossPeriod.entryOnly => const FeeLine('依進場時段計費'),
          null when visits >= 2 => const FeeLine(
            '跨時段計費方式未確認',
            tone: FeeTone.unconfirmed,
            icon: _unconfirmedIcon,
          ),
          null => null,
        },
      );
    case FeeMode.posted || FeeMode.sameAsScooter || FeeMode.sameAsCar:
      return _plain(
        const FeeLine(
          feeUnconfirmed,
          tone: FeeTone.unconfirmed,
          icon: _unconfirmedIcon,
        ),
      );
  }
}

const _unconfirmedRow = [
  FeeLine(feeUnconfirmed, tone: FeeTone.unconfirmed, icon: _unconfirmedIcon),
];

/// The periods grouped by the days they cover, in order of first appearance
/// (平日 and 假日, single weekdays only when a period names them), with the
/// times and days no period covers written out as unconfirmed. A period
/// across midnight belongs to the day it starts (decision 47): 平日
/// 20:00–08:00 covers Saturday until 08:00, and not Monday before 08:00.
List<FeeDayGroup> _groups(List<FeePeriod> periods, int pct) {
  final byDays = <int, List<FeePeriod>>{};
  for (final p in periods) {
    byDays.putIfAbsent(FeeWords.dayMask(p.days), () => []).add(p);
  }
  final covered = _coverage(periods);
  bool open(int day) =>
      covered.sublist(day * 1440, day * 1440 + 1440).contains(false);
  bool whole(int day) =>
      !covered.sublist(day * 1440, day * 1440 + 1440).contains(true);
  List<int> days(int mask) => [
    for (var d = 0; d < 7; d++)
      if (mask & (1 << d) != 0) d,
  ];
  final groups = [
    for (final MapEntry(key: mask, value: list) in byDays.entries)
      (
        mask,
        [
          for (final p in list)
            FeePeriodRow(
              feePeriodTime(p.from, p.to),
              _periodLines(p.rate, pct),
            ),
          if (days(mask).any(open)) const FeePeriodRow('其他時間', _unconfirmedRow),
        ],
      ),
  ];
  final missing = 127 & ~byDays.keys.fold(0, (a, b) => a | b);
  if (missing != 0) {
    // A day no period starts on may still hold the night before's end.
    groups.add((
      missing,
      [
        FeePeriodRow(
          days(missing).every(whole) ? '全天' : '其他時間',
          _unconfirmedRow,
        ),
      ],
    ));
  }
  final single = groups.length == 1 && groups.single.$1 == 127;
  return [
    for (final (mask, rows) in groups)
      FeeDayGroup(single ? null : FeeWords.dayLabel(mask), rows),
  ];
}

List<bool> _coverage(List<FeePeriod> periods) => feeWeekCoverage([
  for (final p in periods) (days: p.days, from: p.from, to: p.to),
]);

List<FeeLine> _periodLines(Rate rate, int pct) {
  final d = _describe(rate, pct);
  return [?d.headline, ...d.lines];
}

/// One rate's lines on the board at [pct] percent (a follow's factor), the
/// amount first; a by_time rate has none, since its periods are rows. The
/// details' summary row reads the current period's this way.
List<FeeLine> feeRateLines(Rate rate, [int pct = 100]) =>
    _periodLines(rate, pct);

/// A period's time as the board writes it: 全天, 08:00–20:00, or
/// 20:00–隔日 08:00 across midnight.
String feePeriodTime(String? from, String? to) {
  if (from == null || to == null) return '全天';
  return '$from–${from.compareTo(to) < 0 ? '' : '隔日 '}$to';
}

String _hhmm(int m) =>
    '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

/// One gap of a time-of-day rate: the day it starts on (Monday 0) and its
/// minutes from that day's 00:00; [end] passes 1440 when the gap runs into
/// the next morning. [whole] marks a day no period touches.
typedef _Gap = ({int day, int start, int end, bool whole});

/// The gaps of [periods], each the start day's (decision 47): one running
/// past midnight is a single gap from the day it starts.
List<_Gap> _gaps(List<FeePeriod> periods) {
  final covered = _coverage(periods);
  // Each day's uncovered `[start, end)` minutes.
  final segments = List.generate(7, (d) {
    final list = <(int, int)>[];
    var m = 0;
    while (m < 1440) {
      if (covered[d * 1440 + m]) {
        m++;
        continue;
      }
      final start = m;
      while (m < 1440 && !covered[d * 1440 + m]) {
        m++;
      }
      list.add((start, m));
    }
    return list;
  });
  bool whole(int d) =>
      segments[d].length == 1 && segments[d].single == (0, 1440);
  // A gap running into the next morning is written once, from its start.
  final carried = List.filled(7, false);
  for (var d = 0; d < 7; d++) {
    final next = (d + 1) % 7;
    if (!whole(d) &&
        !whole(next) &&
        segments[d].lastOrNull?.$2 == 1440 &&
        segments[next].firstOrNull?.$1 == 0) {
      carried[next] = true;
    }
  }
  return [
    for (var d = 0; d < 7; d++)
      for (final (i, (start, end)) in segments[d].indexed)
        if (!(i == 0 && carried[d]))
          (
            day: d,
            start: start,
            end: end == 1440 && carried[(d + 1) % 7]
                ? 1440 + segments[(d + 1) % 7].first.$2
                : end,
            whole: whole(d),
          ),
  ];
}

/// Each phrase with the days it applies to, in order of the first day,
/// written by [join] (「平日 20:00–隔日 08:00」).
List<String> _byDays(
  List<(int, String)> phrases,
  String Function(String days, String phrase) join,
) {
  final masks = <String, int>{};
  for (final (day, phrase) in phrases) {
    masks[phrase] = (masks[phrase] ?? 0) | (1 << day);
  }
  return [
    for (final MapEntry(key: phrase, value: mask) in masks.entries)
      join(FeeWords.dayLabel(mask), phrase),
  ];
}

String _gapTime(_Gap g) => g.whole
    ? '全天'
    : g.end <= 1440
    ? (g.end < 1440
          ? feePeriodTime(_hhmm(g.start), _hhmm(g.end))
          : '${_hhmm(g.start)}–隔日 00:00')
    : feePeriodTime(_hhmm(g.start), _hhmm(g.end - 1440));

/// What a time-of-day rate leaves unconfirmed, one phrase per gap, each the
/// period that would fill it: 平日 20:00–隔日 08:00, 週日 全天; the editor
/// lists them under 看完整時段. A gap is the start day's (decision 47), so
/// one running past midnight is written from the day it starts.
List<String> feeGaps(List<FeePeriod> periods) => _byDays([
  for (final g in _gaps(periods)) (g.day, _gapTime(g)),
], (days, phrase) => days == '每天' && phrase != '全天' ? phrase : '$days $phrase');

/// The gaps in a few words, for the editor's first line (decision 55):
/// 「平日夜間、假日全天」. A day whose gaps all fall at night (starting from
/// 18:00, or before 06:00, and over by 09:00) reads 夜間, in the day (06:00–21:00) 白天, none
/// covered 全天; any other day keeps its times as [feeGaps] writes them.
/// Empty when nothing is left uncovered.
List<String> feeGapsBrief(List<FeePeriod> periods) {
  String? word(_Gap g) {
    if (g.whole) return '全天';
    // Starting in the evening, or in the small hours before 06:00, and
    // over by 09:00: a gap from 07:00 is morning, not night.
    if ((g.start >= 18 * 60 && g.end <= 1440 + 9 * 60) ||
        (g.start < 6 * 60 && g.end <= 9 * 60)) {
      return '夜間';
    }
    if (g.start >= 6 * 60 && g.end <= 21 * 60) return '白天';
    return null;
  }

  final gaps = _gaps(periods);
  final days = <(int, String)>[];
  for (var d = 0; d < 7; d++) {
    final own = gaps.where((g) => g.day == d).toList();
    if (own.isEmpty) continue;
    final words = own.map(word).toSet();
    if (words.length == 1 && words.single != null) {
      days.add((d, words.single!));
    } else {
      // Mixed or out of the usual hours: the times themselves.
      days.add((d, ' ${own.map(_gapTime).join('、')}'));
    }
  }
  return _byDays(
    days,
    (days, phrase) =>
        days == '每天' && phrase.startsWith(' ') ? phrase.trim() : '$days$phrase',
  );
}

/// Whether any line of [boards] is unconfirmed: the board then ends with
/// [feeBoardPostedNote] (decision 54).
bool feeBoardHasUnconfirmed(List<FeeVehicleBoard> boards) {
  bool any(Iterable<FeeLine?> lines) =>
      lines.any((l) => l?.tone == FeeTone.unconfirmed);
  return boards.any(
    (b) =>
        any([b.headline, ...b.lines, b.footer]) ||
        b.groups.any((g) => g.rows.any((r) => any(r.lines))),
  );
}

/// The board's closing line, once whatever the number of unconfirmed lines
/// above it (decision 54).
class FeeBoardPostedNote extends StatelessWidget {
  const FeeBoardPostedNote({super.key, required this.colors});
  final FeeBoardTheme colors;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('fee-board-posted-note'),
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: colors.divider)),
    ),
    child: Text(
      feeBoardPostedNote,
      style: TextStyle(fontSize: 13, height: 1.4, color: colors.muted),
    ),
  );
}

/// The fee notice board (design §8.3, canvas 「收費公告牌」): one block per
/// vehicle with its plates, the amounts worked out, 首段 0 元 never written as
/// 免費, and every gap written out as 費率未確認 with one closing line to read
/// the posted notice (decision 54). The app's details and the admin
/// site show the same board; the fee editor previews it.
class FeeBoard extends StatelessWidget {
  const FeeBoard({
    super.key,
    required this.fee,
    this.first,
    this.vehicles,
    this.framed = true,
  });
  final Fee fee;

  /// The vehicles listed, unconfirmed ones included (a zone's, for C5);
  /// by default the known ones and the heavy bike.
  final List<FeeVehicle>? vehicles;

  /// The vehicle listed first: the rider's, or the one being edited.
  final FeeVehicle? first;

  /// Off inside the editor's preview, which draws its own frame.
  final bool framed;

  @override
  Widget build(BuildContext context) {
    final colors = FeeBoardTheme.of(context);
    final vehicles = feeBoardOf(fee, first: first, vehicles: this.vehicles);
    final posted = feeBoardHasUnconfirmed(vehicles);
    final body = vehicles.isEmpty
        ? Padding(
            padding: EdgeInsets.symmetric(vertical: framed ? 12 : 0),
            child: _Line(
              const FeeLine(
                '費率未確認，請依現場公告',
                tone: FeeTone.unconfirmed,
                icon: _unconfirmedIcon,
              ),
              colors: colors,
              size: 14,
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, v) in vehicles.indexed)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: i < vehicles.length - 1
                        ? Border(bottom: BorderSide(color: colors.divider))
                        : null,
                  ),
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: i == 0 && !framed ? 0 : 10,
                      bottom: i == vehicles.length - 1 && !framed && !posted
                          ? 0
                          : 10,
                    ),
                    child: _VehicleBlock(v, colors: colors),
                  ),
                ),
              if (posted) FeeBoardPostedNote(colors: colors),
            ],
          );
    // Ink on white whatever the theme: the board is the posted notice.
    final text = DefaultTextStyle.merge(
      style: TextStyle(
        color: colors.ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      child: body,
    );
    if (!framed) return text;
    return Semantics(
      container: true,
      label: '收費公告牌',
      child: Container(
        key: const ValueKey('fee-board'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: colors.paper,
          border: Border.all(color: colors.ink),
          borderRadius: BorderRadius.circular(10),
        ),
        child: text,
      ),
    );
  }
}

/// Where the lines under a vehicle's name start: the mark and its gap.
const _indent = 35.0;

class _VehicleBlock extends StatelessWidget {
  const _VehicleBlock(this.board, {required this.colors});
  final FeeVehicleBoard board;
  final FeeBoardTheme colors;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: VehicleMark(board.vehicle, color: colors.ink),
          ),
          const SizedBox(width: 10),
          Text(
            board.vehicle.label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          if (board.headline case final line?) ...[
            const SizedBox(width: 12),
            Expanded(
              child: _Line(
                line,
                colors: colors,
                size: line.tone == FeeTone.main ? 15 : 14,
                bold: true,
                end: true,
              ),
            ),
          ],
        ],
      ),
      for (final line in board.lines)
        Padding(
          padding: const EdgeInsets.only(left: _indent, top: 6),
          child: _Line(
            line,
            colors: colors,
            size: line.tone == FeeTone.main ? 15 : 13,
          ),
        ),
      for (final (i, group) in board.groups.indexed)
        Padding(
          padding: const EdgeInsets.only(left: _indent, top: 6),
          child: _Group(group, colors: colors, first: i == 0),
        ),
      if (board.footer case final footer?)
        Container(
          margin: const EdgeInsets.only(left: _indent, top: 8),
          padding: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.divider)),
          ),
          child: _Line(footer, colors: colors, size: 13),
        ),
    ],
  );
}

class _Group extends StatelessWidget {
  const _Group(this.group, {required this.colors, required this.first});
  final FeeDayGroup group;
  final FeeBoardTheme colors;
  final bool first;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.only(top: first ? 0 : 6),
    decoration: BoxDecoration(
      border: first || group.label == null
          ? null
          : Border(top: BorderSide(color: colors.divider)),
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        // The time column keeps the canvas's 128 px at normal text size and
        // grows with it, but never takes more than 45% of the row.
        final time = (MediaQuery.textScalerOf(context).scale(128))
            .clamp(0.0, constraints.maxWidth * .45)
            .toDouble();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (group.label case final label?)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colors.muted,
                  ),
                ),
              ),
            for (final row in group.rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: time,
                      child: Text(
                        row.time,
                        style: TextStyle(fontSize: 14, color: colors.muted),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final (i, line) in row.lines.indexed)
                            Padding(
                              padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                              child: _Line(
                                line,
                                colors: colors,
                                size: i == 0 ? 14 : 13,
                                bold: i == 0 && line.tone == FeeTone.main,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}

class _Line extends StatelessWidget {
  const _Line(
    this.line, {
    required this.colors,
    required this.size,
    this.bold,
    this.end = false,
  });
  final FeeLine line;
  final FeeBoardTheme colors;
  final double size;
  final bool? bold;

  /// Right-aligned beside a vehicle's name.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final color = line.tone == FeeTone.unconfirmed ? colors.unconfirmed : null;
    final weight = (bold ?? line.tone == FeeTone.main)
        ? FontWeight.w700
        : FontWeight.w400;
    return Text.rich(
      TextSpan(
        children: [
          if (line.icon case final icon?) ...[
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(icon, size: size + 1, color: color ?? colors.ink),
            ),
            const TextSpan(text: ' '),
          ],
          TextSpan(text: line.text),
        ],
      ),
      textAlign: end ? TextAlign.end : TextAlign.start,
      style: TextStyle(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: 1.4,
      ),
    );
  }
}

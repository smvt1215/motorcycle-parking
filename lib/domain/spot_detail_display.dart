/// The full-page details (design canvas v154 A2, A4, A8, A10, A12): what
/// each of the four sections lists below the plates, as words, for the
/// rider's vehicle at this moment. Only what applies to the vehicle is
/// listed (「只列 X 適用的規定」): the places open to it now, those open
/// later, and the ones closed to it named once. A street spot without
/// segments stands as one segment, so nothing reads empty. Pure Dart.
library;

import '../models/availability.dart';
import '../models/condition_text.dart';
import '../models/fee.dart';
import '../models/holiday_calendar.dart';
import '../models/parking.dart';
import '../models/parking_condition.dart';
import '../models/space_kind.dart';
import '../models/zone_entries.dart';
import 'eligibility.dart';
import 'four_sign.dart';
import 'four_sign_display.dart';
import 'segment_decision.dart' show OpenWindow;

/// The bay's name (汽機車共用格); empty when unconfirmed.
String bayLabel(BayKind? kind) =>
    kind == null ? '' : SpaceKind.ofBay(kind).label;

/// 路段 on the street, 分區 in a lot.
String detailUnit(FourSign s) => s.street ? '路段' : '分區';

/// The places the details list one by one: a lot's zones or a street's
/// segments, or the street itself when it has none; a lot standing as one
/// lists none.
List<SignArea> listedPlaces(FourSign s) => [
  for (final a in s.areas)
    if (!a.whole || s.street) a,
];

/// Whether the spot has zones or segments of its own.
bool hasPlaces(FourSign s) => s.areas.any((a) => !a.whole);

/// A place as the details name it: its own name, else its side and bay;
/// a street standing as one reads as its bay, else [fallback].
String detailPlaceName(SignArea a, {String fallback = '路邊格位'}) {
  final name = signAreaName(a);
  return name.isEmpty ? fallback : name;
}

/// 「B1 機車區（一般機車格）」: the name and, when known, the bay.
String _nameWithBay(SignArea a) {
  final bay = bayLabel(a.bayKind);
  final name = detailPlaceName(a);
  return bay.isEmpty || name.contains(bay) ? name : '$name（$bay）';
}

String _list(Iterable<String> items) => items.toSet().join('、');

String _time(String? from, String? to) => from == null || to == null
    ? '全天'
    : '$from–${to.compareTo(from) < 0 ? '隔日 ' : ''}$to';

String _days(Object days) => FeeWords.dayLabel(FeeWords.dayMask(days));

/// 「平日 07:00–20:00」; every day all day reads 全天.
String _when(Object days, String? from, String? to) {
  final d = _days(days), t = _time(from, to);
  if (d == '每天') return t;
  return '$d $t';
}

SlotVehicle _slot(VehicleType v) =>
    v == VehicleType.heavy ? SlotVehicle.heavy : SlotVehicle.scooter;

const _slotLabels = {SlotVehicle.scooter: '普通機車', SlotVehicle.heavy: '大型重機'};

// ① 能不能停 ---------------------------------------------------------------

enum DetailRuleKind {
  /// 限時: each stay's length and extensions.
  limit,

  /// 禁停: periods nobody may park.
  noParking,

  /// 共用: when a bay shared with cars opens to motorcycles.
  shared,

  /// 僅限: who the place is for when no motorcycle may park (A2b).
  only,

  /// 機車: why motorcycles may not park (A2b).
  motorcycle,
}

/// One row under the verdict card (A2, A10).
class DetailRule {
  const DetailRule(this.kind, this.text);
  final DetailRuleKind kind;
  final String text;

  String get label => switch (kind) {
    DetailRuleKind.limit => '限時',
    DetailRuleKind.noParking => '禁停',
    DetailRuleKind.shared => '共用',
    DetailRuleKind.only => '僅限',
    DetailRuleKind.motorcycle => '機車',
  };
}

/// 「每次限停 2 小時，可延長 1 次」 for every day all day, else 「平日
/// 07:00–20:00 每次限停 2 小時，可延長 1 次」; 時間未提供 when the minutes are
/// unconfirmed.
String limitWords(LimitPeriod p) {
  final text = limitPeriodText(p);
  return text.startsWith('每天 全天 ') ? text.substring(6) : text;
}

List<String> _limitTexts(ParkingCondition? c) => [
  for (final l in c?.limits ?? const <ParkingLimit>[])
    if (l.kind == LimitKind.timeLimit)
      if (l.timePeriods.isEmpty)
        '限停時間未提供'
      else
        for (final p in l.timePeriods) limitWords(p),
];

List<String> _noParkingTexts(ParkingCondition? c) => [
  for (final l in c?.limits ?? const <ParkingLimit>[])
    if (l.kind == LimitKind.noParking)
      for (final p in l.periods) _when(p.days, p.from, p.to),
];

List<String> _sharedTexts(ParkingCondition? c) => [
  for (final slot in c?.schedule ?? const <ScheduleSlot>[])
    if (slot.vehicles.any(_slotLabels.containsKey))
      '${_when(slot.days, slot.from, slot.to)} 開放'
          '${_list([for (final v in slot.vehicles) ?_slotLabels[v]])}',
];

/// The rules under the verdict card: each kind once, from every place open
/// to the vehicle (now or later). A rule that holds everywhere reads as it
/// is; one that holds on some places names them (「南側汽機車共用格：…」).
/// A lot's own limits hold for all its zones.
List<DetailRule> detailRules(FourSign s, ParkingSpot spot) {
  final places = [
    for (final a in s.areas)
      if (a.open) a,
  ];
  if (places.isEmpty) return const [];
  final lotWide = !s.street && places.any((a) => !a.whole)
      ? spot.condition
      : null;
  DetailRule? rule(
    DetailRuleKind kind,
    List<String> Function(ParkingCondition?) of,
  ) {
    final base = of(lotWide);
    // Each place's own rules, merged where places share them.
    final byText = <String, List<SignArea>>{};
    for (final a in places) {
      final own = {
        for (final t in of(a.condition))
          if (!base.contains(t)) t,
      }.join('、');
      if (own.isNotEmpty) byText.putIfAbsent(own, () => []).add(a);
    }
    final parts = [
      ...base,
      for (final MapEntry(key: text, value: where) in byText.entries)
        where.length == places.length
            ? text
            : '${_list(where.map(detailPlaceName))}：$text',
    ];
    return parts.isEmpty ? null : DetailRule(kind, parts.toSet().join('；'));
  }

  return [
    ?rule(DetailRuleKind.limit, _limitTexts),
    ?rule(DetailRuleKind.noParking, _noParkingTexts),
    ?rule(DetailRuleKind.shared, _sharedTexts),
  ];
}

/// When [a] next opens to [vehicle], read from its window, which leaves
/// out 禁停 periods and the notice's own dates: 「20:00–23:00」 when a slot
/// starting then is the whole story (no 禁停, no notice end to cut it),
/// else 「20:00 起」; empty when no time within the week is known.
String openHours(SignArea a, VehicleType vehicle) {
  final opensAt = a.window.opensAt;
  if (opensAt == null) return '';
  final c = a.condition;
  final clock = opensAt.split(' ').last;
  final plain =
      opensAt == clock &&
      c != null &&
      c.basis?.expiresOn == null &&
      !c.hasLimit(LimitKind.noParking);
  if (plain) {
    final slots = [
      for (final slot in c.schedule)
        if (slot.vehicles.contains(_slot(vehicle)) && slot.from == clock)
          _when(slot.days, slot.from, slot.to),
    ];
    if (slots.isNotEmpty) return _list(slots);
  }
  return '$opensAt 起';
}

/// 「20:00–23:00 才開放大型重機」 for a place open later; empty when it is
/// open now, never, or opens at no known time.
String laterWords(SignArea a, VehicleType vehicle) {
  if (!a.open || a.window.now) return '';
  final hours = openHours(a, vehicle);
  if (hours.isEmpty) return '';
  return hours.endsWith('起')
      ? '$hours開放${vehicle.label}'
      : '$hours 才開放${vehicle.label}';
}

/// The verdict card's headline for the decided states: 「大型重機現在可停」,
/// 「…現在有條件」, 「…現在禁停」, 「…不能停」; null where the existing
/// wording (待確認, 車友回報可停…) stays, after the vehicle
/// ([undecidedHeadline]). [selected] is a chosen segment
/// (A10): its own state reads.
String? verdictHeadline(FourSign s, {SignArea? selected}) {
  final v = s.vehicle.label;
  if (selected != null) {
    return switch (selected.status) {
      EligibilityStatus.allowed when selected.window.now => '$v現在可停',
      EligibilityStatus.conditional when selected.window.now => '$v現在有條件',
      EligibilityStatus.allowed || EligibilityStatus.conditional => '$v現在不能停',
      EligibilityStatus.notAllowed => '$v不能停',
      EligibilityStatus.unverified => null,
    };
  }
  final verdict = s.verdict;
  return switch (verdict.status) {
    EligibilityStatus.allowed => '$v現在可停',
    EligibilityStatus.conditional when verdict.noParkingNow => '$v現在禁停',
    EligibilityStatus.conditional when verdict.openNow => '$v現在有條件',
    EligibilityStatus.conditional when verdict.opensAt != null =>
      '$v現在不能停，${verdict.opensAt} 起可停',
    EligibilityStatus.conditional => '$v有條件',
    EligibilityStatus.notAllowed => '$v不能停',
    EligibilityStatus.unverified => null,
  };
}

/// An undecided headline with the vehicle it is for: 「大型重機：待確認」.
String undecidedHeadline(VehicleType vehicle, String label) =>
    '${vehicle.label}：$label';

/// The selected segment's line under the headline (A10): its own state,
/// then the other segments open now.
String selectedNote(FourSign s, SignArea selected) {
  final name = detailPlaceName(selected);
  final own = switch (selected.status) {
    EligibilityStatus.allowed when selected.window.now => '現在可停',
    EligibilityStatus.conditional when selected.window.now =>
      _limitTexts(selected.condition).firstOrNull ??
          (selected.window.until == null
              ? '有條件'
              : '可停到 ${selected.window.until}'),
    EligibilityStatus.allowed ||
    EligibilityStatus.conditional => laterWords(selected, s.vehicle),
    EligibilityStatus.notAllowed => '${s.vehicle.label}不能停',
    EligibilityStatus.unverified => '待確認',
  };
  final others = [
    for (final a in s.areas)
      if (a != selected && a.open && a.window.now) detailPlaceName(a),
  ];
  return [
    '選定的$name$own',
    if (others.isNotEmpty) '${_list(others)}現在可停',
  ].join('；');
}

/// The plate 能不能停 reads for a selected segment (A10): its state, with
/// the segment's side and what limits it under it.
SignPlate selectedVerdictPlate(FourSign s, SignArea a) {
  final short = a.side?.label ?? detailPlaceName(a);
  final (tone, main, note) = switch (a.status) {
    EligibilityStatus.allowed when a.window.now => (
      PlateTone.allowed,
      '可停',
      short,
    ),
    EligibilityStatus.conditional when a.window.now => (
      PlateTone.conditional,
      a.restriction?.label ?? '有條件',
      short,
    ),
    EligibilityStatus.allowed || EligibilityStatus.conditional => (
      PlateTone.conditional,
      openHours(a, s.vehicle).isEmpty ? '有條件' : '限時段',
      '$short ${openHours(a, s.vehicle)}'.trim(),
    ),
    EligibilityStatus.notAllowed => (PlateTone.denied, '不能停', short),
    EligibilityStatus.unverified => (PlateTone.unverified, '待確認', short),
  };
  return SignPlate(
    face: FourSignFace.verdict,
    main: main,
    note: note,
    tone: tone,
    semantics: '能不能停：$main，目前選定的${detailPlaceName(a)}',
  );
}

// 整個點都不能停 (A2b) -------------------------------------------------------

/// The verdict card's headline when neither vehicle may park (A2b).
const notParkableHeadline = '這裡機車不能停';

/// The line under it.
const notParkableExplanation = '普通機車、大型重機都不能停。';

/// 能不能停's single plate when neither vehicle may park (A2b): 不能停,
/// whichever vehicle is chosen, with what it rests on.
SignPlate notParkablePlate(SignPlate plate) => SignPlate(
  face: FourSignFace.verdict,
  main: '不能停',
  note: plate.note,
  tone: PlateTone.denied,
  semantics: [
    '能不能停：不能停，普通機車和大型重機都不能停',
    if (plate.note.isNotEmpty) plate.note,
  ].join('，'),
);

/// Why neither vehicle may park (A2b): 僅限 汽車 when every bay is a car's,
/// 禁停 全天 when a no-parking limit covers every day, and the decision's
/// own reason under 機車.
List<DetailRule> notParkableRules(FourSign s, ParkingSpot spot, String reason) {
  final bays = [
    for (final z in spot.zones)
      bayKindOf(z.condition ?? zoneConditionOf(z.access)),
    for (final a in s.areas)
      if (a.segment != null || (s.street && a.whole)) a.bayKind,
  ];
  final carOnly =
      bays.isNotEmpty && bays.every((b) => b == BayKind.car) ||
      bays.isEmpty && spot.condition?.bay == Bay.car;
  final conditions = [spot.condition, for (final a in s.areas) a.condition];
  final allDay = conditions.any(
    (c) => (c?.limits ?? const <ParkingLimit>[]).any(
      (l) =>
          l.kind == LimitKind.noParking &&
          l.periods.any(
            (p) => p.days == 'all' && p.from == null && p.to == null,
          ),
    ),
  );
  return [
    if (carOnly)
      DetailRule(DetailRuleKind.only, bays.length > 1 ? '汽車；全場只有汽車格' : '汽車'),
    if (allDay) const DetailRule(DetailRuleKind.noParking, '全天'),
    if (reason.trim().isNotEmpty)
      DetailRule(DetailRuleKind.motorcycle, reason.trim()),
  ];
}

/// The folded 有沒有位・怎麼算錢 row (A2b): what it says, and what it hides.
const notParkableFoldTitle = '這裡不能停，空位和費率不顯示';
const notParkableFoldSub = '有沒有位、怎麼算錢';
const notParkableFoldHint = '點一下展開，看這裡的空位與費率（資料照常保留）。';

// ② 有沒有位 ---------------------------------------------------------------

/// One place's row (A10, A12): the official count or total, and room for
/// riders' reports below it (#189).
class SeatRow {
  const SeatRow({
    required this.area,
    required this.name,
    required this.sub,
    required this.official,
    this.officialNote = '',
    this.areas = const [],
  });

  /// The place the row is about; the first of [areas] when it stands for
  /// several.
  final SignArea area;

  /// The places sharing one official count; empty for a single place.
  final List<SignArea> areas;
  final String name, sub;

  /// 「剩 4 格」, 「已滿」, 「共 18 格」, 「空位未知」, 「暫停營運」.
  final String official;

  /// 「2 分鐘前」, 「更新延遲・8 分鐘前」, 「空位未知」.
  final String officialNote;
}

/// A place's state in a few words: 現在可停, 有條件：…, or when it opens.
String placeState(SignArea a, VehicleType vehicle, {bool street = false}) {
  if (a.window.now) {
    if (a.status == EligibilityStatus.allowed) return '現在可停';
    final limit =
        _limitTexts(a.condition).firstOrNull ??
        switch (_noParkingTexts(a.condition)) {
          [] => null,
          final banned => '${banned.join('、')} 禁停',
        } ??
        (a.window.until == null ? null : '可停到 ${a.window.until}');
    return limit == null ? '有條件' : '有條件：$limit';
  }
  final later = laterWords(a, vehicle);
  if (later.isEmpty) return '';
  return street ? '$later，現在不能停' : later;
}

bool _shown(AvailabilitySnapshot s, DateTime now) =>
    s.status(now) == AvailabilityStatus.fresh ||
    s.status(now) == AvailabilityStatus.delayed;

/// The rows of 有沒有位: each place open to the vehicle, now or later.
/// Empty when the spot stands as one (the section then reads the plate's
/// answer whole).
List<SeatRow> seatRows(
  FourSign s,
  SpotAvailability availability,
  DateTime now,
) {
  if (!hasPlaces(s)) return const [];
  final open = [
    for (final a in s.areas)
      if (a.open) a,
  ];
  final rows = <SeatRow>[];
  final listed = <SignArea>{};
  for (final a in open) {
    if (!listed.add(a)) continue;
    // A lot's official count is one per vehicle class for the whole lot:
    // zones sharing a class share it, so they share one row, never each
    // its own copy of the number (as four_sign's 有沒有位 merges them).
    final shared = !s.street && a.countClass != null
        ? [
            for (final b in open)
              if (b.countClass == a.countClass) b,
          ]
        : [a];
    listed.addAll(shared);
    final row = _seatRow(s, a, availability, now);
    if (shared.length == 1) {
      rows.add(row);
      continue;
    }
    rows.add(
      SeatRow(
        area: a,
        areas: shared,
        name: _list(shared.map(detailPlaceName)),
        sub: [
          _list(
            shared.map((b) => bayLabel(b.bayKind)).where((t) => t.isNotEmpty),
          ),
          '${shared.length} 區共用同一個官方數字',
        ].where((t) => t.isNotEmpty).join('・'),
        official: row.official,
        officialNote: row.officialNote,
      ),
    );
  }
  return rows;
}

SeatRow _seatRow(
  FourSign s,
  SignArea a,
  SpotAvailability availability,
  DateTime now,
) {
  final sub = [
    bayLabel(a.bayKind),
    placeState(a, s.vehicle, street: s.street),
  ].where((t) => t.isNotEmpty).join('・');
  final snapshot = !s.street && a.countClass != null
      ? availability.of(a.countClass!)
      : null;
  if (snapshot != null &&
      snapshot.status(now) == AvailabilityStatus.suspended) {
    return SeatRow(
      area: a,
      name: detailPlaceName(a),
      sub: sub,
      official: '暫停營運',
    );
  }
  if (snapshot != null && _shown(snapshot, now)) {
    final delayed = snapshot.status(now) == AvailabilityStatus.delayed;
    final at = snapshot.sourceUpdatedAt;
    return SeatRow(
      area: a,
      name: detailPlaceName(a),
      sub: sub,
      official: snapshot.available == 0 ? '已滿' : '剩 ${snapshot.available} 格',
      officialNote: [
        if (delayed) '更新延遲',
        if (at != null) agoText(at, now),
      ].join('・'),
    );
  }
  final total = a.total ?? snapshot?.capacity;
  return SeatRow(
    area: a,
    name: detailPlaceName(a),
    sub: sub,
    official: total == null ? '空位未知' : '共 $total 格',
    officialNote: total == null ? '' : '空位未知',
  );
}

/// The words under 有沒有位's answer when the spot stands as one.
String seatExplanation(FourSign s, {bool riders = false}) {
  switch (s.seat.kind) {
    case SeatKind.unknown:
      return [
        '官方沒有提供即時數字；空位未知不代表已滿。',
        riders ? '可以看車友回報（列出 30 分鐘內的）或到場再找車位。' : '可以到場再找車位。',
      ].join();
    case SeatKind.total:
      return '「共幾格」是總數，不是剩餘；官方沒有提供即時空位。';
    case SeatKind.live || SeatKind.delayed || SeatKind.suspended:
    case SeatKind.rider:
      return '';
  }
}

/// The note under the rows (A10): what the counts mean.
String seatRowsNote(FourSign s) =>
    s.street ? '路邊格沒有官方即時空位，「共幾格」是總數，不是剩餘。' : '官方是停管處公開的剩餘格數；沒有數字的區，空位未知不代表已滿。';

// ③ 怎麼算錢 ---------------------------------------------------------------

/// A place's price: a structured rate, legacy text, or none (未提供).
class DetailPrice {
  const DetailPrice({this.rate, this.text});
  final Rate? rate;
  final String? text;

  bool get none => rate == null && text == null;

  @override
  bool operator ==(Object other) =>
      other is DetailPrice && other.rate == rate && other.text == text;

  @override
  int get hashCode => Object.hash(rate, text);
}

bool _placeholder(String text) =>
    const {'', '依現場公告', '請依現場公告', '費率未確認'}.contains(text.trim());

DetailPrice _text(String text) =>
    _placeholder(text) ? const DetailPrice() : DetailPrice(text: text.trim());

/// [vehicle]'s rate in [fee], a follow read as the rate it follows; null
/// when unconfirmed or not applicable.
Rate? _resolved(Fee fee, VehicleType vehicle) {
  final key = vehicle == VehicleType.heavy ? 'heavy' : 'scooter';
  if (fee.textOf(key) == null) return null;
  final rate = vehicle == VehicleType.heavy ? fee.heavy : fee.scooter;
  final out = rate == null || !rate.mode.follows
      ? rate
      : rate.mode == FeeMode.sameAsScooter
      ? fee.scooter
      : fee.car;
  return out == null || out.mode == FeeMode.notApplicable ? null : out;
}

DetailPrice _rateOf(Fee fee, VehicleType vehicle) {
  final rate = _resolved(fee, vehicle);
  return rate == null ? const DetailPrice() : DetailPrice(rate: rate);
}

/// [a]'s price for [vehicle], as the 怎麼算錢 plate reads it (#188 layer
/// 2): a segment's or zone's own rate, else the road's or the lot's; text
/// only where nothing is structured.
DetailPrice placePrice(ParkingSpot spot, SignArea a, VehicleType vehicle) {
  if (a.segment case final seg?) {
    final fee = seg.fee ?? spot.fee;
    return fee == null ? _text(spot.feeNote) : _rateOf(fee, vehicle);
  }
  if (a.zone case final z?) {
    if (z.fee case final fee?) return _rateOf(fee, vehicle);
    if (spot.fee case final fee?) return _rateOf(fee, vehicle);
    final own = vehicle == VehicleType.heavy
        ? z.heavyFeeNote
        : z.scooterFeeNote;
    final legacy = own.trim().isNotEmpty ? own : z.feeNote;
    if (!_placeholder(legacy)) return DetailPrice(text: legacy.trim());
    if (spot.zones.any((z) => z.fee != null)) return const DetailPrice();
    return _text(spot.feeNote);
  }
  return spot.fee == null ? _text(spot.feeNote) : _rateOf(spot.fee!, vehicle);
}

/// The period of [c]'s time limit holding at [now]; null when none does.
LimitPeriod? _stayAt(ParkingCondition? c, DateTime now, HolidayCalendar cal) {
  final (today, at) = taipeiDateMinute(now);
  for (final l in c?.limits ?? const <ParkingLimit>[]) {
    if (l.kind != LimitKind.timeLimit) continue;
    for (final p in l.timePeriods) {
      if (datedSpans(
        p.days,
        p.from,
        p.to,
        today,
        cal,
      ).any((s) => s.$1 <= at && at < s.$2)) {
        return p;
      }
    }
  }
  return null;
}

/// A rate's amount as riders read it: 每小時 20 元, 每次 30 元, 首 2 小時 0
/// 元, 免費. A time-of-day rate reads its periods elsewhere.
String rateWords(Rate r, {int? firstMinutes}) => switch (r.mode) {
  FeeMode.free => '免費',
  FeeMode.hourly =>
    '${FeeWords.every(r.perMinutes)} ${FeeWords.money(r.amount)} 元',
  FeeMode.perVisit when r.amount == 0 && firstMinutes != null =>
    '首 ${FeeWords.span(firstMinutes)} 0 元',
  FeeMode.perVisit => '每次 ${FeeWords.money(r.amount)} 元',
  _ => '',
};

/// A period's rate with all its terms, in the words the notice board's
/// period lines use ([Rate.text]): 「每次 30 元，隔日另計」, 「每小時 20
/// 元，當日上限 100 元（零時重算）」.
String periodWords(Rate r) => r.text;

/// What else a rate says: a cap, a paid extension, how a visit renews.
List<String> _extras(Rate r, LimitPeriod? stay) => [
  if (r.mode == FeeMode.hourly && r.dailyCap != null)
    '當日上限 ${FeeWords.money(r.dailyCap)} 元'
        '${FeeWords.reset(r.capReset) == null ? '' : '（${FeeWords.reset(r.capReset)}）'}',
  if (r.mode == FeeMode.perVisit &&
      r.extensionAmount != null &&
      (stay?.extensions ?? 0) > 0)
    '可付 ${FeeWords.money(r.extensionAmount)} 元延長 ${stay!.extensions} 次',
  if (r.mode == FeeMode.perVisit && r.renew == Renew.none) '停多久都只收一次',
  if (r.mode == FeeMode.perVisit && r.renew == Renew.midnight) '隔日另計',
];

/// One card of 怎麼算錢 (A2, A8, A10).
class FeeCard {
  const FeeCard({
    required this.header,
    required this.main,
    this.detail = '',
    this.unknown = false,
    this.others = const [],
    this.closedTimes = '',
    this.note = '',
    this.vehicleHeader = false,
  });

  /// 「大型重機　現在適用」, or the place's name and bay.
  final String header;

  /// Whether [header] names the vehicle (its plates are drawn beside the
  /// amount).
  final bool vehicleHeader;

  /// 「每小時 20 元」; 未提供 when no source states it.
  final String main;
  final bool unknown;

  /// 「現在適用，全天；當日上限 100 元」.
  final String detail;

  /// A time-of-day rate's other periods: (when, amount).
  final List<(String, String)> others;

  /// The place's 禁停 periods, when the vehicle may not park (非開放時段).
  final String closedTimes;

  /// 「全場同價」 when one card stands for several places.
  final String note;
}

/// 怎麼算錢 as a whole.
class FeeSection {
  const FeeSection({
    required this.cards,
    this.title = '怎麼算錢',
    this.sameNote = '',
    this.closed = const [],
    this.later = const [],
  });
  final String title;
  final List<FeeCard> cards;

  /// 「其他分區 全場同價」: one zone open now, the lot's rate everywhere.
  final String sameNote;

  /// Places closed to the vehicle: 「B1 機車區（一般機車格）」.
  final List<String> closed;

  /// Places open later: 「另有 B3 汽車區（汽機車共用格），20:00–23:00 才開放
  /// 大型重機，同樣每小時 20 元。」
  final List<String> later;
}

String _priceWords(DetailPrice p, ParkingCondition? c, DateTime now) {
  if (p.text != null) return p.text!;
  final r = p.rate;
  if (r == null) return '未提供';
  if (r.mode != FeeMode.byTime) {
    return rateWords(
      r,
      firstMinutes: _stayAt(c, now, HolidayCalendar.current)?.maxMinutes,
    );
  }
  final periods = r.periods ?? const <FeePeriod>[];
  return periods
      .map((p) => '${_when(p.days, p.from, p.to)} ${rateWords(p.rate)}')
      .join('；');
}

FeeCard _card(
  DetailPrice price,
  SignArea a,
  FourSign s,
  DateTime now,
  HolidayCalendar cal, {
  required String header,
  required bool vehicleHeader,
  required bool current,
  String note = '',
}) {
  final closedTimes = _noParkingTexts(a.condition).join('、');
  final lead = vehicleHeader ? <String>[] : [if (current) '現在適用'];
  if (price.text != null) {
    return FeeCard(
      header: header,
      vehicleHeader: vehicleHeader,
      main: price.text!,
      closedTimes: closedTimes,
      note: note,
    );
  }
  final r = price.rate;
  if (r == null) {
    return FeeCard(
      header: header,
      vehicleHeader: vehicleHeader,
      main: '未提供',
      unknown: true,
      closedTimes: closedTimes,
      note: note,
    );
  }
  final stay = _stayAt(a.condition, now, cal);
  if (r.mode != FeeMode.byTime) {
    final extras = _extras(r, stay);
    return FeeCard(
      header: header,
      vehicleHeader: vehicleHeader,
      main: rateWords(r, firstMinutes: stay?.maxMinutes),
      detail: [
        [...lead, '全天'].join('，'),
        ...extras,
      ].join('；'),
      closedTimes: closedTimes,
      note: note,
    );
  }
  // A time-of-day rate: the period holding now (the one that started last
  // where they overlap), and the others beside it.
  final (today, at) = taipeiDateMinute(now);
  final periods = r.periods ?? const <FeePeriod>[];
  FeePeriod? holding;
  int? since;
  for (final p in periods) {
    for (final (start, end) in datedSpans(p.days, p.from, p.to, today, cal)) {
      final elapsed = at - start;
      if (elapsed >= 0 && at < end && (since == null || elapsed < since)) {
        (holding, since) = (p, elapsed);
      }
    }
  }
  final others = [
    for (final p in periods)
      if (!identical(p, holding))
        (
          _when(p.days, p.from, p.to),
          p.rate.mode == FeeMode.byTime ? '' : periodWords(p.rate),
        ),
  ];
  final cross = switch (r.crossPeriod) {
    CrossPeriod.eachPeriod => '跨時段分別計費',
    null => null,
    _ => '依進場時段計費',
  };
  if (holding == null) {
    return FeeCard(
      header: header,
      vehicleHeader: vehicleHeader,
      main: '未提供',
      unknown: true,
      detail: [?cross].join(),
      others: others,
      closedTimes: closedTimes,
      note: note,
    );
  }
  return FeeCard(
    header: header,
    vehicleHeader: vehicleHeader,
    main: rateWords(holding.rate, firstMinutes: stay?.maxMinutes),
    detail: [
      [...lead, _when(holding.days, holding.from, holding.to)].join('，'),
      ..._extras(holding.rate, stay),
      ?cross,
    ].join('；'),
    others: others,
    closedTimes: closedTimes,
    note: note,
  );
}

/// 怎麼算錢 for [s] at [now]: a card per place open now (one card when they
/// all charge alike), the places closed to the vehicle, and those open
/// later with what they charge then. With no place open, the spot's rate
/// is read for every place, as the plate does.
FeeSection feeSection(
  FourSign s,
  ParkingSpot spot,
  DateTime now, {
  HolidayCalendar? calendar,
}) {
  final cal = calendar ?? HolidayCalendar.current;
  final v = s.vehicle;
  final openNow = [
    for (final a in s.areas)
      if (a.open && a.window.now) a,
  ];
  final openLater = [
    for (final a in s.areas)
      if (a.open && !a.window.now) a,
  ];
  var named = hasPlaces(s);
  // Places priced: those open now, else those open later, else all.
  var priced = openNow.isNotEmpty
      ? openNow
      : openLater.isNotEmpty
      ? openLater
      : s.areas;
  // A lot whose zones say nothing of access stands as one place, yet its
  // zones may still carry their own rates: each zone prices it, as the
  // 怎麼算錢 plate reads them, never the lot's rate in their place.
  if (!s.street &&
      spot.zones.isNotEmpty &&
      priced.isNotEmpty &&
      priced.every((a) => a.whole)) {
    final whole = priced.first;
    priced = [
      for (final z in spot.zones)
        SignArea(
          id: z.id,
          name: z.name.trim().isEmpty ? '分區' : z.name.trim(),
          status: whole.status,
          window: whole.window,
          zone: z,
          condition: z.condition ?? zoneConditionOf(z.access),
          bayKind: bayKindOf(z.condition ?? zoneConditionOf(z.access)),
        ),
    ];
    named = true;
  }
  final current = openNow.isNotEmpty;
  final prices = [for (final a in priced) placePrice(spot, a, v)];
  final closed = [
    for (final a in s.areas)
      if (a.status == EligibilityStatus.notAllowed && !a.whole) _nameWithBay(a),
  ];
  final later = current
      ? [
          for (final a in openLater)
            () {
              final price = placePrice(spot, a, v);
              final words = _priceWords(price, a.condition, now);
              final same = prices.contains(price) && !price.none;
              final hours = laterWords(a, v);
              return [
                '另有 ${_nameWithBay(a)}',
                ?(hours.isEmpty ? null : hours),
                '${same ? '同樣' : ''}${price.none ? '費率未提供' : words}',
              ].join('，');
            }(),
        ]
      : const <String>[];
  final title = named && current
      ? '怎麼算錢（${v.label}現在可停的${detailUnit(s)}）'
      : '怎麼算錢';
  final vehicleHeader = '${v.label}${current ? '　現在適用' : ''}';
  final allSame =
      priced.length > 1 &&
      prices.toSet().length == 1 &&
      // The stay a time limit allows (and its extensions) shapes a card's
      // amount and extension line: places differing there keep their own.
      {
            for (final a in priced)
              '${_noParkingTexts(a.condition).join()}|'
                  '${_limitTexts(a.condition).join()}',
          }.length ==
          1;
  if (!named || allSame || priced.isEmpty) {
    final area = priced.isEmpty
        ? const SignArea(
            name: '',
            status: EligibilityStatus.unverified,
            window: OpenWindow.never,
          )
        : priced.first;
    return FeeSection(
      title: title,
      cards: [
        _card(
          prices.firstOrNull ?? placePrice(spot, area, v),
          area,
          s,
          now,
          cal,
          header: vehicleHeader,
          vehicleHeader: true,
          current: current,
          note: allSame ? (s.street ? '各路段同價' : '全場同價') : '',
        ),
      ],
      closed: closed,
      later: later,
    );
  }
  // One zone open now on the lot's rate, others beside it: 全場同價.
  final lotWide =
      !s.street &&
      priced.length == 1 &&
      priced.single.zone?.fee == null &&
      spot.fee != null &&
      spot.zones.length > 1;
  return FeeSection(
    title: title,
    cards: [
      for (final (i, a) in priced.indexed)
        _card(
          prices[i],
          a,
          s,
          now,
          cal,
          header: [
            detailPlaceName(a),
            if (!detailPlaceName(a).contains(bayLabel(a.bayKind)))
              bayLabel(a.bayKind),
          ].where((t) => t.isNotEmpty).join('　'),
          vehicleHeader: false,
          current: current,
        ),
    ],
    sameNote: lotWide ? '全場同價' : '',
    closed: closed,
    later: later,
  );
}

// ④ 停哪裡 -----------------------------------------------------------------

/// One place's card (A2, A10).
class WhereCard {
  const WhereCard({
    required this.area,
    required this.name,
    required this.sub,
    this.state = '',
    this.limit = '',
    this.guide = '',
    this.later = false,
  });
  final SignArea area;
  final String name;

  /// 「建國北路口 → 松江路口・收費格・共 18 格」, 「重機專用格」.
  final String sub;

  /// When it opens, for a place open later (amber).
  final String state;
  final bool later;

  /// What limits it now (平日 07:00–20:00 每次限停 2 小時).
  final String limit;
  final String guide;
}

String _charge(ParkingCondition? c) => switch (c?.charge) {
  Charge.toll => '收費格',
  Charge.free => '免費格',
  null => '',
};

/// The cards of 停哪裡: each place open to the vehicle (now or later); a
/// street without segments as one card; a lot standing as one has none.
List<WhereCard> whereCards(FourSign s, ParkingSpot spot) => [
  for (final a in listedPlaces(s))
    if (a.open || (a.whole && s.street)) _whereCard(s, spot, a),
];

WhereCard _whereCard(FourSign s, ParkingSpot spot, SignArea a) {
  final segment = a.segment;
  final range = segment?.range.trim() ?? '';
  final sub = s.street
      ? [
          if (range.isNotEmpty)
            range
          else if (a.whole && spot.roadSegment.trim().isNotEmpty)
            spot.roadSegment.trim(),
          bayLabel(a.bayKind),
          _charge(a.condition),
          if (a.total != null) '共 ${a.total} 格',
        ].where((t) => t.isNotEmpty).join('・')
      : bayLabel(a.bayKind);
  final guide = (segment?.guide ?? a.zone?.guide ?? '').trim();
  final later = laterWords(a, s.vehicle);
  return WhereCard(
    area: a,
    name: detailPlaceName(a, fallback: spot.spaceType.label),
    sub: sub,
    state: later.isEmpty
        ? ''
        : s.street
        ? '$later，現在不能停'
        : later,
    later: later.isNotEmpty,
    limit: a.window.now && a.status == EligibilityStatus.conditional
        ? (_limitTexts(a.condition).firstOrNull ?? '')
        : '',
    guide: guide,
  );
}

/// 「另有 B1 機車區（一般機車格），大型重機不能停」; empty when every place
/// is open, or when the whole spot is closed (the verdict says so).
String closedNote(FourSign s) {
  if (s.denied) return '';
  final closed = [
    for (final a in s.areas)
      if (a.status == EligibilityStatus.notAllowed && !a.whole) _nameWithBay(a),
  ];
  if (closed.isEmpty) return '';
  return '另有 ${_list(closed)}，${s.vehicle.label}不能停';
}

/// 「另有 B2，大型重機能不能停待確認」: places whose access for the vehicle
/// is unconfirmed, so no zone drops out of the details; empty when none.
String pendingNote(FourSign s) {
  final pending = [
    for (final a in s.areas)
      if (a.status == EligibilityStatus.unverified && !a.whole) _nameWithBay(a),
  ];
  if (pending.isEmpty) return '';
  return '另有 ${_list(pending)}，${s.vehicle.label}能不能停待確認';
}

/// The address lines and the coordinates (地址與座標).
(String, String) addressAndCoordinates(ParkingSpot spot) => (
  [
    if (spot.address.trim().isNotEmpty) spot.address.trim(),
    if (spot.roadSegment.trim().isNotEmpty) spot.roadSegment.trim(),
  ].join('\n'),
  '${spot.lat.toStringAsFixed(6)}, ${spot.lng.toStringAsFixed(6)}',
);

/// What 複製 puts on the clipboard: the name, the address and the
/// coordinates, one per line.
String copiedLocation(ParkingSpot spot) {
  final (address, coordinates) = addressAndCoordinates(spot);
  return [spot.name, if (address.isNotEmpty) address, coordinates].join('\n');
}

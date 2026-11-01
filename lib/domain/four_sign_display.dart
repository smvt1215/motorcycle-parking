/// How the four signs read (design canvas Ver.143 Main, A3, A5, A6, A11):
/// each face's question, its large answer, the small note under it, the
/// tone it is painted in and what a screen reader says. Words follow
/// FIX-DECISIONS: 不能停, 空位未知, 官方未標示, 車友回報. Pure Dart.
library;

import '../models/fee.dart';
import '../models/parking.dart';
import '../models/space_kind.dart';
import 'eligibility.dart';
import 'four_sign.dart';
import 'parking_decision.dart';

/// How a plate is painted; the colours are fixed (A4: never the dynamic
/// scheme), so the widget maps each tone to one look.
enum PlateTone {
  /// Solid green: 可停.
  allowed,

  /// Solid amber: 有條件.
  conditional,

  /// Solid grey: 待確認.
  unverified,

  /// Solid red: 不能停 (the only plate left).
  denied,

  /// Ink outline: a known answer.
  line,

  /// Dashed outline: unknown (空位未知, 官方未標示).
  dashed,

  /// Amber outline on cream: an official count past its window.
  delayed,

  /// Light grey: riders' reports, with a meter.
  rider,
}

/// One plate.
class SignPlate {
  const SignPlate({
    required this.face,
    required this.main,
    required this.tone,
    required this.semantics,
    this.note = '',
    this.tag,
    this.meters = const [],
  });
  final FourSignFace face;
  final String main;

  /// Lines under [main], joined by `\n`; empty for none.
  final String note;
  final PlateTone tone;

  /// A small ink tag under the note (「另 1 區有位」).
  final String? tag;

  /// Riders' levels (0–3) as meters: one, or two when they disagree.
  final List<int> meters;

  /// What a screen reader says for the whole plate.
  final String semantics;

  String get question => fourSignQuestion(face);
}

String fourSignQuestion(FourSignFace face) => switch (face) {
  FourSignFace.verdict => '能不能停',
  FourSignFace.seat => '有沒有位',
  FourSignFace.fee => '怎麼算錢',
  FourSignFace.where => '停哪裡',
};

/// A rider report's level in words (A7).
String riderLevelLabel(int level) => switch (level) {
  >= 3 => '很多空位',
  2 => '還有一些',
  1 => '快滿了',
  _ => '已停滿',
};

String _riderLevelShort(int level) => switch (level) {
  >= 3 => '很多',
  2 => '還有一些',
  1 => '快滿',
  _ => '滿',
};

/// 「剛剛」, 「8 分鐘前」, 「2 小時前」.
String agoText(DateTime at, DateTime now) {
  final minutes = now.difference(at).inMinutes;
  if (minutes < 1) return '剛剛';
  if (minutes < 60) return '$minutes 分鐘前';
  return '${minutes ~/ 60} 小時前';
}

String _basisNote(VerdictAnswer v) => switch (v.basis) {
  BasisKind.official => '政府資料',
  BasisKind.adminVerified => '管理員確認',
  BasisKind.cityRule => '${v.city ?? '縣市'}規則',
  BasisKind.law => '依法規',
  BasisKind.notice => '現場公告',
  BasisKind.communityReport => '車友回報',
  BasisKind.adminLapsed => '曾確認',
  BasisKind.none => '',
};

/// The name a place is listed by: a zone's or segment's own, else a
/// segment's side and bay (北側一般機車格).
String signAreaName(SignArea a) {
  if (a.name.isNotEmpty) return a.name;
  final kind = a.bayKind == null ? '' : SpaceKind.ofBay(a.bayKind!).label;
  return '${a.side?.label ?? ''}$kind';
}

/// A zone name split into its code and the rest: 「B2 重機專區」 reads B2
/// on the plate and 重機專區 under it.
(String, String) _split(String name) {
  final i = name.indexOf(RegExp(r'\s'));
  if (i <= 0) return (name, '');
  return (name.substring(0, i), name.substring(i).trim());
}

String _short(SignArea a, bool street) {
  if (street && a.side != null) return a.side!.label;
  return _split(signAreaName(a)).$1;
}

String _list(Iterable<String> items) {
  final unique = items.where((s) => s.isNotEmpty).toSet().toList();
  return unique.length > 3 ? '${unique.take(3).join('、')}…' : unique.join('、');
}

/// An amount as the fee texts write it (fee.dart's money format): whole,
/// else up to two decimals without trailing zeros, 41.25, 22.5.
String _num(num v) {
  final cents = (v * 100).round(), whole = cents ~/ 100, rem = cents % 100;
  if (rem == 0) return '$whole';
  if (rem % 10 == 0) return '$whole.${rem ~/ 10}';
  return '$whole.${rem.toString().padLeft(2, '0')}';
}

/// A rate in the plate's short form: 20/時, 10/30分, 30/次, 100/日, 免費.
String plateRateText(PlateRate r) => switch (r.mode) {
  FeeMode.free => '免費',
  FeeMode.hourly =>
    r.perMinutes == 60
        ? '${_num(r.amount ?? 0)}/時'
        : '${_num(r.amount ?? 0)}/${r.perMinutes}分',
  FeeMode.perVisit =>
    r.firstMinutes != null
        ? '首 ${_span(r.firstMinutes!)} 0 元'
        : '${_num(r.amount ?? 0)}/次',
  FeeMode.daily => '${_num(r.amount ?? 0)}/日',
  _ => '',
};

/// 20 分鐘, 2 小時 (fee.dart's spans).
String _span(int minutes) =>
    minutes % 60 == 0 ? '${minutes ~/ 60} 小時' : '$minutes 分鐘';

/// 可付 40 元延長 1 次, when the rate has a paid extension.
String? _extensionText(PlateRate r) =>
    r.extensionAmount == null || r.extensionTimes == null
    ? null
    : '可付 ${_num(r.extensionAmount!)} 元延長 ${r.extensionTimes} 次';

SignPlate _verdictPlate(FourSign s) {
  final v = s.verdict;
  final basis = _basisNote(v);
  final (tone, main, note) = switch (v.status) {
    EligibilityStatus.allowed => (PlateTone.allowed, '可停', basis),
    EligibilityStatus.conditional => (
      PlateTone.conditional,
      v.restriction?.label ?? '有條件',
      v.until != null
          ? '到 ${v.until}'
          : v.opensAt != null
          ? '${v.opensAt} 起'
          : basis,
    ),
    // 官方未標示 (A3): as unsure as 待確認, worded apart and drawn
    // dashed, since it is no conclusion either way.
    EligibilityStatus.unverified when v.notStated => (
      PlateTone.dashed,
      '不確定',
      '官方未標示',
    ),
    EligibilityStatus.unverified => (
      PlateTone.unverified,
      '待確認',
      switch (v.basis) {
        BasisKind.communityReport => '車友回報',
        BasisKind.adminLapsed => '曾確認',
        _ => '依現場公告',
      },
    ),
    EligibilityStatus.notAllowed => (
      PlateTone.denied,
      '${s.vehicle.label}不能停',
      basis,
    ),
  };
  if (v.status == EligibilityStatus.unverified && v.notStated) {
    return SignPlate(
      face: FourSignFace.verdict,
      main: main,
      note: note,
      tone: tone,
      semantics: '能不能停：不確定，官方與營運業者都沒有標示${s.vehicle.label}能不能停',
    );
  }
  return SignPlate(
    face: FourSignFace.verdict,
    main: main,
    note: note,
    tone: tone,
    semantics: [
      '能不能停：$main',
      if (v.status == EligibilityStatus.conditional && v.until != null)
        '現在可停到 ${v.until}'
      else if (v.status == EligibilityStatus.conditional && v.opensAt != null)
        '現在不能停，${v.opensAt} 起可停'
      else if (note.isNotEmpty)
        note,
    ].join('，'),
  );
}

SignPlate _seatPlate(FourSign s, DateTime now) {
  final seat = s.seat;
  final unit = s.street ? '段' : '區';
  // 停哪裡 already names a single place; the plate does not repeat it,
  // the screen reader does (2026-10-29).
  final named = seat.areas.isEmpty
      ? ''
      : seat.areas.map(signAreaName).join('、');
  final shown = s.singlePlace ? '' : named;
  final more = seat.more > 0 ? '另 ${seat.more} $unit有位' : null;
  String spoken(List<String> parts) =>
      ['有沒有位：${parts.first}', ...parts.skip(1), ?more].join('，');
  switch (seat.kind) {
    case SeatKind.live || SeatKind.delayed:
      final full = seat.available == 0;
      final main = full ? '已滿' : '剩 ${seat.available} 格';
      final delayed = seat.kind == SeatKind.delayed;
      final ago = seat.at == null ? '' : agoText(seat.at!, now);
      return SignPlate(
        face: FourSignFace.seat,
        main: main,
        note: [
          shown,
          if (delayed) '更新延遲',
          ago,
        ].where((t) => t.isNotEmpty).join('\n'),
        tone: delayed ? PlateTone.delayed : PlateTone.line,
        tag: more,
        semantics: spoken([
          '$named$main',
          delayed ? '官方資料更新延遲' : '官方即時',
          if (ago.isNotEmpty) '$ago更新',
        ]),
      );
    case SeatKind.suspended:
      return SignPlate(
        face: FourSignFace.seat,
        main: '暫停營運',
        tone: PlateTone.dashed,
        semantics: spoken(['暫停營運，來源標示場站停止服務']),
      );
    case SeatKind.rider:
      final r = seat.rider!;
      final ago = agoText(r.at, now);
      final main = r.conflict ? '說法不一' : riderLevelLabel(r.level);
      final high = r.conflict && r.otherLevel! > r.level
          ? r.otherLevel!
          : r.level;
      final low = r.conflict && r.otherLevel! > r.level
          ? r.level
          : r.otherLevel;
      final split = r.conflict
          ? '${r.highCount ?? 1} 人說${_riderLevelShort(high)}・'
                '${r.lowCount ?? 1} 人說${_riderLevelShort(low!)}'
          : null;
      return SignPlate(
        face: FourSignFace.seat,
        main: main,
        note: shown.isNotEmpty ? '$shown\n車友回報・$ago' : '車友回報\n${split ?? ago}',
        tone: PlateTone.rider,
        tag: more,
        meters: r.conflict ? [high, low!] : [r.level],
        semantics: spoken([
          r.conflict
              ? '車友回報說法不一，${split!.replaceAll('・', '，')}'
              : '$named${main == '很多空位' || main == '還有一些' ? '$main空位' : main}',
          if (!r.conflict) '車友回報',
          if (!r.conflict) ago,
        ]),
      );
    case SeatKind.total:
      final split = seat.counted > 1 ? '分 ${seat.counted} $unit' : '';
      return SignPlate(
        face: FourSignFace.seat,
        main: '共 ${seat.total} 格',
        note: [split, '空位未知'].where((t) => t.isNotEmpty).join('\n'),
        tone: PlateTone.dashed,
        semantics: spoken([
          '${seat.counted > 1 ? '' : named}共 ${seat.total} 格',
          ?(split.isEmpty ? null : split),
          '空位未知',
        ]),
      );
    case SeatKind.unknown:
      final note = s.verdict.status == EligibilityStatus.unverified
          ? ''
          : '到場再找';
      return SignPlate(
        face: FourSignFace.seat,
        main: '空位未知',
        note: note,
        tone: PlateTone.dashed,
        semantics: spoken(['空位未知', ?(note.isEmpty ? null : note)]),
      );
  }
}

SignPlate _feePlate(FourSign s) {
  final fee = s.fee;
  switch (fee.kind) {
    case FeeKind.rate:
      final r = fee.rate!;
      final note = [
        if (fee.places > 1) '全場同價',
        if (r.from != null && r.to != null) '${r.from}–${r.to}',
        if (r.dailyCap != null) '上限 ${_num(r.dailyCap!)}',
        ?_extensionText(r),
      ].join('\n');
      final main = plateRateText(r);
      return SignPlate(
        face: FourSignFace.fee,
        main: main,
        note: note,
        tone: PlateTone.line,
        semantics: [
          '怎麼算錢：${_spokenRate(r)}',
          if (fee.places > 1) '全場同價',
          if (r.from != null && r.to != null) '${r.from} 到 ${r.to}',
          if (r.dailyCap != null) '當日上限 ${_num(r.dailyCap!)} 元',
          ?_extensionText(r),
        ].join('，'),
      );
    case FeeKind.varies:
      final main = s.street ? '依路段' : '依分區';
      final hourly =
          fee.rates.isNotEmpty &&
          fee.rates.length == fee.places &&
          fee.rates.every((r) => r.hourly && r.amount != null);
      var note = '';
      if (hourly) {
        final amounts = [for (final r in fee.rates) r.amount!]..sort();
        note = amounts.first == amounts.last
            ? '${_num(amounts.first)}/時'
            : '${_num(amounts.first)}–${_num(amounts.last)}/時';
      }
      return SignPlate(
        face: FourSignFace.fee,
        main: main,
        note: note,
        tone: PlateTone.line,
        semantics: [
          '怎麼算錢：$main',
          if (note.isNotEmpty) '每小時 ${note.replaceAll('/時', '')} 元',
        ].join('，'),
      );
    case FeeKind.text:
      return SignPlate(
        face: FourSignFace.fee,
        main: fee.text!,
        tone: PlateTone.line,
        semantics: '怎麼算錢：${fee.text}',
      );
    case FeeKind.unknown:
      return const SignPlate(
        face: FourSignFace.fee,
        // No fee written: 未提供, for official and community spots alike
        // (user decision 2026-11-01).
        main: '未提供',
        tone: PlateTone.dashed,
        semantics: '怎麼算錢：未提供',
      );
  }
}

String _spokenRate(PlateRate r) => switch (r.mode) {
  FeeMode.free => '免費',
  FeeMode.hourly =>
    r.perMinutes == 60
        ? '每小時 ${_num(r.amount ?? 0)} 元'
        : '每 ${r.perMinutes} 分鐘 ${_num(r.amount ?? 0)} 元',
  FeeMode.perVisit =>
    r.firstMinutes != null
        ? '首 ${_span(r.firstMinutes!)} 0 元'
        : '每次 ${_num(r.amount ?? 0)} 元',
  FeeMode.daily => '每日 ${_num(r.amount ?? 0)} 元',
  _ => plateRateText(r),
};

SignPlate _wherePlate(FourSign s) {
  final areas = s.where.areas;
  final unit = s.street ? '段' : '區';
  if (areas.isEmpty) {
    if (s.street) {
      final bay = s.where.wholeBay;
      final kind = bay == null ? '路邊格' : SpaceKind.ofBay(bay).label;
      return SignPlate(
        face: FourSignFace.where,
        main: kind,
        tone: PlateTone.line,
        semantics: '停哪裡：$kind',
      );
    }
    final entrance = s.where.entrance;
    return SignPlate(
      face: FourSignFace.where,
      main: entrance.isEmpty ? '看入口公告' : '入口',
      note: entrance,
      tone: PlateTone.line,
      semantics: entrance.isEmpty ? '停哪裡：看入口公告' : '停哪裡：入口，$entrance',
    );
  }
  if (areas.length == 1) {
    final a = areas.single;
    final name = signAreaName(a);
    final short = _short(a, s.street);
    final rest = s.street && a.side != null
        ? (a.bayKind == null ? '' : SpaceKind.ofBay(a.bayKind!).label)
        : _split(name).$2;
    final note = rest.isNotEmpty
        ? rest
        : !s.street && a.bayKind != null
        ? SpaceKind.ofBay(a.bayKind!).label
        : '';
    return SignPlate(
      face: FourSignFace.where,
      main: short,
      note: note,
      tone: PlateTone.line,
      semantics: '停哪裡：$name',
    );
  }
  final main = '${areas.length} $unit';
  return SignPlate(
    face: FourSignFace.where,
    main: main,
    note: _list(areas.map((a) => _short(a, s.street))),
    tone: PlateTone.line,
    semantics: '停哪裡：$main，${areas.map(signAreaName).join('、')}',
  );
}

/// The plates [sign] shows at [now], in the rider's order; only the
/// 能不能停 plate when the vehicle may not park.
List<SignPlate> fourSignPlates(FourSign sign, DateTime now) {
  if (sign.denied) return [_verdictPlate(sign)];
  return [
    _verdictPlate(sign),
    _seatPlate(sign, now),
    _feePlate(sign),
    _wherePlate(sign),
  ];
}

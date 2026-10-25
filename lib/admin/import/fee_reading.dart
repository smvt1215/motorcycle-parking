/// Reads an existing `fee_note` into a structured [Fee], only where the text
/// says so for certain (docs/PLAN.md「費率結構」, ADMIN_WEB.md P6).
///
/// Two writings exist. Community notes come from `parse_fee` in
/// tool/import_mymaps.py: `每小時 30 元；每日 150 元（大型重機比照汽車費率）`,
/// the amount being what a heavy bike pays on that map layer. Official notes
/// are the government datasets' own text, which mostly price cars and list
/// monthly or disabled passes beside the motorcycle rate.
///
/// Nothing here guesses. A note with no motorcycle price stays unknown; one
/// whose motorcycle price depends on the day, the hour, the zone or a vehicle
/// the text leaves unnamed goes to a person, with the reading as a
/// suggestion when one exists.
library;

import '../../models/fee.dart';

/// The three lists of the conversion preview.
enum FeeVerdict {
  /// 可轉換: the fee is certain.
  convertible,

  /// 無法判斷: nothing to convert, the fee stays unconfirmed (null).
  unknown,

  /// 需人工確認: a price is there, but which vehicle or period it is for
  /// needs a person.
  manual,
}

class FeeReading {
  const FeeReading(this.verdict, this.reason, [this.fee]);
  final FeeVerdict verdict;

  /// Why, in words an admin reads in the preview.
  final String reason;

  /// The fee for [FeeVerdict.convertible]; a suggestion, if any, for
  /// [FeeVerdict.manual]; null for [FeeVerdict.unknown].
  final Fee? fee;

  @override
  String toString() => '$verdict($reason, ${fee?.toJson()})';
}

FeeReading _unknown(String reason) => FeeReading(FeeVerdict.unknown, reason);
FeeReading _manual(String reason, [Fee? hint]) => FeeReading(
  FeeVerdict.manual,
  reason,
  hint == null || hint.isEmpty ? null : hint,
);

/// Reads [note]. [spaceType] tells whose rate an unlabelled community note
/// is: on a heavy-only bay it can only be the heavy bike's.
FeeReading readFeeNote(String note, {String? spaceType}) {
  final text = _normalize(note);
  final bare = text.replaceAll(RegExp(r'[\s;；,，。.、:：|｜()（）\-]'), '');
  if (bare.isEmpty || _posted.hasMatch(bare)) {
    return _unknown('沒有寫明費率');
  }
  if (text.startsWith('大型重機依路段收費方式')) {
    return _manual('大型重機費率依路段收費方式而不同');
  }
  final community = _readCommunity(text, spaceType);
  if (community != null) return community;
  return _readOfficial(text);
}

/// Placeholder notes that state no price at all.
final _posted = RegExp(r'^(請依現場公告|依現場公告|詳見現場公告|未知|無|不詳)$');

String _normalize(String note) {
  final buffer = StringBuffer();
  for (final rune in note.trim().runes) {
    // Full-width digits and letters to ASCII; the ideographic space to a space.
    if (rune >= 0xff10 && rune <= 0xff19 ||
        rune >= 0xff21 && rune <= 0xff3a ||
        rune >= 0xff41 && rune <= 0xff5a) {
      buffer.writeCharCode(rune - 0xfee0);
    } else if (rune == 0x3000) {
      buffer.write(' ');
    } else {
      buffer.writeCharCode(rune);
    }
  }
  // 4,800元 → 4800元: thousands separators are not list separators.
  return buffer
      .toString()
      .replaceAllMapped(RegExp(r'(\d),(?=\d{3}(?!\d))'), (m) => m[1]!)
      .replaceAll(RegExp(r'免收費|不收費|免費停車'), '免費');
}

// ---------------------------------------------------------------------------
// Community notes: `<price>[；<price or note>]…[（<basis>）]`.

final _basis = RegExp(r'（((?:大型重機|重機專用格)[^（）]*)）$');
final _communityPrice = RegExp(
  r'^(.{0,4}?)(每小時|每 (\d+) 小時|每日|每次|每半天|隔夜|每月) (\d+) 元(.*)$',
);
final _communityFree = RegExp(r'^免費(.*)$');

/// Null when [text] is not in the community format.
FeeReading? _readCommunity(String text, String? spaceType) {
  final basisMatch = _basis.firstMatch(text);
  final body = basisMatch == null
      ? text
      : text.substring(0, basisMatch.start).trim();
  final segments = body.split('；').map((s) => s.trim()).toList();
  final first = segments.first;
  final looksCommunity =
      basisMatch != null ||
      _communityPrice.hasMatch(first) ||
      first == '免費' ||
      first.startsWith('免費；');
  if (!looksCommunity) return null;
  if (_posted.hasMatch(body.replaceAll(RegExp(r'\s'), ''))) {
    return _unknown('沒有寫明費率');
  }

  final prices = <({String unit, int amount, int hours})>[];
  var free = 0;
  var monthly = false;
  for (final segment in segments) {
    if (segment.isEmpty) continue;
    final price = _communityPrice.firstMatch(segment);
    if (price != null) {
      final label = price[1]!.trim();
      final tail = price[5]!.trim();
      // 機車每日 30 元 names the scooter rate the basis already speaks of.
      final scooterLabel = label == '機車' && basisMatch?[1] == '大型重機比照機車費率';
      if (label.isNotEmpty && !scooterLabel) {
        return _manual('依「$label」分別計費');
      }
      if (tail.startsWith('起')) return _manual('金額只寫起價');
      if (price[2] == '每月') {
        monthly = true;
        continue;
      }
      prices.add((
        unit: price[3] != null ? 'hours' : price[2]!,
        amount: int.parse(price[4]!),
        hours: int.tryParse(price[3] ?? '') ?? 1,
      ));
      continue;
    }
    final freeMatch = _communityFree.firstMatch(segment);
    if (freeMatch != null) {
      if (RegExp(r'\d').hasMatch(freeMatch[1]!)) {
        return _manual('只有一段時間免費');
      }
      free++;
      continue;
    }
    if (RegExp(r'折抵|優惠|折扣').hasMatch(segment)) {
      return _manual('另有折抵或優惠：$segment');
    }
    // Entrance and parking notes (需按鈴, 後牌, 機車區…) carry no price.
    if (segment.contains('元')) return _manual('有無法辨識的金額：$segment');
  }

  Rate? rate;
  if (free > 0) {
    if (free > 1 || prices.isNotEmpty) return _manual('免費與收費並列');
    rate = const Rate(FeeMode.free);
  } else if (prices.isEmpty) {
    return monthly ? _manual('只有月租費率') : _unknown('沒有寫明費率');
  } else {
    rate = _combine(prices);
    if (rate == null) {
      return _manual('多種收費方式並列：${prices.map(_priceText).join('、')}');
    }
  }

  final basis = basisMatch?[1];
  switch (basis) {
    case '大型重機比照機車費率':
      return FeeReading(
        FeeVerdict.convertible,
        '大型重機比照機車費率',
        Fee(scooter: rate, heavy: const Rate(FeeMode.sameAsScooter)),
      );
    case '大型重機比照汽車費率' || '重機專用格比照汽車費率':
      return FeeReading(
        FeeVerdict.convertible,
        '金額為大型重機付的汽車費率',
        Fee(heavy: rate),
      );
    case '大型重機停汽車區':
      return FeeReading(
        FeeVerdict.convertible,
        '金額為大型重機停汽車區的費率',
        Fee(heavy: rate),
      );
    case '大型重機另訂費率':
      return _manual('「另訂費率」未說明金額是否為大型重機費率', Fee(heavy: rate));
    case null:
      if (spaceType == 'heavyOnly') {
        return FeeReading(
          FeeVerdict.convertible,
          '重機專用格只有大型重機停放',
          Fee(heavy: rate),
        );
      }
      return _manual(
        '未註明是哪一種車的費率',
        spaceType == 'car' ? Fee(heavy: rate) : Fee(scooter: rate),
      );
    default:
      return _manual('無法辨識的費率依據：$basis');
  }
}

String _priceText(({String unit, int amount, int hours}) p) => switch (p.unit) {
  'hours' => '每 ${p.hours} 小時 ${p.amount} 元',
  _ => '${p.unit} ${p.amount} 元',
};

/// One rate from the listed prices, or null when they are not one rate:
/// an hourly price with an optional daily cap, or a single daily or
/// per-visit price.
Rate? _combine(List<({String unit, int amount, int hours})> prices) {
  final hourly = prices.where((p) => p.unit == '每小時' || p.unit == 'hours');
  final daily = prices.where((p) => p.unit == '每日');
  final visit = prices.where((p) => p.unit == '每次');
  if (prices.length != hourly.length + daily.length + visit.length) {
    return null; // 每半天, 隔夜
  }
  if (hourly.length == 1 && visit.isEmpty && daily.length <= 1) {
    final h = hourly.single;
    final cap = daily.firstOrNull?.amount;
    if (cap != null && cap < h.amount) return null;
    return _valid(
      Rate(
        FeeMode.hourly,
        amount: h.amount,
        perMinutes: h.hours * 60,
        dailyCap: cap,
      ),
    );
  }
  if (prices.length == 1 && daily.length == 1) {
    return _valid(Rate(FeeMode.daily, amount: daily.single.amount));
  }
  if (prices.length == 1 && visit.length == 1) {
    return _valid(Rate(FeeMode.perVisit, amount: visit.single.amount));
  }
  return null;
}

/// The rate if the column accepts it (the same check as `valid_fee()`).
Rate? _valid(Rate rate) =>
    Rate.fromJson(rate.toJson(), heavy: true) == null ? null : rate;

// ---------------------------------------------------------------------------
// Official notes: the datasets' own sentences.

enum _Vehicle { car, scooter, heavy, disabled }

class _Fact {
  _Fact(this.vehicles, this.rate, {this.qualified = false});
  final Set<_Vehicle> vehicles;
  Rate rate;
  final bool qualified;
}

final _sentenceBreak = RegExp(r'[。；;\n|｜]');
final _pieceBreak = RegExp(r'[，,、\s]+');
final _passKeyword = RegExp(r'月租|月票|雙月票|季租|季繳|季票|年票|/月|每月');
final _visitKeyword = RegExp(r'計時|計次|臨停');
final _heavyWord = RegExp(r'大型重型機車|大型重機|大重');
final _ambiguousHeavy = RegExp(r'(?<!大型)重型機車');
final _scooterWord = RegExp(r'(?<!重型|身障)機車');
final _carWord = RegExp(r'小型車|小車|汽車|大客車|大型車|貨車');
final _disabledWord = RegExp(r'身障|身心障礙');
final _qualifier = RegExp(
  r'平日|假日|週[一二三四五六日]|周[一二三四五六日]|日間|夜間|白天|晚上|\d{1,2}\s*[時點]?\s*[-~～至]\s*\d{1,2}\s*[時點]|\(\d{1,2}-\d{1,2}\)',
);
final _cap = RegExp(r'(?:上限|最高)(?:收費)?(?:上限)?\s*(\d+)\s*元(?:\s*/\s*[日天次])?');
final _daily = RegExp(
  r'(\d+)\s*元\s*/\s*[日天]|(?:每日|每天|當日計次)\s*[:：]?\s*(\d+)\s*元',
);
final _hourly = RegExp(
  r'(\d+)\s*元\s*/\s*(?:時|[Hh]|小時|hr)(?![a-z])|每小時\s*(\d+)\s*元',
);
final _halfHour = RegExp(r'(\d+)\s*元\s*/\s*半小時|每半小時\s*(\d+)\s*元');
final _minutes = RegExp(r'(\d+)\s*元\s*/\s*(\d+)\s*分(?:鐘)?');
final _visit = RegExp(r'(\d+)\s*元\s*/\s*次|(?:每次|計次|一次)\s*[:：]?\s*(\d+)\s*元');
final _hoursVisit = RegExp(r'(\d+)\s*元\s*/\s*(\d+)\s*小時');
final _laterVisit = RegExp(r'逾\s*(\d+)\s*小時[^，,。]*另計');

/// A price: an amount in yuan, `$15`, `30/次`, or 免費.
final _priced = RegExp(r'\d+\s*元|\$\s*\d|\d+\s*/\s*[次時日天Hh]|免費');
final _graceFree = RegExp(r'\d+\s*(?:分鐘|小時)[^，,。]*免費|免費\s*\d+\s*(?:分鐘|小時)');

FeeReading _readOfficial(String text) {
  if (RegExp(r'拖吊|保管費').hasMatch(text)) {
    return _manual('費率說明混有拖吊保管費');
  }
  final facts = <_Fact>[];
  final unparsed = <_Vehicle?>{};
  var unlabelledPrice = false;
  var carPrice = false;
  var ambiguousHeavy = false;
  var vehicles = <_Vehicle>{};
  var passes = false;
  for (final sentence in text.split(_sentenceBreak)) {
    var pass = false;
    // Caps belong to the latest hourly rate of the same vehicle in a sentence.
    final hourlies = <_Fact>[];
    // 平日 standing alone qualifies the prices after it in the sentence.
    var heading = false;
    for (final raw in sentence.split(_pieceBreak)) {
      final piece = raw.trim();
      if (piece.isEmpty) continue;
      final named = <_Vehicle>{
        if (_disabledWord.hasMatch(piece)) _Vehicle.disabled,
        if (_heavyWord.hasMatch(piece)) _Vehicle.heavy,
        if (_scooterWord.hasMatch(piece.replaceAll(_heavyWord, '')))
          _Vehicle.scooter,
        if (_carWord.hasMatch(piece)) _Vehicle.car,
      };
      final ambiguous = _ambiguousHeavy.hasMatch(piece);
      if (named.isNotEmpty || ambiguous) {
        vehicles = named.contains(_Vehicle.disabled)
            ? {_Vehicle.disabled}
            : named;
      }
      if (_passKeyword.hasMatch(piece)) {
        pass = passes = true;
      } else if (_visitKeyword.hasMatch(piece)) {
        pass = false;
      }
      if (_qualifier.hasMatch(piece) &&
          piece
              .replaceAll(_qualifier, '')
              .replaceAll(RegExp(r'[\s:：]'), '')
              .isEmpty) {
        heading = true;
      }
      final priced = _priced.hasMatch(piece);
      if (!priced || pass || vehicles.contains(_Vehicle.disabled)) continue;
      if (ambiguous && named.isEmpty) {
        ambiguousHeavy = true;
        continue;
      }
      // A grace period (入場前 30 分鐘免費) leaves the rate as it is.
      if (_graceFree.hasMatch(piece) &&
          !_priced.hasMatch(piece.replaceAll('免費', ''))) {
        continue;
      }
      final readings = _pricesIn(piece);
      final target = vehicles.isEmpty ? null : vehicles;
      if (target == null) {
        unlabelledPrice = true;
        continue;
      }
      if (target.contains(_Vehicle.car)) carPrice = true;
      final riders = target.intersection({_Vehicle.scooter, _Vehicle.heavy});
      if (riders.isEmpty) continue;
      if (readings == null) {
        unparsed.addAll(riders);
        continue;
      }
      final qualified = heading || _qualifier.hasMatch(piece);
      // Rates first, so a cap in the same piece finds its rate.
      for (final reading in [
        ...readings.where((r) => r.cap == null),
        ...readings.where((r) => r.cap != null),
      ]) {
        if (reading.cap != null) {
          final hourly = hourlies.reversed
              .where((f) => f.vehicles.containsAll(riders))
              .firstOrNull;
          if (hourly == null) {
            unparsed.addAll(riders);
          } else {
            final r = hourly.rate;
            hourly.rate = Rate(
              FeeMode.hourly,
              amount: r.amount,
              perMinutes: r.perMinutes,
              dailyCap: reading.cap,
            );
          }
          continue;
        }
        final fact = _Fact(riders, reading.rate!, qualified: qualified);
        facts.add(fact);
        if (fact.rate.mode == FeeMode.hourly) hourlies.add(fact);
      }
    }
  }

  if (ambiguousHeavy) {
    return _manual('另列「重型機車」費率，可能包含普通重型機車');
  }
  if (unparsed.isNotEmpty) {
    return _manual(
      '${unparsed.contains(_Vehicle.heavy) ? '大型重機' : '機車'}的費率寫法無法辨識',
    );
  }
  Rate? pick(_Vehicle vehicle) {
    final own = facts.where((f) => f.vehicles.contains(vehicle)).toList();
    if (own.isEmpty) return null;
    return own.first.rate;
  }

  String? conflict(_Vehicle vehicle) {
    final own = facts.where((f) => f.vehicles.contains(vehicle)).toList();
    if (own.isEmpty) return null;
    final name = vehicle == _Vehicle.heavy ? '大型重機' : '機車';
    if (own.map((f) => f.rate).toSet().length > 1) return '$name有多種費率';
    if (own.any((f) => f.qualified) && own.length < 2) {
      return '$name費率只寫了部分日期或時段';
    }
    return null;
  }

  final scooterConflict = conflict(_Vehicle.scooter);
  if (scooterConflict != null) return _manual(scooterConflict);
  final scooter = pick(_Vehicle.scooter);
  final heavyConflict = conflict(_Vehicle.heavy);
  // A heavy rate that varies by day or hour stays unconfirmed; a clear
  // scooter rate beside it is still certain.
  if (heavyConflict != null && scooter == null) return _manual(heavyConflict);
  final fee = Fee(
    scooter: scooter,
    heavy: heavyConflict == null ? pick(_Vehicle.heavy) : null,
  );
  if (fee.isEmpty) {
    if (unlabelledPrice) return _manual('未註明是哪一種車的費率');
    if (carPrice) return _unknown('只有汽車費率');
    return _unknown(passes ? '只有月租或定期票費率' : '沒有機車費率');
  }
  if (unlabelledPrice) return _manual('另有未註明車種的費率', fee);
  return FeeReading(
    FeeVerdict.convertible,
    heavyConflict == null
        ? '官方資料寫明${fee.heavy == null
              ? '機車'
              : fee.scooter == null
              ? '大型重機'
              : '機車與大型重機'}費率'
        : '官方資料寫明機車費率；$heavyConflict，維持未確認',
    fee,
  );
}

/// The prices in one piece, or null when it has a price this reader does
/// not know.
List<({Rate? rate, int? cap})>? _pricesIn(String piece) {
  var rest = piece;
  final found = <({Rate? rate, int? cap})>[];
  void take(RegExp pattern, ({Rate? rate, int? cap})? Function(Match) read) {
    rest = rest.replaceAllMapped(pattern, (m) {
      final value = read(m);
      if (value != null) found.add(value);
      return ' ';
    });
  }

  int amount(Match m) => int.parse((m[1] ?? m[2])!);
  take(_cap, (m) => (rate: null, cap: int.parse(m[1]!)));
  final later = _laterVisit.firstMatch(rest);
  rest = rest.replaceAll(_laterVisit, ' ');
  take(
    _daily,
    (m) => (rate: Rate(FeeMode.daily, amount: amount(m)), cap: null),
  );
  take(_halfHour, (m) {
    return (
      rate: Rate(FeeMode.hourly, amount: amount(m), perMinutes: 30),
      cap: null,
    );
  });
  take(_minutes, (m) {
    final minutes = int.parse(m[2]!);
    return (
      rate: Rate(FeeMode.hourly, amount: int.parse(m[1]!), perMinutes: minutes),
      cap: null,
    );
  });
  take(_hourly, (m) {
    return (
      rate: Rate(FeeMode.hourly, amount: amount(m), perMinutes: 60),
      cap: null,
    );
  });
  if (_hoursVisit.hasMatch(rest)) {
    if (!piece.contains('計次')) return null;
    take(_hoursVisit, (m) {
      return (
        rate: Rate(
          FeeMode.perVisit,
          amount: int.parse(m[1]!),
          maxMinutes: int.parse(m[2]!) * 60,
        ),
        cap: null,
      );
    });
  }
  take(_visit, (m) {
    final hours = int.tryParse(later?[1] ?? '');
    return (
      rate: Rate(
        FeeMode.perVisit,
        amount: amount(m),
        maxMinutes: hours == null ? null : hours * 60,
      ),
      cap: null,
    );
  });
  if (rest.contains('免費')) {
    if (_graceFree.hasMatch(piece)) return null;
    found.add((rate: const Rate(FeeMode.free), cap: null));
    rest = rest.replaceAll('免費', ' ');
  }
  // Anything priced that is left is a writing this reader does not know.
  if (RegExp(r'\d+\s*[元萬]|\$\s*\d|\d+\s*/\s*[次時日天Hh]').hasMatch(rest)) {
    return null;
  }
  for (final f in found) {
    final rate = f.rate;
    if (rate != null && _valid(rate) == null) return null;
    if (f.cap != null && (f.cap! < 0 || f.cap! > 10000)) return null;
  }
  return found.isEmpty ? null : found;
}

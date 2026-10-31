/// Stage 0 precheck (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.8): the rules
/// that only need the request itself, run while the rider types so the
/// hint sits under the field to change. The Edge Function runs the same rules
/// and is the one that enforces them; the rule data mirrors
/// supabase/functions/submit-report/precheck_rules.json and both sides run
/// precheck_cases.json (test/precheck_test.dart).
library;

import '../models/fee.dart' show mergeFeeJson;
import '../models/zone_entries.dart' show entriesPatch;

/// [hold] lets the request through, flagged for stricter review (design
/// §4.3); only [fix] and [reject] refuse it.
enum PrecheckAction { fix, hold, reject }

/// One broken rule: [field] is the payload path the rider corrects, such
/// as `scooter_allowed` or `parking_zones.1.fee.heavy`.
class PrecheckIssue {
  const PrecheckIssue(this.rule, this.action, this.field, this.message);
  final String rule;
  final PrecheckAction action;
  final String field;
  final String message;

  @override
  String toString() => '$rule@$field';
}

typedef PrecheckPattern = ({String source, String flags});
typedef PrecheckRule = ({
  PrecheckAction action,
  String message,
  List<PrecheckPattern> patterns,
});

const precheckVersion = 2;

const precheckPlaceholders = {
  '測試',
  '測試用',
  '測試測試',
  'test',
  'testing',
  'asdf',
  'asdfg',
  'asdfgh',
  'qwer',
  'qwerty',
  'abc',
  'aaa',
  'xxx',
  'ooo',
  '123',
  '1234',
  '12345',
  '不知道',
  '不清楚',
  '不確定',
  '未知',
  '無',
  '沒有',
  '停車場',
  '停車格',
  '停車位',
};

/// Rules between a bay's condition and its fee. In a suggestion that names
/// only one of the two, the other is the spot's stored value: the rider can
/// fix only one side at a time, so these flag the case (hold) instead of
/// refusing it, and the reviewer applies both.
const precheckStoredPairHold = {
  'charge_free_rate',
  'charge_toll_free_rate',
  'free_with_renew',
  'free_with_extension',
  'heavy_bay_scooter_fee',
  'motorcycle_bay_car_fee',
  'time_limit_mismatch',
};

const Map<String, PrecheckRule> precheckRules = {
  'lot_roadside': (
    action: PrecheckAction.fix,
    message: '路外停車場不能選「路邊」場站型式。請改選立體、地下或平面；不確定就選未確認。',
    patterns: [],
  ),
  'street_lot_details': (
    action: PrecheckAction.fix,
    message: '場站型式和分區只用在路外停車場。請把格位類型改成路外停車場，或清除場站型式與分區。',
    patterns: [],
  ),
  'heavy_only_scooter': (
    action: PrecheckAction.fix,
    message: '大型重機專用格不能停普通機車。普通機車請改選不可停或未確認，或把格位類型改成地面畫的那一種。',
    patterns: [],
  ),
  'access_no_motorcycle': (
    action: PrecheckAction.fix,
    message: '停放分類是「機車不可停」，{vehicle}就不能選可停。請改停放分類，或把{vehicle}改成不可停或未確認。',
    patterns: [],
  ),
  'access_heavy_only_scooter': (
    action: PrecheckAction.fix,
    message: '停放分類是「大型重機專用」，普通機車就不能選可停。請改停放分類，或把普通機車改成不可停或未確認。',
    patterns: [],
  ),
  'access_scooter_only_heavy': (
    action: PrecheckAction.fix,
    message: '停放分類是「普通機車專用」，大型重機就不能選可停。請改停放分類，或把大型重機改成不可停或未確認。',
    patterns: [],
  ),
  'zones_no_motorcycle': (
    action: PrecheckAction.fix,
    message: '每個分區都標成「機車不可停」，{vehicle}就不能選可停。請改分區的停放分類，或把{vehicle}改成不可停或未確認。',
    patterns: [],
  ),
  'fee_follows_missing_scooter': (
    action: PrecheckAction.fix,
    message: '{where}大型重機選了「比照機車費率」，但普通機車的收費方式是未確認。請填普通機車的費率，或改選大型重機的收費方式。',
    patterns: [],
  ),
  'fee_follows_missing_car': (
    action: PrecheckAction.fix,
    message: '{where}大型重機比照汽車費率，但還沒填汽車費率。請填汽車費率，或改選其他收費方式。',
    patterns: [],
  ),
  'fee_cap_below_amount': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}的當日上限 {cap} 元比計時金額 {amount} 元還低。請照收費牌重填；沒有上限就留空。',
    patterns: [],
  ),
  'fee_hourly_zero': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}計時 0 元等於免費。格位免費請選「免費」；前段免費請填「前幾分鐘 0 元」。',
    patterns: [],
  ),
  'fee_zero_visit': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}{mode} 0 元等於免費。格位免費請選「免費」；公告寫首段 0 元時，計次請填有效時間。',
    patterns: [],
  ),
  'charge_free_rate': (
    action: PrecheckAction.fix,
    message: '{where}這是免費格，{vehicle}的費率卻不是「免費」。請把{vehicle}改成免費，或把收費屬性改成收費格。',
    patterns: [],
  ),
  'charge_toll_free_rate': (
    action: PrecheckAction.fix,
    message:
        '{where}這是收費格，{vehicle}的費率不能是「免費」。公告寫首段 0 元時，請填「前幾分鐘 0 元」或計次的有效時間。',
    patterns: [],
  ),
  'share_free_needs_basis': (
    action: PrecheckAction.hold,
    message: '普大共用的免費格較少見，請附上公告連結，審核會比較快。',
    patterns: [],
  ),
  'heavy_bay_scooter_fee': (
    action: PrecheckAction.fix,
    message: '{where}重機專用格不能停普通機車，不用填普通機車的費率。請把普通機車改回未確認。',
    patterns: [],
  ),
  'motorcycle_bay_car_fee': (
    action: PrecheckAction.fix,
    message: '{where}機車格或機車區不用填汽車費率。請把汽車改回未確認；汽車區請另外新增分區。',
    patterns: [],
  ),
  'car_area_scooter_fee': (
    action: PrecheckAction.hold,
    message: '{where}汽車區通常不開放普通機車。現場公告開放時，請附上公告連結，審核會比較快。',
    patterns: [],
  ),
  'time_limit_mismatch': (
    action: PrecheckAction.fix,
    message:
        '{where}限時 {limit} 分鐘，和{vehicle}計次的有效時間 {minutes} 分鐘不同。請照公告改成一樣的時間。',
    patterns: [],
  ),
  'cross_period_single': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}的計次時段不到兩段，沒有可以跨的時段。請把「停到下一個時段時」改回未確認。',
    patterns: [],
  ),
  'free_with_renew': (
    action: PrecheckAction.fix,
    message: '{where}這是免費格，{vehicle}不用填「跨日怎麼收」。請改回未確認，或把收費屬性改成收費格。',
    patterns: [],
  ),
  'free_with_extension': (
    action: PrecheckAction.fix,
    message: '{where}這是免費格，{vehicle}不用填付費延長。請刪除延長，或把收費屬性改成收費格。',
    patterns: [],
  ),
  'gone_with_changes': (
    action: PrecheckAction.fix,
    message: '回報「這裡已經不能停車」時不能同時修改其他資料。請只送出這筆回報，其他修改另外提出建議。',
    patterns: [],
  ),
  'placeholder_name': (
    action: PrecheckAction.fix,
    message: '「{value}」看不出是哪個停車點。請填現場看得到的名稱，例如「信義路五段收費機車格」。',
    patterns: [],
  ),
  'placeholder_text': (
    action: PrecheckAction.fix,
    message: '「{value}」看不出現場狀況。請寫你看到的內容，例如「格線已塗銷，改成人行道」。',
    patterns: [],
  ),
  'pii_email': (
    action: PrecheckAction.reject,
    message: '內容含有 Email。為保護個人資料，請刪除 Email 再送出。',
    patterns: [
      (
        source: r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}',
        flags: '',
      ),
    ],
  ),
  'pii_phone': (
    action: PrecheckAction.reject,
    message: '內容含有電話號碼。為保護個人資料，請刪除電話號碼再送出。',
    patterns: [
      (
        source: r'(?<![0-9])(?:\+?886[- ]?|0)9[0-9]{2}[- ]?[0-9]{3}[- ]?[0-9]{3}(?![0-9])',
        flags: '',
      ),
      (
        source: r'(?<![0-9])(?:\(0[2-8][0-9]?\)[- ]?|0[2-8][0-9]?-)[0-9]{3,4}-?[0-9]{4}(?![0-9])',
        flags: '',
      ),
    ],
  ),
  'pii_national_id': (
    action: PrecheckAction.reject,
    message: '內容含有身分證或居留證號碼。為保護個人資料，請刪除號碼再送出。',
    patterns: [
      (
        source: r'(?<![A-Za-z0-9])[A-Za-z][1289][0-9]{8}(?![A-Za-z0-9])',
        flags: '',
      ),
    ],
  ),
  'pii_plate': (
    action: PrecheckAction.reject,
    message: '內容含有車牌號碼。為保護個人資料，請刪除車牌再送出。',
    patterns: [
      (
        source: r'(?<![A-Za-z0-9-])(?:[A-Z]{3}-[0-9]{3,4}|[A-Z]{2}-[0-9]{4}|[0-9]{3}-[A-Z]{3}|[0-9]{4}-[A-Z]{2})(?![A-Za-z0-9-])',
        flags: '',
      ),
    ],
  ),
  'ad_url': (
    action: PrecheckAction.reject,
    message: '內容含有網址。請刪除網址，把需要的資訊直接寫成文字。',
    patterns: [
      (source: r'(?:https?://|www\.)[^\s]+', flags: 'i'),
      (
        source: r'(?<![A-Za-z0-9@.-])[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.(?:com|net|org|tw|io|me|cc|app|info|biz|xyz|link|ly|gl)(?![A-Za-z0-9])',
        flags: 'i',
      ),
    ],
  ),
};

final _patterns = [
  for (final MapEntry(key: code, value: rule) in precheckRules.entries)
    for (final p in rule.patterns)
      (
        code: code,
        regex: RegExp(
          p.source,
          unicode: true,
          caseSensitive: !p.flags.contains('i'),
        ),
      ),
];

PrecheckIssue _issue(
  String rule,
  String field, [
  Map<String, Object> params = const {},
]) {
  final r = precheckRules[rule]!;
  return PrecheckIssue(
    rule,
    r.action,
    field,
    r.message.replaceAllMapped(
      RegExp(r'\{(\w+)\}'),
      (m) => '${params[m[1]] ?? ''}',
    ),
  );
}

/// Full-width letters, digits and signs as ASCII, so ０９１２ reads as 0912.
String halfWidth(String text) => String.fromCharCodes(
  text.runes.map(
    (c) => c >= 0xFF01 && c <= 0xFF5E
        ? c - 0xFEE0
        : c == 0x3000
        ? 0x20
        : c,
  ),
);

const _idLetters = 'ABCDEFGHJKLMNPQRSTUVXYWZIO';

bool _validNationalId(String id) {
  final upper = id.toUpperCase();
  final n = _idLetters.indexOf(upper[0]) + 10;
  var sum = n ~/ 10 + (n % 10) * 9;
  for (var i = 1; i < 9; i++) {
    sum += int.parse(upper[i]) * (9 - i);
  }
  return (sum + int.parse(upper[9])) % 10 == 0;
}

/// The personal-data or link rules [text] breaks, one per rule.
List<String> precheckTextRules(String text) {
  final value = halfWidth(text);
  final hits = <String>[];
  for (final (:code, :regex) in _patterns) {
    if (hits.contains(code)) continue;
    final found = regex
        .allMatches(value)
        .any((m) => code != 'pii_national_id' || _validNationalId(m[0]!));
    if (found) hits.add(code);
  }
  return hits;
}

final _bare = RegExp(r'[\s\p{P}\p{S}]', unicode: true);

/// Whether [text] is a stand-in such as 測試 or asdf rather than content.
bool isPlaceholder(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  final bare = halfWidth(trimmed).toLowerCase().replaceAll(_bare, '');
  return bare.isEmpty || precheckPlaceholders.contains(bare);
}

/// The first hint for one free-text field as the rider types: personal
/// data, then a placeholder when the text is a [name] or a [solo] note (the
/// whole suggestion). Null when the text may be sent.
String? precheckTextHint(String? text, {bool name = false, bool solo = false}) {
  if (text == null || text.trim().isEmpty) return null;
  final hits = precheckTextRules(text);
  if (hits.isNotEmpty) return _issue(hits.first, '').message;
  if ((name || solo) && isPlaceholder(text)) {
    return _issue(name ? 'placeholder_name' : 'placeholder_text', '', {
      'value': text.trim(),
    }).message;
  }
  return null;
}

typedef _Json = Map<String, Object?>;
const _vehicles = {'scooter': '普通機車', 'heavy': '大型重機'};
const _lotFacilities = ['multiStorey', 'underground', 'surface'];

List<PrecheckIssue> _combinations(_Json s) {
  final out = <PrecheckIssue>[];
  final zones = [
    if (s['parking_zones'] case final List<Object?> list)
      for (final z in list)
        if (z is Map) z.cast<String, Object?>(),
  ];
  if (s.containsKey('space_type')) {
    final type = s['space_type'];
    // The set a new build sends (decision 58), else the one type: any of
    // them that does not fit the space type counts.
    final types = switch (s['facility_types']) {
      final List<Object?> list => [for (final t in list) '$t'],
      _ => [?s['facility_type']?.toString()],
    };
    final field = s.containsKey('facility_types')
        ? 'facility_types'
        : 'facility_type';
    if (type == 'offStreet' && types.contains('roadside')) {
      out.add(_issue('lot_roadside', field));
    }
    if (type != 'offStreet') {
      if (types.any(_lotFacilities.contains)) {
        out.add(_issue('street_lot_details', field));
      }
      if (zones.isNotEmpty) {
        out.add(_issue('street_lot_details', 'parking_zones'));
      }
    }
    if (type == 'heavyOnly' && s['scooter_allowed'] == true) {
      out.add(_issue('heavy_only_scooter', 'scooter_allowed'));
    }
  }
  for (final MapEntry(key: key, value: vehicle) in _vehicles.entries) {
    final field = '${key}_allowed';
    if (s[field] != true) continue;
    final access = s['parking_access'];
    if (access == 'noMotorcycle') {
      out.add(_issue('access_no_motorcycle', field, {'vehicle': vehicle}));
    }
    if (key == 'scooter' && access == 'heavyOnly') {
      out.add(_issue('access_heavy_only_scooter', field));
    }
    if (key == 'heavy' && access == 'scooterOnly') {
      out.add(_issue('access_scooter_only_heavy', field));
    }
    if (zones.isNotEmpty && zones.every((z) => z['access'] == 'noMotorcycle')) {
      out.add(_issue('zones_no_motorcycle', field, {'vehicle': vehicle}));
    }
  }
  // A lot's condition lives in its zones (§1.2); riders send zone areas.
  final condition = s['space_type'] != 'offStreet' && s['condition'] is Map
      ? (s['condition']! as Map).cast<String, Object?>()
      : null;
  if (s['fee'] case final Map<Object?, Object?> fee) {
    out.addAll(precheckFee(fee.cast(), field: 'fee', condition: condition));
  }
  for (final (i, zone) in zones.indexed) {
    if (zone['fee'] case final Map<Object?, Object?> fee) {
      out.addAll(
        precheckFee(
          fee.cast(),
          field: 'parking_zones.$i.fee',
          where: '分區 ${i + 1}：',
          condition: switch (zone['condition']) {
            final Map<Object?, Object?> c => c.cast(),
            _ => null,
          },
          area: zone['area'] as String?,
        ),
      );
    }
  }
  return out;
}

/// A free 普大共用 bay the request itself writes: rare, so it waits for a
/// notice (§4.3, §1.4); a spot already stored that way is not re-flagged.
List<PrecheckIssue> _shareFree(Object? condition, String field) => [
  if (condition case {'share': 'scooter_heavy', 'charge': 'free'})
    _issue('share_free_needs_basis', field),
];

const _feeVehicles = {..._vehicles, 'car': '汽車'};

/// The rates one vehicle pays: its own, or the periods of a by_time rate.
List<Map<Object?, Object?>> _ratesOf(Map<Object?, Object?> rate) =>
    rate['mode'] == 'by_time' && rate['periods'] is List
    ? [
        for (final p in rate['periods']! as List)
          if (p case {'rate': final Map<Object?, Object?> r}) r,
      ]
    : [rate];

/// A heavy follow's mode as the vehicle it follows; others as they are.
Object? _modeOf(Map<String, Object?> fee, String key) {
  final rate = fee[key];
  if (rate is! Map) return null;
  return switch ((key, rate['mode'])) {
    ('heavy', 'same_as_scooter') => (fee['scooter'] as Map?)?['mode'],
    ('heavy', 'same_as_car') => (fee['car'] as Map?)?['mode'],
    (_, final mode) => mode,
  };
}

/// The structural contradictions in one fee, as JSON (`Fee.toJson`), and
/// those between it and the bay it is for (§4.3): the bay's [condition], or
/// a zone's [area].
List<PrecheckIssue> precheckFee(
  Map<String, Object?> fee, {
  String field = 'fee',
  String where = '',
  Map<String, Object?>? condition,
  String? area,
}) {
  final out = <PrecheckIssue>[];
  if (fee['heavy'] case {'mode': 'same_as_scooter'}
      when fee['scooter'] == null) {
    out.add(
      _issue('fee_follows_missing_scooter', '$field.heavy', {'where': where}),
    );
  }
  if (fee['heavy'] case {'mode': 'same_as_car'} when fee['car'] == null) {
    out.add(
      _issue('fee_follows_missing_car', '$field.heavy', {'where': where}),
    );
  }
  final limit = switch (condition?['limits']) {
    final List<Object?> limits =>
      limits
          .whereType<Map<Object?, Object?>>()
          .where((l) => l['kind'] == 'time_limit')
          .firstOrNull,
    _ => null,
  };
  final charge = condition?['charge'];
  for (final MapEntry(key: key, value: vehicle) in _feeVehicles.entries) {
    final rate = fee[key];
    if (rate is! Map) continue;
    final at = '$field.$key';
    final params = {'where': where, 'vehicle': vehicle};
    final rates = _ratesOf(rate);
    for (final r in rates) {
      final amount = r['amount'];
      final mode = r['mode'];
      if (mode == 'hourly' && amount == 0 && r['free_minutes'] == null) {
        out.add(_issue('fee_hourly_zero', at, params));
      }
      final cap = r['daily_cap'];
      if (mode == 'hourly' && cap is num && amount is num && cap < amount) {
        out.add(
          _issue('fee_cap_below_amount', at, {
            ...params,
            'cap': cap,
            'amount': amount,
          }),
        );
      }
      // 首段 0 元 is a per-visit 0 with a valid time (§2.3), never free.
      if ((mode == 'per_visit' && amount == 0 && r['max_minutes'] == null) ||
          (mode == 'daily' && amount == 0)) {
        out.add(
          _issue('fee_zero_visit', at, {
            ...params,
            'mode': mode == 'daily' ? '每日' : '計次',
          }),
        );
      }
      if (limit?['max_minutes'] case final num minutes
          when mode == 'per_visit' &&
              r['max_minutes'] is num &&
              r['max_minutes'] != minutes) {
        out.add(
          _issue('time_limit_mismatch', at, {
            ...params,
            'limit': minutes,
            'minutes': r['max_minutes']!,
          }),
        );
      }
    }
    if (rate['mode'] == 'by_time' &&
        rate['cross_period'] != null &&
        rates.where((r) => r['mode'] == 'per_visit').length < 2) {
      out.add(_issue('cross_period_single', at, params));
    }
    final mode = _modeOf(fee, key);
    if (charge == 'free') {
      if (mode != null && mode != 'free') {
        out.add(_issue('charge_free_rate', at, params));
      }
      if (rates.any((r) => r['renew'] != null)) {
        out.add(_issue('free_with_renew', at, params));
      }
      if (rates.any((r) => r['extension'] != null)) {
        out.add(_issue('free_with_extension', at, params));
      }
    }
    if (charge == 'toll' && mode == 'free') {
      out.add(_issue('charge_toll_free_rate', at, params));
    }
  }
  if (condition?['bay'] == 'heavy' && fee.containsKey('scooter')) {
    out.add(
      _issue('heavy_bay_scooter_fee', '$field.scooter', {'where': where}),
    );
  }
  if ((condition?['bay'] == 'motorcycle' || area == 'motorcycle') &&
      fee.containsKey('car')) {
    out.add(_issue('motorcycle_bay_car_fee', '$field.car', {'where': where}));
  }
  if (area == 'car' && fee.containsKey('scooter')) {
    out.add(_issue('car_area_scooter_fee', '$field.scooter', {'where': where}));
  }
  return out;
}

List<({String field, String value, bool name})> _texts(_Json body) {
  final out = <({String field, String value, bool name})>[];
  void add(String field, Object? value, [bool name = false]) {
    if (value is String && value.trim().isNotEmpty) {
      out.add((field: field, value: value, name: name));
    }
  }

  // The free text of zones and segments (#188): names, guides and ranges.
  void entryTexts(String field, Object? list) {
    if (list is! List) return;
    for (final (i, e) in list.indexed) {
      if (e is! Map) continue;
      add('$field.$i.name', e['name'], true);
      add('$field.$i.guide', e['guide']);
      add('$field.$i.range', e['range']);
    }
  }

  if (body['spot'] case final Map<Object?, Object?> s) {
    add('name', s['name'], true);
    for (final key in ['fee_note', 'note', 'entrance_note', 'parking_guide']) {
      add(key, s[key]);
    }
    entryTexts('parking_zones', s['parking_zones']);
    entryTexts('parking_segments', s['parking_segments']);
  }
  if (body['proposed'] case final Map<Object?, Object?> p) {
    add('proposed.name', p['name'], true);
    // Zone and segment patches (#188): the same free text, by position.
    entryTexts('proposed.parking_zones', p['parking_zones']);
    entryTexts('proposed.parking_segments', p['parking_segments']);
    for (final key in [
      'fee_note',
      'note',
      'address',
      'road_segment',
      'entrance_note',
      'parking_guide',
      'special_rules',
    ]) {
      add('proposed.$key', p[key]);
    }
  }
  add('note', body['note']);
  if (body['action'] == 'flag') add('reason', body['reason']);
  return out;
}

const _goneFields = ['gone', '點位已不存在'];

/// The zone or segment list a suggestion's [patch] leaves (#188): applied
/// by id to [current] when it is known and names only entries it has; else
/// the patch's own entries, less those it removes.
List<Object?> patchedEntries(Object? current, List<Object?> patch) =>
    (current is List ? entriesPatch(current, patch) : null) ??
    [
      for (final e in patch)
        if (e is! Map || e['removed'] != true) e,
    ];

/// Every stage 0 rule [body], a submit-report request, breaks. A fee
/// suggestion changes only the vehicles it names (design §5.4), so its rules
/// run on the fee it leaves: [current] (the spot's stored values, when
/// known) merged with it.
List<PrecheckIssue> precheck(
  Map<String, Object?> body, {
  Map<String, Object?>? current,
}) {
  final out = <PrecheckIssue>[];
  final action = body['action'];
  final spot = (action == 'create' || action == 'update') ? body['spot'] : null;
  final proposed = action == 'flag' ? body['proposed'] : null;
  if (spot is Map) {
    out.addAll(_combinations(spot.cast()));
    if (spot['space_type'] != 'offStreet') {
      out.addAll(_shareFree(spot['condition'], 'condition.charge'));
    }
  }
  if (proposed is Map) {
    // The fee a suggestion leaves, judged with the condition it leaves: its
    // own, or the spot's (§4.3, merged results). A new condition is judged
    // with the stored fee it would sit beside.
    final judged = proposed['fee'] is Map || proposed['condition'] is Map;
    final merged = <String, Object?>{
      ...proposed.cast<String, Object?>(),
      if (judged && (proposed['fee'] is Map || current?['fee'] is Map))
        'fee': mergeFeeJson(current?['fee'], proposed['fee']),
      if (judged &&
          !proposed.containsKey('condition') &&
          current?['condition'] is Map)
        'condition': current!['condition'],
      // Zone and segment patches (#188) are judged as the lists they leave.
      for (final key in const ['parking_zones', 'parking_segments'])
        if (proposed[key] is List)
          key: patchedEntries(current?[key], proposed[key]! as List<Object?>),
    };
    // Whether the suggestion's condition or fee is the spot's stored one.
    final storedPair =
        proposed['fee'] is! Map || !proposed.containsKey('condition');
    for (final i in _combinations(merged)) {
      out.add(
        PrecheckIssue(
          i.rule,
          storedPair && precheckStoredPairHold.contains(i.rule)
              ? PrecheckAction.hold
              : i.action,
          'proposed.${i.field}',
          i.message,
        ),
      );
    }
    out.addAll(_shareFree(proposed['condition'], 'proposed.condition.charge'));
    if (_goneFields.contains(body['field']) &&
        // A closure (#116) is what works or a closure suggest instead.
        proposed.keys.any(
          (k) => k != 'hidden' && k != 'status' && k != 'closure',
        )) {
      out.add(_issue('gone_with_changes', 'proposed'));
    }
  }
  for (final (:field, :value, :name) in _texts(body)) {
    for (final code in precheckTextRules(value)) {
      out.add(_issue(code, field));
    }
    final solo =
        field == 'note' &&
        action == 'flag' &&
        proposed is! Map &&
        !_goneFields.contains(body['field']);
    if ((name || solo) && isPlaceholder(value)) {
      out.add(
        _issue(name ? 'placeholder_name' : 'placeholder_text', field, {
          'value': value.trim(),
        }),
      );
    }
  }
  return out;
}

/// The issues that refuse the request; a [PrecheckAction.hold] only flags it.
List<PrecheckIssue> precheckBlocking(Iterable<PrecheckIssue> issues) => [
  for (final i in issues)
    if (i.action != PrecheckAction.hold) i,
];

/// The messages for issues under [prefix] (e.g. `fee` or
/// `parking_zones.1.fee`), joined for one hint under that field: the ones
/// that refuse the report, or with [holds] the ones that only flag it.
String? precheckHint(
  Iterable<PrecheckIssue> issues,
  String prefix, {
  bool holds = false,
}) {
  final messages = {
    for (final i in issues)
      if ((i.field == prefix || i.field.startsWith('$prefix.')) &&
          (i.action == PrecheckAction.hold) == holds)
        i.message,
  };
  return messages.isEmpty ? null : messages.join('\n');
}

/// The sentence when an admin has deleted the spot a report names (#200):
/// riders can no longer vote on, suggest, edit or restore it.
const spotDeletedMessage = '這個點已被刪除';

/// The rider-facing reason in a submit-report refusal the forms show as is:
/// a precheck refusal's sentence, or [spotDeletedMessage]; null otherwise.
String? reportRefusal(Object? details) =>
    precheckRefusal(details) ??
    switch (details) {
      {'error': 'spot deleted'} => spotDeletedMessage,
      _ => null,
    };

/// The rider-facing reason in a submit-report refusal, or null when the
/// body is not a precheck refusal (older servers send only `error`).
String? precheckRefusal(Object? details) => switch (details) {
  {'error': final String error, 'message': final String message}
      when error.startsWith('precheck ') =>
    message,
  _ => null,
};

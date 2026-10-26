/// Stage 0 precheck (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §5.8): the rules
/// that only need the request itself, run while the rider types so the
/// hint sits under the field to change. The Edge Function runs the same rules
/// and is the one that enforces them; the rule data mirrors
/// supabase/functions/submit-report/precheck_rules.json and both sides run
/// precheck_cases.json (test/precheck_test.dart).
library;

import '../models/fee.dart' show mergeFeeJson;

enum PrecheckAction { fix, reject }

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

const precheckVersion = 1;

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
  'fee_cap_below_amount': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}的當日上限 {cap} 元比計時金額 {amount} 元還低。請照收費牌重填；沒有上限就留空。',
    patterns: [],
  ),
  'fee_hourly_zero': (
    action: PrecheckAction.fix,
    message: '{where}{vehicle}的計時金額是 0 元。不收費請改選「免費」。',
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
    if (type == 'offStreet' && s['facility_type'] == 'roadside') {
      out.add(_issue('lot_roadside', 'facility_type'));
    }
    if (type != 'offStreet') {
      if (_lotFacilities.contains(s['facility_type'])) {
        out.add(_issue('street_lot_details', 'facility_type'));
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
  if (s['fee'] case final Map<Object?, Object?> fee) {
    out.addAll(precheckFee(fee.cast(), field: 'fee'));
  }
  for (final (i, zone) in zones.indexed) {
    if (zone['fee'] case final Map<Object?, Object?> fee) {
      out.addAll(
        precheckFee(
          fee.cast(),
          field: 'parking_zones.$i.fee',
          where: '分區 ${i + 1}：',
        ),
      );
    }
  }
  return out;
}

/// The structural contradictions in one fee, as JSON (`Fee.toJson`).
List<PrecheckIssue> precheckFee(
  Map<String, Object?> fee, {
  String field = 'fee',
  String where = '',
}) {
  final out = <PrecheckIssue>[];
  if (fee['heavy'] case {'mode': 'same_as_scooter'}
      when fee['scooter'] == null) {
    out.add(
      _issue('fee_follows_missing_scooter', '$field.heavy', {'where': where}),
    );
  }
  for (final MapEntry(key: key, value: vehicle) in _vehicles.entries) {
    final rate = fee[key];
    if (rate is! Map || rate['mode'] != 'hourly') continue;
    final params = {'where': where, 'vehicle': vehicle};
    final amount = rate['amount'];
    if (amount == 0) out.add(_issue('fee_hourly_zero', '$field.$key', params));
    final cap = rate['daily_cap'];
    if (cap is num && amount is num && cap < amount) {
      out.add(
        _issue('fee_cap_below_amount', '$field.$key', {
          ...params,
          'cap': cap,
          'amount': amount,
        }),
      );
    }
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

  if (body['spot'] case final Map<Object?, Object?> s) {
    add('name', s['name'], true);
    for (final key in ['fee_note', 'note', 'entrance_note', 'parking_guide']) {
      add(key, s[key]);
    }
    if (s['parking_zones'] case final List<Object?> zones) {
      for (final (i, z) in zones.indexed) {
        if (z is! Map) continue;
        add('parking_zones.$i.name', z['name'], true);
        add('parking_zones.$i.guide', z['guide']);
      }
    }
  }
  if (body['proposed'] case final Map<Object?, Object?> p) {
    add('proposed.name', p['name'], true);
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
  if (spot is Map) out.addAll(_combinations(spot.cast()));
  if (proposed is Map) {
    final merged = <String, Object?>{
      ...proposed.cast<String, Object?>(),
      if (proposed['fee'] is Map)
        'fee': mergeFeeJson(current?['fee'], proposed['fee']),
    };
    for (final i in _combinations(merged)) {
      out.add(
        PrecheckIssue(i.rule, i.action, 'proposed.${i.field}', i.message),
      );
    }
    if (_goneFields.contains(body['field']) &&
        proposed.keys.any((k) => k != 'hidden' && k != 'status')) {
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

/// The messages for issues under [prefix] (e.g. `fee` or
/// `parking_zones.1.fee`), joined for one hint under that field.
String? precheckHint(Iterable<PrecheckIssue> issues, String prefix) {
  final messages = {
    for (final i in issues)
      if (i.field == prefix || i.field.startsWith('$prefix.')) i.message,
  };
  return messages.isEmpty ? null : messages.join('\n');
}

/// The rider-facing reason in a submit-report refusal, or null when the
/// body is not a precheck refusal (older servers send only `error`).
String? precheckRefusal(Object? details) => switch (details) {
  {'error': final String error, 'message': final String message}
      when error.startsWith('precheck ') =>
    message,
  _ => null,
};

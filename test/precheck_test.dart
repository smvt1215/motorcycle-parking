import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/precheck.dart';

/// The Edge Function's rule data and cases, the single source both sides
/// must agree with.
const _dir = 'supabase/functions/submit-report';
Map<String, Object?> _json(String name) =>
    jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('the app mirrors the Edge Function rule data exactly', () {
    final data = _json('precheck_rules.json');
    expect(data['version'], precheckVersion);
    expect((data['placeholders']! as List).toSet(), precheckPlaceholders);
    final rules = (data['rules']! as Map).cast<String, Map<String, Object?>>();
    expect(rules.keys.toSet(), precheckRules.keys.toSet());
    for (final MapEntry(:key, :value) in rules.entries) {
      final mine = precheckRules[key]!;
      expect(mine.action.name, value['action'], reason: key);
      expect(mine.message, value['message'], reason: key);
      expect(
        [
          for (final p in mine.patterns) {'source': p.source, 'flags': p.flags},
        ],
        value['patterns'] ?? const [],
        reason: key,
      );
    }
  });

  test('shared cases break exactly the rules the Edge Function finds', () {
    final cases = (_json('precheck_cases.json')['cases']! as List)
        .cast<Map<String, Object?>>();
    expect(cases, isNotEmpty);
    for (final c in cases) {
      final got = precheck(
        (c['body']! as Map).cast<String, Object?>(),
      ).map((i) => '$i').toList()..sort();
      final want = (c['expect']! as List).cast<String>().toList()..sort();
      expect(got, want, reason: c['name'] as String);
    }
  });

  test('text hints lead with personal data, then placeholders', () {
    expect(precheckTextHint('0912345678 測試'), contains('電話'));
    expect(precheckTextHint('測試', name: true), contains('停車點'));
    expect(precheckTextHint('測試', solo: true), contains('現場狀況'));
    expect(precheckTextHint('測試'), isNull);
    expect(precheckTextHint('信義路五段收費機車格', name: true), isNull);
    expect(precheckTextHint('   '), isNull);
    expect(precheckTextHint(null), isNull);
  });

  test('refusals read the server message and ignore other errors', () {
    expect(precheckRefusal({'error': 'precheck fix', 'message': '請改'}), '請改');
    expect(precheckRefusal({'error': 'invalid name'}), isNull);
    expect(precheckRefusal('oops'), isNull);
    expect(precheckRefusal(null), isNull);
  });
}

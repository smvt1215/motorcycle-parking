import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/fee_plan.dart';

/// Fee plans (§2.6) against the shared cases every side runs.
void main() {
  final contract = jsonDecode(
    File('supabase/functions/_shared/parking_contract.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = jsonDecode(
    File('supabase/functions/_shared/parking_contract_cases.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;

  test('the plan rules mirror the contract', () {
    final plans = {...(contract['fee_plans']! as Map<String, Object?>)}
      ..remove('comment');
    expect(plans, feePlansContract);
  });

  test('validFeePlans accepts exactly the valid shared cases', () {
    final all = (cases['fee_plans']! as List).cast<Map<String, Object?>>();
    expect(all, isNotEmpty);
    for (final c in all) {
      expect(
        validFeePlans(c['plans'], c['fee_plan'], c['fee'], c['zones']),
        c['valid'],
        reason: c['name'] as String,
      );
    }
  });

  test('segments refer to plans as zones do (#188 layer 2)', () {
    final all = (cases['segment_fee_plans']! as List)
        .cast<Map<String, Object?>>();
    expect(all, isNotEmpty);
    for (final c in all) {
      expect(
        validFeePlans(c['plans'], null, null, const [], c['segments']),
        c['valid'],
        reason: c['name'] as String,
      );
    }
  });

  test('a plan projected onto a zone, as the shared cases expect', () {
    final all = (cases['fee_projections']! as List)
        .cast<Map<String, Object?>>();
    expect(all, isNotEmpty);
    for (final c in all) {
      expect(
        canonicalJson(projectZoneFee(c['fee']! as Map, c['zone']! as Map)),
        canonicalJson(c['projected']),
        reason: c['name'] as String,
      );
    }
  });

  test('a plan reads and writes its JSON', () {
    final json = {
      'id': 'p1',
      'name': '機車計時',
      'fee': {
        'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      },
    };
    final plan = FeePlan.fromJson(json)!;
    expect(
      plan.fee.scooter,
      const Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
    );
    expect(plan.toJson(), json);
    expect(FeePlan.fromJson({...json, 'id': 'P1'}), isNull);
    expect(FeePlan.fromJson({...json, 'fee': <String, Object>{}}), isNull);
  });
}

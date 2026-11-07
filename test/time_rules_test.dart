import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/report/entry_drafts.dart';
import 'package:motorcycle_parking/features/report/time_rules.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';

const _allow = ZoneAllow(scooter: true, heavy: true);

ParkingZone _zone(String id, List<ParkingLimit> limits) => ParkingZone(
  id: id,
  name: id.toUpperCase(),
  condition: ParkingCondition(
    bay: Bay.motorcycle,
    use: BayUse.usual,
    limits: limits,
    allow: _allow,
  ),
);

const _weekday = LimitPeriod(
  days: 'weekday',
  from: '07:00',
  to: '20:00',
  maxMinutes: 120,
  extensions: 1,
);
const _limit = ParkingLimit(LimitKind.timeLimit, periods: [_weekday]);
const _night = ParkingLimit(
  LimitKind.noParking,
  periods: [LimitPeriod(days: 'all', from: '23:00', to: '07:00')],
);

void main() {
  late List<EntryDraft> drafts;

  setUp(() {
    drafts = [
      EntryDraft.ofZone(_zone('b1', [_limit, _night])),
      EntryDraft.ofZone(_zone('b2', [_limit])),
    ];
  });

  test('各區相同的時段讀成一條規定，全部都有時管全場', () {
    final rules = rulesOf(drafts);
    expect(rules, hasLength(2));
    final limit = rules.firstWhere((r) => r.kind == RuleKind.limit);
    expect(limit.all, isTrue);
    expect(limit.minutes, 120);
    expect(
      ruleSummary(limit, drafts, '全場'),
      '全場　平日 07:00–20:00 每次限停 2 小時・可延長 1 次',
    );
    final night = rules.firstWhere((r) => r.kind == RuleKind.noParking);
    expect(night.all, isFalse);
    expect(ruleSummary(night, drafts, '全場'), 'B1　每天 23:00–07:00');
  });

  test('沒動的規定不產生 patch，也沒有差異', () {
    final rules = rulesOf(drafts);
    expect(ruleChanges(rules, drafts, '全場'), isEmpty);
    applyRules(rules, drafts);
    expect(entriesPatchOf(drafts), isEmpty);
  });

  test('改時長：複製到每個分區，差異只列改到的部分', () {
    final rules = rulesOf(drafts);
    rules.firstWhere((r) => r.kind == RuleKind.limit).minutes = 180;
    final lines = ruleChanges(rules, drafts, '全場');
    expect(lines, hasLength(1));
    expect(lines.single.label, '限時');
    expect(lines.single.from, '每次限停 2 小時・可延長 1 次');
    expect(lines.single.to, '每次限停 3 小時・可延長 1 次');
    applyRules(rules, drafts);
    final patch = entriesPatchOf(drafts);
    expect(patch.map((e) => e['id']), ['b1', 'b2']);
    final b1 = patch.first['condition']! as Map<String, Object?>;
    expect((b1['limits']! as List).first, {
      'kind': 'time_limit',
      'periods': [
        {
          'days': 'weekday',
          'from': '07:00',
          'to': '20:00',
          'max_minutes': 180,
          'extensions': 1,
        },
      ],
    });
    // The other kind stays in the zone that has it, and only there.
    expect((b1['limits']! as List).last, _night.toJson());
    final b2 = patch.last['condition']! as Map<String, Object?>;
    expect(b2['limits'], hasLength(1));
    expect(ParkingCondition.fromJson(b1, zone: true), isNotNull);
  });

  test('縮小範圍只改被拿掉的分區', () {
    final rules = rulesOf(drafts);
    final limit = rules.firstWhere((r) => r.kind == RuleKind.limit);
    limit
      ..all = false
      ..scope = {drafts.first.token};
    applyRules(rules, drafts);
    final patch = entriesPatchOf(drafts);
    expect(patch.single['id'], 'b2');
    final c = patch.single['condition']! as Map<String, Object?>;
    expect(c.containsKey('limits'), isFalse);
  });

  test('同一分區同種規定合併成一個 limit 的多段', () {
    final rules = rulesOf(drafts);
    rules.add(
      TimeRule.create()
        ..kind = RuleKind.noParking
        ..all = false
        ..scope = {drafts.first.token}
        ..days = const ['mon']
        ..allDay = true,
    );
    applyRules(rules, drafts);
    final b1 = entriesPatchOf(drafts).single;
    final c = b1['condition']! as Map<String, Object?>;
    final night = (c['limits']! as List).last as Map;
    expect(night['kind'], 'no_parking');
    expect(night['periods'], [
      {'days': 'all', 'from': '23:00', 'to': '07:00'},
      {
        'days': ['mon'],
      },
    ]);
  });

  test('移除與共用時段', () {
    final rules = rulesOf(drafts);
    rules.firstWhere((r) => r.kind == RuleKind.noParking).removed = true;
    rules.add(
      TimeRule.create()
        ..kind = RuleKind.share
        ..days = 'all'
        ..from = '20:00'
        ..to = '23:00'
        ..vehicles = {SlotVehicle.scooter, SlotVehicle.heavy},
    );
    final lines = ruleChanges(rules, drafts, '全場');
    expect(lines.map((l) => l.label), ['禁停', '共用']);
    expect(lines.first.to, '沒有');
    expect(lines.last.to, '全場　每天 20:00–23:00 開放機車');
    applyRules(rules, drafts);
    final c =
        entriesPatchOf(drafts).first['condition']! as Map<String, Object?>;
    expect(c['schedule'], [
      {
        'days': 'all',
        'from': '20:00',
        'to': '23:00',
        'vehicles': ['scooter', 'heavy'],
      },
    ]);
  });

  test('移除再新增一模一樣的規定：沒有差異，也沒有 patch', () {
    final rules = rulesOf(drafts);
    final limit = rules.firstWhere((r) => r.kind == RuleKind.limit);
    limit.removed = true;
    rules.add(
      TimeRule.create()
        ..days = 'weekday'
        ..from = '07:00'
        ..to = '20:00'
        ..minutes = 120
        ..extensions = 1,
    );
    expect(ruleChanges(rules, drafts, '全場'), isEmpty);
    applyRules(rules, drafts);
    expect(entriesPatchOf(drafts), isEmpty);
  });

  test('只有一區時點選該區等於全場，沒有差異', () {
    final one = [
      EntryDraft.ofZone(_zone('b1', [_limit])),
    ];
    final rules = rulesOf(one);
    rules.single
      ..all = false
      ..scope = {one.single.token};
    expect(ruleChanges(rules, one, '全場'), isEmpty);
    expect(rules.single.all, isTrue);
  });

  test('路段改規定時，沒有收費資訊的格位依費率補 charge', () {
    final segment = EntryDraft.ofSegment(
      const ParkingSegment(
        id: 's1',
        name: '北側',
        condition: ParkingCondition(
          bay: Bay.motorcycle,
          use: BayUse.usual,
          allow: _allow,
        ),
      ),
    );
    final rules = [
      TimeRule.create()
        ..kind = RuleKind.noParking
        ..allDay = true,
    ];
    applyRules(rules, [segment]);
    final patch = entriesPatchOf(
      [segment],
      spotFee: const Fee(
        scooter: Rate(FeeMode.free),
        heavy: Rate(FeeMode.free),
        car: Rate(FeeMode.notApplicable),
      ),
    );
    final c = patch.single['condition']! as Map<String, Object?>;
    expect(c['charge'], 'free');
  });

  test('欄位檢查', () {
    final rule = TimeRule.create();
    expect(ruleProblems(rule, '區'), {'time': '請選開始和結束時間，或按「全天」'});
    rule
      ..from = '08:00'
      ..to = '08:00'
      ..all = false
      ..kind = RuleKind.share;
    expect(ruleProblems(rule, '段'), {
      'scope': '請選這條規定管哪幾段',
      'time': '結束和開始不能相同',
      'vehicles': '請選這段時間可停的車種，或刪除這個時段',
    });
  });

  test('同種規定超過 8 條時擋下', () {
    final rules = [
      for (var i = 0; i < 9; i++)
        TimeRule.create()
          ..kind = RuleKind.noParking
          ..days = const ['mon']
          ..from = '0$i:00'
          ..to = '0$i:30',
    ];
    expect(rulesOverflow(rules, drafts), contains('最多 8 條'));
  });

  test('舊資料的全天限時讀得出來，延長未說時寫入 0', () {
    final old = EntryDraft.ofZone(
      _zone('b3', const [ParkingLimit(LimitKind.timeLimit, maxMinutes: 45)]),
    );
    final rules = rulesOf([old]);
    expect(rules.single.allDay, isTrue);
    expect(rules.single.minutes, 45);
    applyRules(rules, [old]);
    expect(old.signs, isNull);
    rules.single.minutes = 60;
    applyRules(rules, [old]);
    expect(old.signs!.single.periods.single.extensions, 0);
  });

  test('點位 condition：沒有改到規定時保留既有限時與禁停', () {
    const spot = ParkingSpot(
      id: 'official:bare',
      name: '巷口',
      lat: 25,
      lng: 121,
      city: '臺北市',
      spaceType: SpaceType.timedMotorcycle,
      source: 'official',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        limits: [_limit, _night],
      ),
    );
    final d = EntryDraft.ofSpot(spot);
    final p = spotRulesProposal(spot, d, free: false);
    final c = p['condition']! as Map<String, Object?>;
    expect((c['limits']! as List).map((l) => (l as Map)['kind']), [
      'time_limit',
      'no_parking',
    ]);
    expect(p['space_type'], 'timedMotorcycle');
  });

  test('沒有路段的路邊點送點位 condition 與對應的 space_type', () {
    const spot = ParkingSpot(
      id: 'official:bare',
      name: '巷口',
      lat: 25,
      lng: 121,
      city: '臺北市',
      spaceType: SpaceType.timedMotorcycle,
      source: 'official',
      condition: ParkingCondition(
        bay: Bay.motorcycle,
        use: BayUse.usual,
        limits: [_limit],
      ),
    );
    final d = EntryDraft.ofSpot(spot);
    final rules = rulesOf([d]);
    expect(rules.single.all, isTrue);
    rules.single.removed = true;
    rules.add(
      TimeRule.create()
        ..kind = RuleKind.noParking
        ..days = 'weekday'
        ..allDay = true,
    );
    applyRules(rules, [d]);
    final p = spotRulesProposal(spot, d, free: false);
    expect(p['space_type'], 'paidMotorcycle');
    final c = p['condition']! as Map<String, Object?>;
    expect(c['charge'], 'toll');
    expect(c.containsKey('allow'), isFalse);
    expect(ParkingCondition.fromJson(c), isNotNull);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/admin/review/review_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';

import 'fake_admin_gateway.dart';

/// Zone and segment suggestions on the review page (#188): shown as the
/// list the rider's patches leave, sent back as the patches that make it.
void main() {
  const zones = [
    {'id': 'b1', 'name': 'B1', 'access': 'scooterOnly', 'guide': '靠電梯'},
    {'id': 'b2', 'name': 'B2', 'access': 'heavyOnly'},
  ];
  final spot = ReviewSpot(
    sourceId: '10000000-0000-4000-8000-000000000002',
    official: false,
    values: {'name': '松壽地下停車場', 'parking_zones': zones},
  );
  ReviewReport report(Map<String, dynamic> proposed) => ReviewReport.fromJson({
    'id': 'r1',
    'source_id': spot.sourceId,
    'reason': '分區：修改',
    'field': 'zones',
    'proposed': proposed,
    'created_at': '2026-10-31T00:00:00Z',
  });

  test('entriesPatch changes, removes and adds by id', () {
    expect(
      entriesPatch(zones, [
        {'id': 'b1', 'guide': null, 'area': 'motorcycle'},
        {'id': 'b2', 'removed': true},
        {'name': 'B3', 'access': 'scooterHeavy', 'guide': null},
      ]),
      [
        {
          'id': 'b1',
          'name': 'B1',
          'access': 'scooterOnly',
          'area': 'motorcycle',
        },
        {'name': 'B3', 'access': 'scooterHeavy'},
      ],
    );
    expect(
      entriesPatch(zones, [
        {'id': 'b9', 'guide': 'x'},
      ]),
      isNull,
    );
    expect(
      entriesPatch(zones, [
        {'id': 'b1', 'removed': true, 'name': 'B1'},
      ]),
      isNull,
    );
    expect(entriesPatch(zones, {'id': 'b1'}), isNull);
  });

  test('entriesDiff is the patch back, leaving unchanged entries out', () {
    final next = entriesPatch(zones, [
      {'id': 'b1', 'guide': '走右側坡道'},
      {'id': 'b2', 'removed': true},
      {'name': 'B3'},
    ])!;
    final diff = entriesDiff(zones, next);
    expect(diff, [
      {'id': 'b1', 'guide': '走右側坡道'},
      {'name': 'B3'},
      {'id': 'b2', 'removed': true},
    ]);
    expect(entriesPatch(zones, diff), [
      {'id': 'b1', 'name': 'B1', 'access': 'scooterOnly', 'guide': '走右側坡道'},
      {'name': 'B3'},
    ]);
    expect(entriesDiff(zones, zones), isEmpty);
    // A key taken out is sent as null.
    expect(
      entriesDiff(zones, [
        {'id': 'b1', 'name': 'B1', 'access': 'scooterOnly'},
        zones[1],
      ]),
      [
        {'id': 'b1', 'guide': null},
      ],
    );
  });

  test('the review adopts the list the patches leave and sends patches', () {
    final proposal = initialProposal(
      report({
        'parking_zones': [
          {'id': 'b2', 'removed': true},
          {'name': 'B3', 'access': 'scooterHeavy'},
        ],
      }),
      spot,
    );
    expect(proposal['parking_zones'], [
      zones[0],
      {'name': 'B3', 'access': 'scooterHeavy'},
    ]);
    final patch = applicablePatch(proposal, spot);
    expect(patch.keys, ['parking_zones']);
    expect(validatePatch(patch, spot), isNull);
    expect(formatValue('parking_zones', patch['parking_zones']), '2 區：B1、B3');
    expect(formatValue('parking_zones', zones), '2 區：B1、B2');
    expect(wirePatch(patch, spot: spot), {
      'parking_zones': [
        {'name': 'B3', 'access': 'scooterHeavy'},
        {'id': 'b2', 'removed': true},
      ],
    });
  });

  test('a patch naming a zone the spot no longer has is set aside', () {
    final proposal = initialProposal(
      report({
        'parking_zones': [
          {'id': 'b9', 'guide': 'x'},
        ],
      }),
      spot,
    );
    expect(applicablePatch(proposal, spot), isEmpty);
    expect(ignoredKeys(proposal, spot), ['parking_zones']);
  });

  test('segments read the same way, with their own label', () {
    final street = ReviewSpot(
      sourceId: spot.sourceId,
      official: false,
      values: {
        'parking_segments': [
          {'id': 's1', 'name': '北側', 'total': 18},
        ],
      },
    );
    final proposal = initialProposal(
      report({
        'parking_segments': [
          {'id': 's1', 'total': 20},
        ],
      }),
      street,
    );
    expect(proposal['parking_segments'], [
      {'id': 's1', 'name': '北側', 'total': 20},
    ]);
    expect(reviewField('parking_segments')!.label, '路邊分段');
    expect(suggestionFieldLabels['segments'], '路邊分段');
    expect(wirePatch(applicablePatch(proposal, street), spot: street), {
      'parking_segments': [
        {'id': 's1', 'total': 20},
      ],
    });
  });

  test('a stale rename never reaches the patch, nor removes the others', () {
    final proposal = initialProposal(
      report({
        'parking_zones': [
          {'id': 'b9', 'name': '新名稱'},
        ],
      }),
      spot,
    );
    expect(proposal['parking_zones'], isA<StaleEntries>());
    expect(applicablePatch(proposal, spot), isEmpty);
    expect(ignoredKeys(proposal, spot), ['parking_zones']);
    expect('${proposal['parking_zones']}', '這區已不存在，無法套用');
    expect(wirePatch(applicablePatch(proposal, spot), spot: spot), isEmpty);
  });

  test('the review lists what each change does, not only the names', () {
    final next = entriesPatch(zones, [
      {'id': 'b1', 'guide': '走右側坡道', 'access': 'scooterHeavy'},
      {'id': 'b2', 'removed': true},
      {'name': 'B3'},
    ])!;
    expect(entriesChangeLines(zones, next), [
      '「B1」：車種開放 普機專用→普大共用；指引 靠電梯→走右側坡道',
      '新增「B3」',
      '撤除「B2」',
    ]);
    expect(
      entriesChangeLines(
        [
          {'id': 's1', 'name': '北側', 'total': 18},
        ],
        [
          {'id': 's1', 'name': '北側', 'total': 20, 'side': 'north'},
        ],
      ),
      ['「北側」：格數 18 格→20 格；哪一側 未填→北側'],
    );
  });

  test(
    'as in SQL: a fee sent drops its plan; an access brings its condition',
    () {
      expect(
        entriesPatch(
          [
            {
              'id': 'a',
              'name': 'A',
              'fee_plan': 'p1',
              'fee': <String, Object?>{},
            },
            {
              'id': 'b',
              'name': 'B',
              'access': 'scooterOnly',
              'condition': {
                'bay': 'motorcycle',
                'use': 'usual',
                'limits': [
                  {'kind': 'time_limit'},
                ],
                'allow': {'scooter': true, 'heavy': false},
              },
            },
          ],
          [
            {'id': 'a', 'fee': null},
            {'id': 'b', 'access': 'heavyOnly'},
          ],
        ),
        [
          {'id': 'a', 'name': 'A'},
          {
            'id': 'b',
            'name': 'B',
            'access': 'heavyOnly',
            'condition': {
              'bay': 'heavy',
              'limits': [
                {'kind': 'time_limit'},
              ],
              'allow': {'scooter': false, 'heavy': true},
            },
          },
        ],
      );
    },
  );

  test(
    'a conflict retry sends the first patch again, keeping others\' changes',
    () async {
      final gateway = FakeAdminGateway(access: adminAal2);
      addTearDown(gateway.dispose);
      final r = report({
        'parking_zones': [
          {'id': 'b1', 'guide': '走右側坡道'},
        ],
      });
      gateway
        ..reports = [r]
        ..spots = {spot.sourceId: spot}
        ..changedSpots.add(r.id);
      final review = ReviewController(gateway);
      await review.load();
      review.startEdit(r);
      await review.decide(r, ReviewDecision.acceptEdited, '');
      // Meanwhile another admin renames B1 and adds B3.
      gateway.spots = {
        spot.sourceId: ReviewSpot(
          sourceId: spot.sourceId,
          official: false,
          values: {
            ...spot.values,
            'parking_zones': [
              {...zones[0], 'name': 'B1 機車區'},
              zones[1],
              {'id': 'b3', 'name': 'B3'},
            ],
          },
        ),
      };
      await review.flush();
      expect(review.conflicts, contains(r.id));
      // The page shows the rider's change on the newer list.
      expect(
        (review.draft['parking_zones'] as List).map((z) => (z as Map)['name']),
        ['B1 機車區', 'B2', 'B3'],
      );
      await review.decide(r, ReviewDecision.acceptEdited, '', force: true);
      await review.flush();
      expect(gateway.resolved.single.$3, {
        'parking_zones': [
          {'id': 'b1', 'guide': '走右側坡道'},
        ],
      });
    },
  );
}

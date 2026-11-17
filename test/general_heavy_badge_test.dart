import 'dart:convert';
import 'dart:io';

import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/domain/spot_detail_display.dart';
import 'package:motorcycle_parking/features/map/availability_capsule.dart';
import 'package:motorcycle_parking/features/map/google_parking_map.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/map/map_legend_page.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/four_sign_plates.dart';

import 'availability_ui_test.dart' show pumpMap, useSize;
import 'availability_fixtures.dart' as fx;

/// #493 and #492 (design v3, 2026-11-17): plain 一般機車格 that state heavy
/// bikes may park lend the scooter count as 普大共用格 do, under their own
/// name 「一般機車格可停」 and badge (G1, heavy bikes only); the pills carry
/// the badge of the bays they count.
void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CityRule.fromJson)
          .toList();
  // 2026-11-03 (Tuesday) 14:20 in Taiwan.
  final day = DateTime.utc(2026, 11, 3, 6, 20);

  Map<String, dynamic> lotJson(
    List<Map<String, dynamic>> zones, {
    String? access,
    String id = 'demo',
  }) => {
    'id': id,
    'name': '示範地下停車場',
    'lat': 25.0339,
    'lng': 121.5623,
    'city': '臺北市',
    'district': '中山區',
    'space_type': 'offStreet',
    'facility_type': 'underground',
    'source': 'official',
    'status': 'confirmed',
    'scooter_allowed': true,
    'heavy_allowed': true,
    'parking_access': ?access,
    'parking_zones': zones,
  };
  ParkingSpot lot(
    List<Map<String, dynamic>> zones, {
    String? access,
    String id = 'demo',
  }) => ParkingSpot.fromJson(lotJson(zones, access: access, id: id));

  const sharedZone = {
    'id': 'b1',
    'name': 'B1 機車區',
    'condition': {
      'bay': 'motorcycle',
      'use': 'share',
      'share': 'scooter_heavy',
      'allow': {'scooter': true, 'heavy': true},
    },
  };
  // 一般機車格准重機: a plain motorcycle bay, heavy bikes stated, no share.
  const generalZone = {
    'id': 'b2',
    'name': 'B2 機車區',
    'condition': {
      'bay': 'motorcycle',
      'use': 'usual',
      'allow': {'scooter': true, 'heavy': true},
    },
  };
  const scooterZone = {
    'id': 'b3',
    'name': 'B3 機車區',
    'condition': {
      'bay': 'motorcycle',
      'use': 'usual',
      'allow': {'scooter': true, 'heavy': false},
    },
  };
  const heavyZone = {
    'id': 'b4',
    'name': 'B4 重機專區',
    'condition': {
      'bay': 'heavy',
      'use': 'usual',
      'allow': {'heavy': true},
    },
  };
  final general = lot([generalZone]);
  final mixed = lot([sharedZone, generalZone]);
  final allShared = lot([sharedZone]);
  final withScooterOnly = lot([generalZone, scooterZone]);
  final legacy = lot(const [], access: 'scooterHeavy');

  AvailabilitySnapshot count(
    AvailabilityVehicle vehicle,
    int available, {
    Duration age = const Duration(minutes: 2),
    String spot = 'demo',
  }) => AvailabilitySnapshot(
    spotId: spot,
    vehicle: vehicle,
    provider: '臺北市停管處',
    window: AvailabilityWindow.taipei,
    total: 40,
    available: available,
    sourceUpdatedAt: day.subtract(age),
  );
  final scooter9 = count(AvailabilityVehicle.scooter, 9);
  final heavyNone = count(AvailabilityVehicle.heavy, -9);

  ParkingDecision judged(ParkingSpot spot, VehicleType vehicle) =>
      decideParking(spot, vehicle, rules, now: day);
  List<AvailabilityCapsule> capsules(
    ParkingSpot spot,
    VehicleType vehicle,
    List<AvailabilitySnapshot> list,
  ) => markerCapsules(
    spot,
    SpotAvailability(list),
    vehicle,
    judged(spot, vehicle),
    day,
  );
  FourSign sign(
    ParkingSpot spot,
    VehicleType vehicle,
    List<AvailabilitySnapshot> list,
  ) => fourSign(
    spot,
    vehicle,
    rules,
    now: day,
    availability: SpotAvailability(list),
  );
  SignPlate seat(
    ParkingSpot spot,
    VehicleType vehicle,
    List<AvailabilitySnapshot> list,
  ) => fourSignPlates(
    sign(spot, vehicle, list),
    day,
  ).firstWhere((p) => p.face == FourSignFace.seat);

  group('借用條件（#493）', () {
    test('全場一般格准重機、或混有普大共用格：借用，標一般機車格可停（M1）', () {
      expect(borrowedBays(general), BorrowedBays.general);
      expect(borrowedBays(mixed), BorrowedBays.general);
      expect(borrowedBays(lot([generalZone, heavyZone])), BorrowedBays.general);
      expect(borrowedBays(allShared), BorrowedBays.shared);
      expect(motorcycleBaysAllShared(mixed), isFalse);
      expect(motorcycleBaysAllShared(allShared), isTrue);
    });

    test('混有不准重機的一般機車格、舊 access、未標示、身障或充電格：不借用', () {
      expect(borrowedBays(withScooterOnly), isNull);
      expect(borrowedBays(lot([sharedZone, generalZone, scooterZone])), isNull);
      expect(borrowedBays(legacy), isNull);
      // A legacy zone access alone states nothing.
      expect(
        borrowedBays(
          lot([
            generalZone,
            {'id': 'z9', 'name': '機車區', 'access': 'scooterHeavy'},
          ]),
        ),
        isNull,
      );
      Map<String, dynamic> zone(Map<String, dynamic> condition) => {
        'id': 'z1',
        'name': '機車區',
        'condition': condition,
      };
      for (final condition in <Map<String, dynamic>>[
        // 官方未標示 is not yes.
        {
          'bay': 'motorcycle',
          'allow': {'scooter': true, 'heavy': 'not_stated'},
        },
        {
          'bay': 'motorcycle',
          'allow': {'scooter': true},
        },
        {'bay': 'motorcycle'},
        // Scooters excluded: the scooter count is not these bays'.
        {
          'bay': 'motorcycle',
          'allow': {'scooter': false, 'heavy': true},
        },
        {
          'bay': 'motorcycle',
          'limits': [
            {'kind': 'ev_only'},
          ],
          'allow': {'scooter': true, 'heavy': true},
        },
      ]) {
        final spot = lot([zone(condition)]);
        expect(spot.zones.single.condition, isNotNull, reason: '$condition');
        expect(borrowedBays(spot), isNull, reason: '$condition');
      }
      // A lot without zones states no 一般格准重機 (#493: 邏輯不改).
      expect(
        borrowedBays(
          ParkingSpot.fromJson({
            ...lotJson(const []),
            'condition': {'bay': 'motorcycle', 'use': 'usual'},
          }),
        ),
        isNull,
      );
    });

    test('重機模式借用機車剩餘數：膠囊帶 G1、路牌與詳情寫一般機車格可停', () {
      final list = [scooter9, heavyNone];
      final pill = capsules(general, VehicleType.heavy, list).single;
      expect(
        (pill.text, pill.style, pill.badge),
        ('剩 9', CapsuleStyle.live, SpaceBadge.generalHeavy),
      );
      expect(pill.semantics, '一般機車格可停，大型重機也可以停，與普通機車共用：官方即時剩 9 格');
      final s = sign(general, VehicleType.heavy, list);
      expect(
        (s.seat.kind, s.seat.available, s.seat.borrowed),
        (SeatKind.live, 9, BorrowedBays.general),
      );
      final plate = seat(general, VehicleType.heavy, list);
      expect(plate.note.split('\n'), contains('一般機車格可停'));
      expect(plate.shortNote!.split('\n'), contains('一般格可停'));
      expect(plate.note, isNot(contains('普大共用')));
      expect(plate.note, isNot(contains('・')));
      expect(plate.semantics, contains('一般機車格可停，大型重機也可以停，與普通機車共用'));
      final row = seatRows(s, SpotAvailability(list), day).single;
      expect(row.official, '剩 9 格');
      expect(row.officialNote, endsWith('一般機車格可停'));
      final fact = availabilityFact(
        general,
        SpotAvailability(list),
        VehicleType.heavy,
        judged(general, VehicleType.heavy),
        day,
      );
      expect(fact.count, 9);
      expect(fact.caption, endsWith('一般機車格可停'));
      expect(
        availabilityExclusion(
          AvailabilityFilter.available,
          general,
          SpotAvailability(list),
          VehicleType.heavy,
          EligibilityStatus.allowed,
          day,
          decision: judged(general, VehicleType.heavy),
        ),
        isNull,
      );
    });

    test('延遲：延遲樣式加 G1，讀屏照稿', () {
      final pill = capsules(general, VehicleType.heavy, [
        count(AvailabilityVehicle.scooter, 9, age: const Duration(minutes: 12)),
        heavyNone,
      ]).single;
      expect(
        (pill.style, pill.badge),
        (CapsuleStyle.delayed, SpaceBadge.generalHeavy),
      );
      expect(pill.semantics, '一般機車格可停，大型重機也可以停，與普通機車共用：更新延遲 12 分鐘，最後一筆剩 9 格');
    });

    test('普通機車模式：純數字，不念一般機車格可停', () {
      final pill = capsules(general, VehicleType.scooter, [scooter9]).single;
      expect((pill.text, pill.badge), ('剩 9', null));
      expect(pill.semantics, '官方即時：剩 9 格');
      final plate = seat(general, VehicleType.scooter, [scooter9]);
      expect(plate.note, isNot(contains('一般')));
      expect(plate.shortNote, isNull);
    });

    test('混合場站（M1）：每一區都寫一般機車格可停，不寫普大共用', () {
      final list = [scooter9, heavyNone];
      final pill = capsules(mixed, VehicleType.heavy, list).single;
      expect(pill.badge, SpaceBadge.generalHeavy);
      final s = sign(mixed, VehicleType.heavy, list);
      expect(s.seat.borrowed, BorrowedBays.general);
      final rows = seatRows(s, SpotAvailability(list), day);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect(row.officialNote, contains('一般機車格可停'));
        expect(row.officialNote, isNot(contains('普大共用')));
      }
    });

    test('混有不准重機的一般機車格：空位未知，准重機那一區附普通機車次要行', () {
      final list = [scooter9, heavyNone];
      expect(capsules(withScooterOnly, VehicleType.heavy, list), isEmpty);
      final s = sign(withScooterOnly, VehicleType.heavy, list);
      expect(s.seat.kind, isNot(SeatKind.live));
      expect(s.seat.borrowed, isNull);
      final row = seatRows(
        s,
        SpotAvailability(list),
        day,
      ).firstWhere((r) => r.area.id == 'b2');
      expect(row.official, '空位未知');
      expect(row.officialNote, contains('普通機車區剩 9 格'));
      expect(row.officialNote, contains(notForHeavyNote));
      expect(
        availabilityExclusion(
          AvailabilityFilter.available,
          withScooterOnly,
          SpotAvailability(list),
          VehicleType.heavy,
          EligibilityStatus.allowed,
          day,
          decision: judged(withScooterOnly, VehicleType.heavy),
        ),
        AvailabilityExclusion.noData,
      );
    });

    test('重機專區自己的數字仍優先，借用的只算另一區有位', () {
      final spot = lot([generalZone, heavyZone]);
      final s = sign(spot, VehicleType.heavy, [
        scooter9,
        count(AvailabilityVehicle.heavy, 3),
      ]).seat;
      expect((s.available, s.borrowed, s.more), (3, null, 1));
    });
  });

  group('角落小章依模式（#492）', () {
    SpaceBadge? heavy(ParkingSpot s) => spaceBadge(s, VehicleType.heavy);
    SpaceBadge? scooter(ParkingSpot s) => spaceBadge(s, VehicleType.scooter);

    test('一般機車格可停只在重機模式掛', () {
      expect(heavy(general), SpaceBadge.generalHeavy);
      expect(scooter(general), isNull);
    });

    test('混合場站（M1）：重機模式掛 G1，普通機車模式不掛', () {
      expect(heavy(mixed), SpaceBadge.generalHeavy);
      expect(scooter(mixed), isNull);
    });

    test('混合場站帶場站層級舊 access：忽略舊標記，普通機車模式也不掛白黃方章', () {
      final spot = lot([sharedZone, generalZone], access: 'scooterHeavy');
      expect(heavy(spot), SpaceBadge.generalHeavy);
      expect(scooter(spot), isNull);
      final onlyGeneral = lot([generalZone], access: 'scooterHeavy');
      expect(heavy(onlyGeneral), SpaceBadge.generalHeavy);
      expect(scooter(onlyGeneral), isNull);
    });

    test('只有舊 access 的場站（K1）：兩種模式都照掛白黃方章', () {
      expect(heavy(legacy), SpaceBadge.shared);
      expect(scooter(legacy), SpaceBadge.shared);
      // Zones that do not lend the count leave the lot's access as it was.
      final spot = lot([generalZone, scooterZone], access: 'scooterHeavy');
      expect(heavy(spot), SpaceBadge.shared);
      expect(scooter(spot), SpaceBadge.shared);
    });

    test('補掛：分區都明確普大共用、沒有場站 access，兩種模式都掛白黃方章', () {
      expect(heavy(allShared), SpaceBadge.shared);
      expect(scooter(allShared), SpaceBadge.shared);
      expect(heavy(lot([sharedZone, heavyZone])), SpaceBadge.shared);
      // A legacy zone access is not an explicit condition: no badge.
      final legacyZone = lot([
        {'id': 'z1', 'name': '機車區', 'access': 'scooterHeavy'},
      ]);
      expect(heavy(legacyZone), isNull);
      expect(scooter(legacyZone), isNull);
      // Shared beside scooter-only bays: not every motorcycle bay.
      expect(heavy(lot([sharedZone, scooterZone])), isNull);
    });

    test('場站層級的重機專用、大汽共用照舊', () {
      for (final vehicle in VehicleType.values) {
        expect(
          spaceBadge(lot([generalZone], access: 'heavyCar'), vehicle),
          SpaceBadge.car,
        );
        expect(
          spaceBadge(lot([sharedZone], access: 'heavyOnly'), vehicle),
          SpaceBadge.heavyOnly,
        );
      }
    });

    test('新章是 Material 的機車圖示，不是重機剪影；只列在六種格位之外', () {
      expect(spaceBadgeIcon(SpaceBadge.generalHeavy), Icons.moped);
      expect(SpaceBadge.bayKinds, hasLength(6));
      expect(SpaceBadge.bayKinds, isNot(contains(SpaceBadge.generalHeavy)));
      expect(SpaceBadge.generalHeavy.square, isFalse);
      expect(SpaceBadge.generalHeavy.label, '一般機車格可停');
    });
  });

  group('膠囊小章（方案 B＋B2）', () {
    AvailabilityCapsule pill(CapsuleStyle style, [SpaceBadge? badge]) =>
        AvailabilityCapsule(
          text: style == CapsuleStyle.full ? '已滿' : '剩 18',
          style: style,
          badge: badge,
          semantics: '測試',
        );

    testWidgets('小章 16、距內框 2、其後 4；時鐘在小章與數字之間；寬度與量測一致', (tester) async {
      for (final badge in [
        SpaceBadge.shared,
        SpaceBadge.car,
        SpaceBadge.generalHeavy,
      ]) {
        for (final style in [
          CapsuleStyle.live,
          CapsuleStyle.delayed,
          CapsuleStyle.full,
        ]) {
          final capsule = pill(style, badge);
          await tester.pumpWidget(
            MaterialApp(
              home: Center(child: AvailabilityCapsuleView(capsule: capsule)),
            ),
          );
          final box = tester.getRect(find.byType(AvailabilityCapsuleView));
          expect(box.height, 24);
          expect(
            box.width,
            closeTo(capsuleWidth(capsule), .01),
            reason: '$badge $style',
          );
          final dot = tester.getRect(
            find.byKey(ValueKey('space-badge-${badge.name}')),
          );
          expect(dot.size, const Size.square(16));
          // 2 keyline + 2 inside the inner pill.
          expect(dot.left - box.left, closeTo(4, .01));
          expect(dot.center.dy, closeTo(box.center.dy, .01));
          final text = tester.getRect(find.text(capsule.text));
          if (style == CapsuleStyle.delayed) {
            final clock = tester.getRect(find.byType(CapsuleClock));
            expect(clock.left - dot.right, closeTo(4, .01));
            expect(text.left - clock.right, closeTo(3, .01));
          } else {
            expect(find.byType(CapsuleClock), findsNothing);
            expect(text.left - dot.right, closeTo(4, .01));
          }
          expect(tester.takeException(), isNull);
        }
      }
    });

    testWidgets('重機專用格（自己的數字）維持純數字，尺寸不變', (tester) async {
      final capsule = pill(CapsuleStyle.live);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(child: AvailabilityCapsuleView(capsule: capsule)),
        ),
      );
      expect(find.byType(SpaceBadgeDot), findsNothing);
      final box = tester.getRect(find.byType(AvailabilityCapsuleView));
      final text = tester.getRect(find.text('剩 18'));
      expect(text.left - box.left, closeTo(12, .01));
      expect(box.right - text.right, closeTo(11, .01));
    });

    testWidgets('字級放大時膠囊與小章不放大', (tester) async {
      final capsule = pill(CapsuleStyle.delayed, SpaceBadge.generalHeavy);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Center(child: AvailabilityCapsuleView(capsule: capsule)),
        ),
      );
      final box = tester.getRect(find.byType(AvailabilityCapsuleView));
      expect(box.height, 24);
      expect(box.width, closeTo(capsuleWidth(capsule), .01));
    });

    testWidgets('Google 地圖的膠囊點陣圖畫同一枚小章，寬度與 widget 相同', (tester) async {
      final seen = <int>{};
      for (final badge in [
        null,
        SpaceBadge.shared,
        SpaceBadge.car,
        SpaceBadge.generalHeavy,
      ]) {
        for (final style in [
          CapsuleStyle.live,
          CapsuleStyle.delayed,
          CapsuleStyle.full,
        ]) {
          for (final selected in [false, true]) {
            final capsule = pill(style, badge);
            final key = CapsuleKey([capsule], selected: selected);
            final icon =
                (await tester.runAsync(() => capsuleIcon(key)))!
                    as gm.BytesMapBitmap;
            expect(
              icon.width,
              (capsuleWidth(capsule, scale: selected ? 26 / 24 : 1) +
                      capsuleShadowRoom * 2)
                  .ceilToDouble(),
              reason: '$badge $style $selected',
            );
            // The bitmap cache keys on the badge too.
            expect(seen.add(key.hashCode), isTrue);
          }
        }
      }
      // The corner badge on the marker bitmap, selected or not.
      for (final selected in [false, true]) {
        expect(
          await tester.runAsync(
            () => markerIcon(
              (EligibilityStatus.allowed, null),
              SpaceBadge.generalHeavy,
              selected,
            ),
          ),
          isNotNull,
        );
      }
    });

    test('底色只看新舊：來源不同，同一狀態同一樣式；小章進入相等比較', () {
      final own = capsules(lot([heavyZone]), VehicleType.heavy, [
        count(AvailabilityVehicle.heavy, 5),
      ]).single;
      final shared = capsules(allShared, VehicleType.heavy, [
        scooter9,
        heavyNone,
      ]).single;
      expect((own.style, own.badge), (CapsuleStyle.live, null));
      expect(
        (shared.style, shared.badge),
        (CapsuleStyle.live, SpaceBadge.shared),
      );
      expect(shared.semantics, '普大共用格，與普通機車共用：官方即時剩 9 格');
      expect(
        pill(CapsuleStyle.live, SpaceBadge.shared),
        isNot(pill(CapsuleStyle.live, SpaceBadge.generalHeavy)),
      );
      expect(
        capsuleWidth(pill(CapsuleStyle.live, SpaceBadge.shared)) -
            capsuleWidth(pill(CapsuleStyle.live)),
        closeTo(12, .01),
      );
    });
  });

  group('地圖：兩種模式各掛哪些章', () {
    // A 全場一般格准重機、B 混合場站、C 只有舊 access、D 全場明確普大共用。
    ParkingSpot at(
      String id,
      double dx,
      double dy,
      List<Map<String, dynamic>> zones, {
      String? access,
    }) {
      final base = fx.lotAt(id, dx, dy, heavy: true);
      return ParkingSpot.fromJson({
        ...lotJson(zones, access: access, id: id),
        'name': '測試停車場 $id',
        'lat': base.lat,
        'lng': base.lng,
      });
    }

    final spots = [
      at('A', -110, -140, [generalZone]),
      at('B', 90, -140, [sharedZone, generalZone]),
      at('C', -110, 80, const [], access: 'scooterHeavy'),
      at('D', 90, 80, [sharedZone]),
    ];
    final counts = [
      for (final id in ['A', 'B', 'C', 'D']) ...[
        fx.count(id, AvailabilityVehicle.scooter, available: 9),
        fx.count(id, AvailabilityVehicle.heavy, available: -9),
      ],
    ];
    Finder badge(SpaceBadge b, {required bool inPill}) => find.descendant(
      of: find.byType(inPill ? AvailabilityCapsuleView : SpotMarker),
      matching: find.byKey(ValueKey('space-badge-${b.name}')),
    );

    testWidgets('大型重機：A、B 角落與膠囊都是 G1，C 只有角落白黃方章，D 兩處白黃方章', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, spots, counts, vehicle: VehicleType.heavy);
      expect(badge(SpaceBadge.generalHeavy, inPill: false), findsNWidgets(2));
      expect(badge(SpaceBadge.generalHeavy, inPill: true), findsNWidgets(2));
      expect(badge(SpaceBadge.shared, inPill: false), findsNWidgets(2));
      // C lends no count: a corner badge and no pill.
      expect(badge(SpaceBadge.shared, inPill: true), findsOneWidget);
      expect(find.byType(AvailabilityCapsuleView), findsNWidgets(3));
      expect(
        find.bySemanticsLabel(RegExp('^測試停車場 A [^，]*，一般機車格可停')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^測試停車場 D [^，]*，普大共用格')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('普通機車：不掛 G1，數字是純數字；C、D 照掛白黃方章', (tester) async {
      useSize(tester, 390);
      await pumpMap(tester, spots, counts);
      expect(badge(SpaceBadge.generalHeavy, inPill: false), findsNothing);
      expect(badge(SpaceBadge.shared, inPill: false), findsNWidgets(2));
      expect(find.byType(AvailabilityCapsuleView), findsNWidgets(4));
      expect(
        find.descendant(
          of: find.byType(AvailabilityCapsuleView),
          matching: find.byType(SpaceBadgeDot),
        ),
        findsNothing,
      );
      expect(find.bySemanticsLabel(RegExp('一般機車格可停')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('路牌副標：放不下才退回短詞', () {
    final plates = fourSignPlates(
      sign(general, VehicleType.heavy, [scooter9, heavyNone]),
      day,
    );
    Future<void> pump(WidgetTester tester, double width, double scale) async {
      useSize(tester, width);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: FourSignPlates(plates: plates, onTap: (_) {}),
            ),
          ),
        ),
      );
    }

    Finder inSeat(String text) => find.descendant(
      of: find.byKey(const ValueKey('four-sign-seat')),
      matching: find.textContaining(text),
    );
    // The note never wraps inside the term: each of its lines fits.
    void expectWhole(WidgetTester tester, String term) {
      final note = tester.renderObject<RenderParagraph>(inSeat(term));
      final lines = note.text.toPlainText().split('\n').length;
      final painter = TextPainter(
        text: note.text,
        textDirection: TextDirection.ltr,
        textScaler: note.textScaler,
      )..layout(maxWidth: note.size.width);
      expect(painter.computeLineMetrics(), hasLength(lines));
      painter.dispose();
    }

    for (final (width, scale, short) in [
      // Two columns from 1.3 up. Here the row is 358 wide (16 either
      // side) and the test font's characters are exactly 1em: seven fit a
      // 160 plate at 2.0 by a hair. The app's sheet is narrower (350), so
      // a real 390 phone at 2.0 falls back (see the PR's screenshots).
      (390.0, 1.3, false),
      (390.0, 2.0, false),
      (820.0, 2.0, false),
      // Four plates in a row at 1.0, or two at 2.0 on a narrower phone:
      // only 「一般格可停」 fits.
      (390.0, 1.0, true),
      (374.0, 2.0, true),
      (320.0, 2.0, true),
    ]) {
      testWidgets('寬 $width 字級 $scale：${short ? '退回一般格可停' : '一般機車格可停'}', (
        tester,
      ) async {
        await pump(tester, width, scale);
        expect(tester.takeException(), isNull);
        expect(inSeat('一般機車格可停'), short ? findsNothing : findsOneWidget);
        expect(inSeat('一般格可停'), short ? findsOneWidget : findsNothing);
        expectWhole(tester, short ? '一般格可停' : '一般機車格可停');
        // The screen reader always hears the full words.
        expect(
          find.bySemanticsLabel(RegExp('一般機車格可停，大型重機也可以停，與普通機車共用')),
          findsOneWidget,
        );
      });
    }
  });

  group('圖例說明頁依模式切換', () {
    Future<void> pump(
      WidgetTester tester,
      VehicleType vehicle, {
      double width = 390,
      double scale = 1,
      bool dark = false,
    }) async {
      useSize(tester, width, 3200);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: MapLegendContent(vehicle: vehicle, availability: true),
            ),
          ),
        ),
      );
    }

    final ink = find.byKey(const ValueKey('space-badge-generalHeavy'));

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets('大型重機：數字多三列帶小章，小圖示多一列新章與深色圓形說明', (tester) async {
        await pump(tester, VehicleType.heavy);
        expect(find.text('標記上方的數字'), findsOneWidget);
        expect(find.text('標記右下角的小圖示'), findsOneWidget);
        for (final title in [
          '重機格位的剩餘',
          '普大共用格的剩餘',
          '汽車格的剩餘',
          '有時鐘：資料晚到',
          '沒有數字：不知道有沒有位',
        ]) {
          expect(find.text(title), findsOneWidget, reason: title);
        }
        // A pill row and the badge's own row.
        expect(find.text('一般機車格可停'), findsNWidgets(2));
        expect(ink, findsNWidgets(2));
        expect(find.byKey(const ValueKey('legend-general-heavy')), findsOne);
        expect(find.textContaining('深色圓形只在大型重機模式出現'), findsOneWidget);
        expect(find.textContaining('沒有小圖示，就是重機自己的格位'), findsOneWidget);
        // The clock row shows a badge and the clock together.
        expect(find.byType(CapsuleClock), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('普通機車：不列新章，六枚格位章，底部一行提示', (tester) async {
        await pump(tester, VehicleType.scooter);
        expect(find.text('普通機車格的剩餘'), findsOneWidget);
        expect(find.text('一般機車格可停'), findsNothing);
        expect(ink, findsNothing);
        expect(find.textContaining('深色圓形'), findsNothing);
        expect(find.text('普大共用格的剩餘'), findsNothing);
        expect(find.text('切到大型重機時，數字前可能多一枚小圖示，說明數字算的是哪種格位。'), findsOneWidget);
        expect(find.textContaining('一般機車格不掛小圖示'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('legend-badges')),
            matching: find.byType(SpaceBadgeDot),
          ),
          findsNWidgets(6),
        );
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));

      for (final (width, scale, dark) in [
        (320.0, 2.0, false),
        (390.0, 1.3, true),
        (390.0, 2.0, true),
        (820.0, 2.0, false),
        (1180.0, 1.0, false),
      ]) {
        testWidgets('寬 $width 字級 $scale${dark ? ' 深色' : ''}：不溢出', (
          tester,
        ) async {
          for (final vehicle in VehicleType.values) {
            await pump(tester, vehicle, width: width, scale: scale, dark: dark);
            expect(tester.takeException(), isNull, reason: '$vehicle');
          }
          // At twice the size the pill sits above its words.
          final pillBox = tester.getRect(
            find.byType(AvailabilityCapsuleView).first,
          );
          final title = tester.getRect(find.textContaining('格位的剩餘'));
          if (scale >= 2) {
            expect(pillBox.bottom, lessThanOrEqualTo(title.top));
          } else {
            expect(pillBox.right, lessThanOrEqualTo(title.left));
          }
        }, variant: TargetPlatformVariant.only(platform));
      }

      testWidgets('平板：數字與小圖示兩節並排', (tester) async {
        await pump(tester, VehicleType.heavy, width: 1180);
        final numbers = tester.getRect(find.text('標記上方的數字'));
        final badges = tester.getRect(find.text('標記右下角的小圖示'));
        expect(badges.left, greaterThan(numbers.right));
        expect(badges.top, closeTo(numbers.top, 1));
        await pump(tester, VehicleType.heavy);
        expect(
          tester.getRect(find.text('標記右下角的小圖示')).top,
          greaterThan(tester.getRect(find.text('標記上方的數字')).bottom),
        );
      }, variant: TargetPlatformVariant.only(platform));
    }
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/four_sign.dart';
import 'package:motorcycle_parking/domain/four_sign_display.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/domain/spot_detail_display.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';

/// #489 (A', 2026-11-15): heavy bikes on 普大共用格 read the lot's scooter
/// count where every motorcycle bay of the lot is shared, marked
/// 「與普通機車共用」; a lot that also has scooter-only bays keeps 空位未知
/// with the scooter count as a secondary line.
void main() {
  final rules =
      (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
              as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(CityRule.fromJson)
          .toList();
  // 2026-11-03 (Tuesday) 14:20 in Taiwan.
  final day = DateTime.utc(2026, 11, 3, 6, 20);

  Map<String, dynamic> lotJson(List<Map<String, dynamic>> zones) => {
    'id': 'binjiang',
    'name': '濱江國中地下停車場',
    'lat': 25.07,
    'lng': 121.54,
    'city': '臺北市',
    'district': '中山區',
    'space_type': 'offStreet',
    'facility_type': 'underground',
    'source': 'official',
    'scooter_allowed': true,
    'heavy_allowed': true,
    'parking_zones': zones,
  };
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
  const scooterZone = {
    'id': 'b2',
    'name': 'B2 機車區',
    'condition': {
      'bay': 'motorcycle',
      'use': 'usual',
      'allow': {'scooter': true, 'heavy': false},
    },
  };
  const heavyZone = {
    'id': 'b3',
    'name': 'B3 重機專區',
    'condition': {
      'bay': 'heavy',
      'use': 'usual',
      'allow': {'heavy': true},
    },
  };
  // 濱江國中: one zone, stored with the legacy access only.
  final binjiang = ParkingSpot.fromJson(
    lotJson([
      {'id': 'z1', 'name': '地下一樓', 'access': 'scooterHeavy'},
    ]),
  );
  final mixed = ParkingSpot.fromJson(lotJson([sharedZone, scooterZone]));
  final withHeavy = ParkingSpot.fromJson(lotJson([sharedZone, heavyZone]));
  final noZones = ParkingSpot.fromJson({
    ...lotJson(const []),
    'parking_access': 'scooterHeavy',
  });

  AvailabilitySnapshot count(
    AvailabilityVehicle vehicle,
    int available, {
    Duration age = const Duration(minutes: 2),
    int total = 40,
  }) => AvailabilitySnapshot(
    spotId: 'binjiang',
    vehicle: vehicle,
    provider: '臺北市停管處',
    window: AvailabilityWindow.taipei,
    total: total,
    available: available,
    sourceUpdatedAt: day.subtract(age),
  );
  final scooter12 = count(AvailabilityVehicle.scooter, 12);
  final heavyNone = count(AvailabilityVehicle.heavy, -9);

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

  group('全場共用的判斷', () {
    test('單一分區 access=scooterHeavy（濱江國中）算全場共用', () {
      expect(motorcycleBaysAllShared(binjiang), isTrue);
    });

    test('普大共用＋重機專區算全場共用；混有普通機車專用格不算', () {
      expect(motorcycleBaysAllShared(withHeavy), isTrue);
      expect(motorcycleBaysAllShared(mixed), isFalse);
    });

    test('任一分區沒資料就不算全場共用（不要求 zones_complete）', () {
      final unknownZone = ParkingSpot.fromJson(
        lotJson([
          sharedZone,
          {'id': 'b9', 'name': 'B9'},
        ]),
      );
      expect(unknownZone.zonesComplete, isFalse);
      expect(motorcycleBaysAllShared(unknownZone), isFalse);
      expect(motorcycleBaysAllShared(binjiang), isTrue);
      expect(binjiang.zonesComplete, isFalse);
    });

    test('沒有分區：看整點條件；只有重機專區或路邊不算', () {
      expect(motorcycleBaysAllShared(noZones), isTrue);
      expect(
        motorcycleBaysAllShared(ParkingSpot.fromJson(lotJson([heavyZone]))),
        isFalse,
      );
      expect(
        motorcycleBaysAllShared(
          ParkingSpot.fromJson({
            ...lotJson(const []),
            'space_type': 'paidMotorcycle',
            'facility_type': 'roadside',
            'parking_access': 'scooterHeavy',
          }),
        ),
        isFalse,
      );
    });
  });

  group('路牌', () {
    test('濱江國中：重機模式用普通機車剩餘數，標「與普通機車共用」', () {
      final p = seat(binjiang, VehicleType.heavy, [scooter12, heavyNone]);
      expect(p.main, '剩 12 格');
      expect(p.note, contains(sharedWithScooterLabel));
      expect(p.tone, PlateTone.line);
      expect(p.semantics, contains(sharedWithScooterLabel));
      expect(
        sign(binjiang, VehicleType.heavy, [scooter12]).seat.shared,
        isTrue,
      );
    });

    test('普通機車模式不變，不標共用', () {
      final p = seat(binjiang, VehicleType.scooter, [scooter12, heavyNone]);
      expect(p.main, '剩 12 格');
      expect(p.note, isNot(contains(sharedWithScooterLabel)));
      expect(p.semantics, isNot(contains(sharedWithScooterLabel)));
    });

    test('沒有分區、整點普大共用：同樣借用並標示', () {
      final p = seat(noZones, VehicleType.heavy, [scooter12, heavyNone]);
      expect(p.main, '剩 12 格');
      expect(p.note, contains(sharedWithScooterLabel));
    });

    test('混有普通機車專用格：主答案維持空位未知', () {
      final p = seat(mixed, VehicleType.heavy, [scooter12, heavyNone]);
      expect(p.main, '空位未知');
      expect(p.tone, PlateTone.dashed);
    });

    test('重機專區有效數字優先，借用的機車數只算另一區有位', () {
      final s = sign(withHeavy, VehicleType.heavy, [
        scooter12,
        count(AvailabilityVehicle.heavy, 3, total: 10),
      ]).seat;
      expect((s.kind, s.available, s.shared), (SeatKind.live, 3, false));
      expect(s.areas.map((a) => a.id), ['b3']);
      expect(s.more, 1);
    });

    test('延遲的重機數字也勝過新鮮的借用數字', () {
      final s = sign(withHeavy, VehicleType.heavy, [
        scooter12,
        count(
          AvailabilityVehicle.heavy,
          3,
          total: 10,
          age: const Duration(minutes: 15),
        ),
      ]).seat;
      expect((s.kind, s.available, s.shared), (SeatKind.delayed, 3, false));
      // The shared zone's fresh scooter count still says it has space.
      expect(s.more, 1);
    });

    test('重機專區沒有數字：改用普大共用區的機車數並標示', () {
      final s = sign(withHeavy, VehicleType.heavy, [scooter12, heavyNone]).seat;
      expect((s.kind, s.available, s.shared), (SeatKind.live, 12, true));
      expect(s.areas.map((a) => a.id), ['b1']);
    });

    test('機車數過期不當成重機的格數，也不放在車友回報旁', () {
      final s = sign(binjiang, VehicleType.heavy, [
        count(AvailabilityVehicle.scooter, 12, age: const Duration(hours: 2)),
      ]).seat;
      expect(s.kind, SeatKind.unknown);
      expect(s.shared, isFalse);
    });
  });

  group('詳情逐區列', () {
    test('全場共用：共用區列寫剩餘數並標「與普通機車共用」', () {
      final counts = SpotAvailability([scooter12, heavyNone]);
      final rows = seatRows(
        sign(withHeavy, VehicleType.heavy, [scooter12, heavyNone]),
        counts,
        day,
      );
      final shared = rows.firstWhere((r) => r.area.id == 'b1');
      expect(shared.official, '剩 12 格');
      expect(shared.counted, isTrue);
      expect(shared.officialNote, contains(sharedWithScooterLabel));
      final heavy = rows.firstWhere((r) => r.area.id == 'b3');
      expect(heavy.official, isNot(contains('剩')));
    });

    test('混有普通機車專用格：共用區列空位未知，次要行寫機車數且不代表重機', () {
      final counts = SpotAvailability([scooter12, heavyNone]);
      final rows = seatRows(
        sign(mixed, VehicleType.heavy, [scooter12, heavyNone]),
        counts,
        day,
      );
      final shared = rows.firstWhere((r) => r.area.id == 'b1');
      expect(shared.official, '空位未知');
      expect(shared.counted, isFalse);
      expect(shared.officialNote, contains('普通機車區剩 12 格'));
      expect(shared.officialNote, contains(notForHeavyNote));
      expect(shared.officialNote, isNot(contains(sharedWithScooterLabel)));
    });

    test('混合場站的普通機車模式不受影響', () {
      final counts = SpotAvailability([scooter12, heavyNone]);
      final rows = seatRows(
        sign(mixed, VehicleType.scooter, [scooter12, heavyNone]),
        counts,
        day,
      );
      expect(rows.map((r) => r.official), everyElement('剩 12 格'));
      for (final r in rows) {
        expect(r.officialNote, isNot(contains(sharedWithScooterLabel)));
        expect(r.officialNote, isNot(contains(notForHeavyNote)));
      }
    });
  });

  group('詳情摘要、膠囊與篩選（沒有分區）', () {
    ParkingDecision judged(ParkingSpot spot, VehicleType vehicle) =>
        decideParking(spot, vehicle, const [], now: day);

    test('摘要用共用數字，標示共用，不重複列機車次要列', () {
      final f = availabilityFact(
        noZones,
        SpotAvailability([scooter12, heavyNone]),
        VehicleType.heavy,
        judged(noZones, VehicleType.heavy),
        day,
      );
      expect(f.count, 12);
      expect(f.capacity, '／ 共 40 格');
      expect(f.caption, contains(sharedWithScooterLabel));
      expect(f.notes.where((n) => n.text.contains('普通機車區')), isEmpty);
    });

    test('膠囊與「目前有位」篩選跟著算，語音標示共用', () {
      final counts = SpotAvailability([scooter12, heavyNone]);
      final capsule = markerCapsules(
        noZones,
        counts,
        VehicleType.heavy,
        judged(noZones, VehicleType.heavy),
        day,
      ).single;
      expect(capsule.text, '剩 12');
      expect(capsule.semantics, contains(sharedWithScooterLabel));
      expect(
        availabilityExclusion(
          AvailabilityFilter.available,
          noZones,
          counts,
          VehicleType.heavy,
          EligibilityStatus.allowed,
          day,
        ),
        isNull,
      );
    });

    test('混有普通機車專用格：膠囊與篩選不借用', () {
      final counts = SpotAvailability([scooter12, heavyNone]);
      expect(
        markerCapsules(
          mixed,
          counts,
          VehicleType.heavy,
          judged(mixed, VehicleType.heavy),
          day,
        ),
        isEmpty,
      );
      expect(
        availabilityExclusion(
          AvailabilityFilter.available,
          mixed,
          counts,
          VehicleType.heavy,
          EligibilityStatus.allowed,
          day,
        ),
        AvailabilityExclusion.noData,
      );
    });

    test('重機自己的有效數字優先', () {
      final heavy = count(AvailabilityVehicle.heavy, 3, total: 10);
      final f = availabilityFact(
        noZones,
        SpotAvailability([scooter12, heavy]),
        VehicleType.heavy,
        judged(noZones, VehicleType.heavy),
        day,
      );
      expect(f.count, 3);
      expect(f.caption, isNot(contains(sharedWithScooterLabel)));
    });
  });
}

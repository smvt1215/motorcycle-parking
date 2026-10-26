import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';

final now = DateTime(2026, 10, 26, 17, 5);

AvailabilitySnapshot snap(
  AvailabilityVehicle vehicle, {
  int? total = 80,
  int? available = 12,
  Duration age = const Duration(minutes: 3),
  bool suspended = false,
  DateTime? zeroSince,
  DateTime? fetchedAt,
}) => AvailabilitySnapshot(
  spotId: 'lot',
  vehicle: vehicle,
  provider: '臺北市停管處',
  window: AvailabilityWindow.taipei,
  total: total,
  available: available,
  sourceUpdatedAt: now.subtract(age),
  fetchedAt: fetchedAt ?? now,
  suspended: suspended,
  zeroSince: zeroSince,
);

const lot = ParkingSpot(
  id: 'lot',
  name: '測試地下停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  facilityType: FacilityType.underground,
  source: 'official',
  scooterAllowed: true,
  heavyAllowed: true,
  scooterTotal: 80,
);

final heavyCarLot = ParkingSpot.fromJson({
  ...lot.toJson(),
  'parking_access': ParkingAccess.heavyCar.name,
});

SpotAvailability counts(List<AvailabilitySnapshot> list) =>
    SpotAvailability(list);

void main() {
  group('狀態判定', () {
    AvailabilityStatus status(AvailabilitySnapshot s) => s.status(now);

    test('依來源時間分新鮮、延遲、過期（臺北 10／20 分鐘）', () {
      const v = AvailabilityVehicle.scooter;
      expect(
        status(snap(v, age: const Duration(minutes: 10))),
        AvailabilityStatus.fresh,
      );
      expect(
        status(snap(v, age: const Duration(minutes: 11))),
        AvailabilityStatus.delayed,
      );
      expect(
        status(snap(v, age: const Duration(minutes: 20))),
        AvailabilityStatus.delayed,
      );
      expect(
        status(snap(v, age: const Duration(minutes: 21))),
        AvailabilityStatus.stale,
      );
    });

    test('剛抓到的舊資料不會因為抓取時間而變新鮮', () {
      final s = snap(
        AvailabilityVehicle.scooter,
        age: const Duration(minutes: 30),
        fetchedAt: now,
      );
      expect(s.status(now), AvailabilityStatus.stale);
    });

    test('-1、-9、null 與容量 0 算無資料，不是 0', () {
      for (final s in [
        snap(AvailabilityVehicle.heavy, available: -9),
        snap(AvailabilityVehicle.heavy, available: -1),
        snap(AvailabilityVehicle.heavy, available: null),
        snap(AvailabilityVehicle.heavy, total: 0, available: 0),
        snap(AvailabilityVehicle.heavy, total: null, available: 3),
      ]) {
        expect(s.status(now), AvailabilityStatus.unavailable);
      }
    });

    test('其他負值、剩餘大於容量、未來時間與長期為 0 算異常', () {
      expect(
        snap(AvailabilityVehicle.scooter, available: -4).status(now),
        AvailabilityStatus.invalid,
      );
      expect(
        snap(AvailabilityVehicle.scooter, available: 81).status(now),
        AvailabilityStatus.invalid,
      );
      expect(
        snap(
          AvailabilityVehicle.scooter,
          age: const Duration(minutes: -10),
        ).status(now),
        AvailabilityStatus.invalid,
      );
      expect(
        snap(
          AvailabilityVehicle.scooter,
          available: 0,
          zeroSince: now.subtract(const Duration(hours: 3)),
        ).status(now),
        AvailabilityStatus.invalid,
      );
      expect(
        snap(
          AvailabilityVehicle.scooter,
          available: 0,
          zeroSince: now.subtract(const Duration(minutes: 30)),
        ).status(now),
        AvailabilityStatus.fresh,
      );
    });

    test('暫停營運與已滿分開', () {
      expect(
        snap(AvailabilityVehicle.scooter, suspended: true).status(now),
        AvailabilityStatus.suspended,
      );
      expect(
        snap(AvailabilityVehicle.scooter, available: 0).status(now),
        AvailabilityStatus.fresh,
      );
    });
  });

  group('地圖膠囊', () {
    List<AvailabilityCapsule> capsules(
      ParkingSpot spot,
      List<AvailabilitySnapshot> list,
      VehicleType vehicle,
    ) => markerCapsules(spot, counts(list), vehicle, now);

    test('新鮮為墨色「剩 N」，0 為「已滿」，延遲為描邊並保留數字', () {
      final fresh = capsules(lot, [
        snap(AvailabilityVehicle.scooter),
      ], VehicleType.scooter).single;
      expect((fresh.text, fresh.style), ('剩 12', CapsuleStyle.live));
      expect(fresh.semantics, '官方即時：剩 12 格');
      final full = capsules(lot, [
        snap(AvailabilityVehicle.scooter, available: 0),
      ], VehicleType.scooter).single;
      expect(full.text, '已滿');
      final delayed = capsules(lot, [
        snap(AvailabilityVehicle.scooter, age: const Duration(minutes: 14)),
      ], VehicleType.scooter).single;
      expect((delayed.text, delayed.style), ('剩 12', CapsuleStyle.delayed));
      expect(delayed.semantics, contains('更新延遲 14 分鐘'));
      final suspended = capsules(lot, [
        snap(AvailabilityVehicle.scooter, suspended: true),
      ], VehicleType.scooter).single;
      expect(suspended.text, '暫停');
    });

    test('過期、無資料、異常都不顯示膠囊', () {
      for (final s in [
        snap(AvailabilityVehicle.scooter, age: const Duration(minutes: 40)),
        snap(AvailabilityVehicle.scooter, available: -9),
        snap(AvailabilityVehicle.scooter, available: 99),
      ]) {
        expect(capsules(lot, [s], VehicleType.scooter), isEmpty);
      }
    });

    test('重機膠囊只在有效重機值時出現，無值不顯示也不顯示 0，不借用機車數字', () {
      expect(
        capsules(lot, [
          snap(AvailabilityVehicle.scooter),
          snap(AvailabilityVehicle.heavy, total: 10, available: 3),
        ], VehicleType.heavy).single.text,
        '剩 3',
      );
      for (final heavy in [
        snap(AvailabilityVehicle.heavy, available: -9),
        snap(AvailabilityVehicle.heavy, total: 0, available: 0),
      ]) {
        final shown = capsules(lot, [
          snap(AvailabilityVehicle.scooter),
          heavy,
        ], VehicleType.heavy);
        expect(shown, isEmpty);
      }
      expect(
        capsules(lot, [snap(AvailabilityVehicle.scooter)], VehicleType.heavy),
        isEmpty,
      );
    });

    test('汽車格膠囊只在大型重機且確認 heavyCar 時出現，只有汽車圖示與「剩 N」', () {
      final car = snap(AvailabilityVehicle.car, total: 100, available: 30);
      final shown = capsules(heavyCarLot, [car], VehicleType.heavy).single;
      expect(
        (shown.text, shown.style, shown.delayed),
        ('剩 30', CapsuleStyle.car, false),
      );
      expect(shown.text, isNot(contains('共用')));
      expect(shown.text, isNot(contains('汽車格')));
      expect(capsules(heavyCarLot, [car], VehicleType.scooter), isEmpty);
      expect(capsules(lot, [car], VehicleType.heavy), isEmpty);
      final zoned = ParkingSpot.fromJson({
        ...lot.toJson(),
        'parking_zones': [
          {'name': 'B2', 'access': ParkingAccess.heavyCar.name},
        ],
      });
      expect(capsules(zoned, [car], VehicleType.heavy), hasLength(1));
    });

    test('汽車格延遲照樣顯示（汽車樣式加時鐘），過期與無資料不顯示', () {
      final delayed = capsules(heavyCarLot, [
        snap(
          AvailabilityVehicle.car,
          total: 100,
          available: 30,
          age: const Duration(minutes: 15),
        ),
      ], VehicleType.heavy).single;
      expect((delayed.style, delayed.delayed), (CapsuleStyle.car, true));
      expect(delayed.text, '剩 30');
      expect(delayed.semantics, contains('更新延遲 15 分鐘'));
      for (final car in [
        snap(
          AvailabilityVehicle.car,
          total: 100,
          available: 30,
          age: const Duration(minutes: 25),
        ),
        snap(AvailabilityVehicle.car, total: 100, available: -9),
      ]) {
        expect(capsules(heavyCarLot, [car], VehicleType.heavy), isEmpty);
      }
    });

    test('路邊格不顯示膠囊', () {
      final roadside = ParkingSpot.fromJson({
        ...lot.toJson(),
        'space_type': SpaceType.paidMotorcycle.name,
        'facility_type': FacilityType.roadside.name,
      });
      expect(
        capsules(roadside, [
          snap(AvailabilityVehicle.scooter),
        ], VehicleType.scooter),
        isEmpty,
      );
    });
  });

  group('密集時的主要膠囊', () {
    const own = AvailabilityCapsule(
      text: '剩 3',
      style: CapsuleStyle.live,
      semantics: '官方即時：剩 3 格',
    );
    const car = AvailabilityCapsule(
      text: '剩 30',
      style: CapsuleStyle.car,
      semantics: '汽車格剩 30 格，大型重機可停汽車格',
    );
    const allowed = EligibilityStatus.allowed;

    test('① 重機只開放汽車格、沒有重機剩餘數：主要膠囊是汽車格', () {
      expect(primaryCapsules(VehicleType.heavy, allowed, [car]), [car]);
    });

    test('② 有重機剩餘數也可停汽車格：主要膠囊是重機剩餘', () {
      expect(primaryCapsules(VehicleType.heavy, allowed, [own, car]), [own]);
      expect(
        primaryCapsules(VehicleType.heavy, EligibilityStatus.conditional, [
          own,
          car,
        ]),
        [own],
      );
    });

    test('③ 不可停或待確認：密集時不顯示膠囊', () {
      for (final status in [
        EligibilityStatus.notAllowed,
        EligibilityStatus.unverified,
      ]) {
        expect(primaryCapsules(VehicleType.heavy, status, [own, car]), isEmpty);
        expect(primaryCapsules(VehicleType.scooter, status, [own]), isEmpty);
      }
    });

    test('普通機車模式：主要膠囊是機車剩餘，沒有就不顯示', () {
      expect(primaryCapsules(VehicleType.scooter, allowed, [own]), [own]);
      expect(primaryCapsules(VehicleType.scooter, allowed, const []), isEmpty);
      // A car-bay pill never stands in for scooters.
      expect(primaryCapsules(VehicleType.scooter, allowed, [car]), isEmpty);
    });
  });

  group('篩選', () {
    AvailabilityExclusion? reason(
      AvailabilityFilter filter,
      List<AvailabilitySnapshot> list, {
      VehicleType vehicle = VehicleType.scooter,
      EligibilityStatus eligibility = EligibilityStatus.allowed,
      ParkingSpot? spot,
    }) => availabilityExclusion(
      filter,
      spot ?? lot,
      counts(list),
      vehicle,
      eligibility,
      now,
    );

    test('未知、過期、異常都不會被排成「已滿」', () {
      for (final filter in [
        AvailabilityFilter.available,
        AvailabilityFilter.live,
      ]) {
        expect(reason(filter, []), AvailabilityExclusion.noData);
        expect(
          reason(filter, [snap(AvailabilityVehicle.scooter, available: -9)]),
          AvailabilityExclusion.noData,
        );
        expect(
          reason(filter, [snap(AvailabilityVehicle.scooter, available: 99)]),
          AvailabilityExclusion.noData,
        );
        expect(
          reason(filter, [
            snap(AvailabilityVehicle.scooter, age: const Duration(hours: 1)),
          ]),
          AvailabilityExclusion.stale,
        );
        expect(
          reason(filter, [
            snap(
              AvailabilityVehicle.scooter,
              available: 0,
              zeroSince: now.subtract(const Duration(hours: 5)),
            ),
          ]),
          isNot(AvailabilityExclusion.full),
        );
      }
    });

    test('目前有位：新鮮、有位、可停或有條件可停才保留', () {
      const f = AvailabilityFilter.available;
      final ok = [snap(AvailabilityVehicle.scooter)];
      expect(reason(f, ok), isNull);
      expect(reason(f, ok, eligibility: EligibilityStatus.conditional), isNull);
      expect(
        reason(f, ok, eligibility: EligibilityStatus.notAllowed),
        AvailabilityExclusion.notAllowed,
      );
      expect(
        reason(f, ok, eligibility: EligibilityStatus.unverified),
        AvailabilityExclusion.unverified,
      );
      expect(
        reason(f, [snap(AvailabilityVehicle.scooter, available: 0)]),
        AvailabilityExclusion.full,
      );
      expect(
        reason(f, [
          snap(AvailabilityVehicle.scooter, age: const Duration(minutes: 12)),
        ]),
        AvailabilityExclusion.delayed,
      );
      expect(
        reason(f, [snap(AvailabilityVehicle.scooter, suspended: true)]),
        AvailabilityExclusion.suspended,
      );
    });

    test('有即時資訊包含已滿；車種不符與汽車格不算重機有位', () {
      expect(
        reason(AvailabilityFilter.live, [
          snap(AvailabilityVehicle.scooter, available: 0),
        ]),
        isNull,
      );
      expect(
        reason(AvailabilityFilter.available, [
          snap(AvailabilityVehicle.scooter),
        ], vehicle: VehicleType.heavy),
        AvailabilityExclusion.noData,
      );
      expect(
        reason(
          AvailabilityFilter.available,
          [snap(AvailabilityVehicle.car, total: 100, available: 30)],
          vehicle: VehicleType.heavy,
          spot: heavyCarLot,
        ),
        AvailabilityExclusion.noData,
      );
    });

    test('關閉時不排除任何點', () {
      expect(reason(AvailabilityFilter.off, []), isNull);
    });
  });

  group('詳情摘要文案', () {
    AvailabilityFact fact(
      List<AvailabilitySnapshot> list, {
      VehicleType vehicle = VehicleType.scooter,
      ParkingSpot? spot,
      EligibilityStatus eligibility = EligibilityStatus.allowed,
    }) =>
        availabilityFact(spot ?? lot, counts(list), vehicle, eligibility, now);

    test('新鮮：大數字、剩餘、共 N 格、時間與來源', () {
      final f = fact([snap(AvailabilityVehicle.scooter)]);
      expect(
        (f.title, f.count, f.headline, f.capacity),
        ('機車車位', 12, '剩餘', '／ 共 80 格'),
      );
      expect(f.caption, '17:02 更新 ・ 臺北市停管處');
      expect(f.semantics, contains('剩餘 12 格'));
    });

    test('已滿寫已滿；不可停仍照實顯示數字', () {
      expect(
        fact([snap(AvailabilityVehicle.scooter, available: 0)]).headline,
        '剩餘，已滿',
      );
      final denied = fact(
        [snap(AvailabilityVehicle.heavy, total: 40, available: 20)],
        vehicle: VehicleType.heavy,
        eligibility: EligibilityStatus.notAllowed,
      );
      expect(denied.count, 20);
      expect(denied.caption, contains('大型重機不可停放此場站'));
    });

    test('延遲強制註記分鐘數與最後更新時間', () {
      final f = fact([
        snap(
          AvailabilityVehicle.scooter,
          available: 7,
          age: const Duration(minutes: 14),
        ),
      ]);
      expect(f.count, 7);
      expect(f.headline, '剩餘，更新延遲 14 分鐘');
      expect(f.caption, '最後更新 16:51 ・ 臺北市停管處');
    });

    test('過期、異常、暫停、無資料都不顯示數字', () {
      final stale = fact([
        snap(AvailabilityVehicle.scooter, age: const Duration(hours: 1)),
      ]);
      expect(
        (stale.count, stale.headline, stale.caption),
        (null, '資料過期 ・ 空位未知', '共 80 格'),
      );
      final invalid = fact([snap(AvailabilityVehicle.scooter, available: 99)]);
      expect(
        (invalid.count, invalid.headline, invalid.caption),
        (null, '空位未知', '共 80 格 ・ 即時資料暫時無法使用'),
      );
      final suspended = fact([
        snap(AvailabilityVehicle.scooter, suspended: true),
      ]);
      expect(
        (suspended.headline, suspended.caption),
        ('暫停營運', '來源標示場站停止服務 ・ 17:02 更新 ・ 臺北市停管處'),
      );
      final none = fact([]);
      expect(
        (none.count, none.headline, none.caption),
        (null, '無即時資料', '共 80 格（靜態資料）'),
      );
      final noTotal = fact(
        [],
        spot: ParkingSpot.fromJson({...lot.toJson(), 'scooter_total': null}),
      );
      expect(noTotal.caption, '總格數未提供');
    });

    test('重機無資料時，機車數字只當次要列，並註明不代表重機', () {
      final f = fact([
        snap(AvailabilityVehicle.scooter, age: const Duration(minutes: 14)),
        snap(AvailabilityVehicle.heavy, available: -9),
      ], vehicle: VehicleType.heavy);
      expect((f.title, f.count, f.headline), ('大型重機車位', null, '無即時資料'));
      expect(f.caption, contains('場站未提供重機或汽車格剩餘'));
      expect(f.notes.single.text, '普通機車區剩 12 格，更新延遲 14 分鐘');
      expect(f.notes.single.caption, contains('不代表重機可用格數'));
    });

    test('汽車格剩餘只寫「汽車格剩餘 N」，不寫共用或費率', () {
      final f = fact(
        [
          snap(AvailabilityVehicle.heavy, total: 10, available: 2),
          snap(AvailabilityVehicle.car, total: 100, available: 30),
        ],
        vehicle: VehicleType.heavy,
        spot: heavyCarLot,
      );
      expect(f.count, 2);
      expect(f.notes.single.text, '汽車格剩餘 30');
      for (final note in f.notes) {
        expect('${note.text}${note.caption}', isNot(contains('共用')));
        expect('${note.text}${note.caption}', isNot(contains('費率')));
      }
      final delayed = fact(
        [
          snap(
            AvailabilityVehicle.car,
            total: 100,
            available: 30,
            age: const Duration(minutes: 15),
          ),
        ],
        vehicle: VehicleType.heavy,
        spot: heavyCarLot,
      );
      expect(delayed.notes.single.text, '汽車格剩餘 30，更新延遲 15 分鐘');
      expect(delayed.caption, contains('場站未提供重機剩餘'));
    });
  });

  test('連上後端（P2 前）沒有即時資料源，範例資料源只給範例停車場', () async {
    expect(const NoAvailabilitySource().enabled, isFalse);
    expect(await const NoAvailabilitySource().forSpots([lot]), isEmpty);
    final demo = demoAvailabilitySource(clock: () => now);
    final demoLot = ParkingSpot.fromJson({
      ...lot.toJson(),
      'id': '00000000-0000-4000-8000-000000000004',
    });
    final result = await demo.forSpots([lot, demoLot]);
    expect(result.keys, [demoLot.id]);
    expect(
      result[demoLot.id]!.of(AvailabilityVehicle.scooter)!.status(now),
      AvailabilityStatus.fresh,
    );
  });
}

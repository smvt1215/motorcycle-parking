import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/eligibility_display.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/models/parking.dart';

final now = DateTime(2026, 10, 25, 12);

ParkingSpot lot({
  String source = 'community',
  String role = '',
  bool? scooter,
  bool? heavy,
  TrustStatus status = TrustStatus.pending,
  DateTime? confirmed,
  DateTime? created,
  DateTime? scooterChecked,
  DateTime? heavyChecked,
  DateTime? updated,
  SpaceType space = SpaceType.offStreet,
  FacilityType? facility = FacilityType.underground,
}) => ParkingSpot(
  id: 'lot',
  name: '測試停車場',
  lat: 25.08,
  lng: 121.56,
  city: '臺北市',
  district: '內湖區',
  source: source,
  contributorRole: role,
  spaceType: space,
  facilityType: facility,
  scooterAllowed: scooter,
  heavyAllowed: heavy,
  status: status,
  lastConfirmedAt: confirmed,
  createdAt: created,
  scooterVerifiedAt: scooterChecked,
  heavyVerifiedAt: heavyChecked,
  updatedAt: updated,
);

EligibilityDisplay show(
  ParkingSpot spot, [
  VehicleType v = VehicleType.scooter,
]) =>
    eligibilityDisplay(spot, v, eligibility(spot, v, null, now: now), now: now);

void main() {
  test('官方場站可停：已判定，標示政府資料與更新日期', () {
    final d = show(
      lot(source: 'official', scooter: true, updated: DateTime(2026, 10, 1, 8)),
    );
    expect(d.tier, EligibilityTier.decided);
    expect(d.label, '可停');
    expect(d.basis, '依政府公開資料，更新於 2026-10-01');
  });

  test('管理員核驗有效期內：已判定，標示核驗日期', () {
    final d = show(
      lot(scooter: true, scooterChecked: DateTime(2026, 10, 20, 9)),
    );
    expect(d.tier, EligibilityTier.decided);
    expect(d.label, '可停');
    expect(d.basis, '管理員確認，2026-10-20');
  });

  test('只有車友回報可停：仍是待確認判斷，顯示回報時間與入口公告提醒', () {
    final spot = lot(scooter: true, created: DateTime(2026, 3, 1, 9));
    expect(
      eligibility(spot, VehicleType.scooter, null, now: now).status,
      EligibilityStatus.unverified,
    );
    final d = show(spot);
    expect(d.tier, EligibilityTier.reportedAllowed);
    expect(d.label, '車友回報可停');
    expect(d.lapsed, isFalse);
    expect(d.explanation, '可停放車種未經確認，請以入口公告為準。');
    expect(d.basis, '回報於 2026-03-01');
  });

  test('已確認存在的車友回報說明存在已確認、車種未核實', () {
    final d = show(
      lot(
        scooter: true,
        status: TrustStatus.confirmed,
        confirmed: DateTime.now(),
      ),
    );
    expect(d.tier, EligibilityTier.reportedAllowed);
    expect(d.explanation, '此處確實有停車點，可停放車種未經確認，請以入口公告為準。');
    expect(d.basis, '回報時間未提供');
  });

  test('只有車友回報不可停：顯示回報不可停，不顯示成可停', () {
    final d = show(
      lot(heavy: false, created: DateTime(2026, 5, 2)),
      VehicleType.heavy,
    );
    expect(d.tier, EligibilityTier.reportedNotAllowed);
    expect(d.label, '車友回報不可停');
    expect(d.basis, '回報於 2026-05-02');
  });

  test('匯入的社群點以匯入時間標示', () {
    final d = show(
      lot(scooter: true, role: 'import', created: DateTime(2026, 4, 3)),
    );
    expect(d.basis, '匯入於 2026-04-03');
    expect(show(lot(scooter: true, source: 'import')).basis, '匯入時間未提供');
  });

  test('核驗過期回落：顯示曾確認與過期日期，判斷仍是待確認', () {
    final old = DateTime(2025, 1, 1);
    final spot = lot(scooter: true, scooterChecked: old);
    expect(
      eligibility(spot, VehicleType.scooter, null, now: now).status,
      EligibilityStatus.unverified,
    );
    final d = show(spot);
    expect(d.tier, EligibilityTier.reportedAllowed);
    expect(d.label, '曾確認可停');
    expect(d.basis, '管理員確認，2025-01-01，已超過 180 天');
    final closed = show(
      lot(heavy: false, heavyChecked: old),
      VehicleType.heavy,
    );
    expect(closed.label, '曾確認不可停');
    expect(closed.lapsed, isTrue);
  });

  test('沒有任何車種資料：待確認', () {
    final d = show(lot());
    expect(d.tier, EligibilityTier.noData);
    expect(d.label, '開放資訊待確認');
    expect(d.basis, isNull);
    final official = show(lot(source: 'official'));
    expect(official.tier, EligibilityTier.noData);
  });

  test('依縣市規則判定的路邊格位不分層', () {
    final d = show(
      lot(
        scooter: true,
        space: SpaceType.paidMotorcycle,
        facility: null,
        created: DateTime(2026, 3, 1),
      ),
    );
    expect(d.tier, EligibilityTier.other);
    expect(d.label, '待確認');
    expect(d.basis, isNull);
  });

  test('分層不改變判斷：回報層只出現在待確認，判定層只出現在已判定', () {
    final fresh = now.subtract(const Duration(days: 3));
    final old = now.subtract(const Duration(days: 400));
    final cases = [
      for (final source in ['community', 'import', 'official'])
        for (final flag in [null, true, false])
          for (final status in TrustStatus.values)
            for (final confirmed in [null, DateTime.now(), old])
              for (final checked in [null, fresh, old])
                for (final vehicle in VehicleType.values)
                  (source, flag, status, confirmed, checked, vehicle),
    ];
    for (final (source, flag, status, confirmed, checked, vehicle) in cases) {
      final spot = lot(
        source: source,
        scooter: flag,
        heavy: flag,
        status: status,
        confirmed: confirmed,
        scooterChecked: checked,
        heavyChecked: checked,
      );
      final result = eligibility(spot, vehicle, null, now: now);
      final d = eligibilityDisplay(spot, vehicle, result, now: now);
      final reason = '$source $flag $status $confirmed $checked $vehicle';
      expect(
        d.tier == EligibilityTier.decided,
        result.status != EligibilityStatus.unverified,
        reason: reason,
      );
      if (d.reported) {
        expect(result.status, EligibilityStatus.unverified, reason: reason);
        expect(d.label, isNot('可停'), reason: reason);
        expect(d.label.endsWith(flag! ? '可停' : '不可停'), isTrue, reason: reason);
      }
    }
  });

  test('已確認欄位逐車種列出確認日期，過期註明', () {
    expect(
      verifiedFieldLines(
        lot(
          scooter: true,
          heavy: false,
          scooterChecked: DateTime(2026, 10, 20),
          heavyChecked: DateTime(2025, 1, 1),
        ),
        now: now,
      ),
      ['普通機車可停：管理員確認，2026-10-20', '大型重機不可停：管理員確認，2025-01-01，已超過 180 天'],
    );
    expect(verifiedFieldLines(lot(scooter: true), now: now), isEmpty);
    expect(
      verifiedFieldLines(
        lot(source: 'official', scooter: true, scooterChecked: now),
        now: now,
      ),
      isEmpty,
    );
  });

  test('列表標籤保留車友回報，其他沿用判斷標籤', () {
    final reported = lot(scooter: true);
    expect(
      eligibilityListLabel(
        reported,
        VehicleType.scooter,
        eligibility(reported, VehicleType.scooter, null, now: now),
        now: now,
      ),
      '車友回報可停',
    );
    final empty = lot();
    expect(
      eligibilityListLabel(
        empty,
        VehicleType.scooter,
        eligibility(empty, VehicleType.scooter, null, now: now),
        now: now,
      ),
      '待確認',
    );
  });

  test('created_at 讀入並隨收藏保存', () {
    final spot = ParkingSpot.fromJson({
      'id': 'a',
      'name': 'n',
      'lat': 25.0,
      'lng': 121.5,
      'city': '臺北市',
      'space_type': 'offStreet',
      'created_at': '2026-03-01T01:00:00Z',
    });
    expect(spot.createdAt, DateTime.utc(2026, 3, 1, 1));
    expect(ParkingSpot.fromJson(spot.toJson()).createdAt, spot.createdAt);
  });

  group('讀取 ParkingDecision.basis（C4）', () {
    ParkingSpot zoned(String source, {DateTime? checked}) => ParkingSpot(
      id: 'lot',
      name: 'lot',
      lat: 25,
      lng: 121,
      city: '臺北市',
      spaceType: SpaceType.offStreet,
      source: source,
      status: TrustStatus.confirmed,
      lastConfirmedAt: now,
      heavyAllowed: true,
      heavyVerifiedAt: checked,
      updatedAt: DateTime(2026, 10, 20),
      zones: const [
        ParkingZone(name: '機車區', access: ParkingAccess.scooterOnly),
      ],
    );
    EligibilityDisplay showDecision(ParkingSpot spot) {
      final d = decideParking(spot, VehicleType.heavy, const [], now: now);
      return eligibilityDisplay(
        spot,
        VehicleType.heavy,
        d.eligibility,
        now: now,
        decision: d,
      );
    }

    test('官方場站分區不完整：待確認，保留政府資料依據並列出分區', () {
      final d = showDecision(zoned('official'));
      expect(d.tier, EligibilityTier.other);
      expect(d.label, '開放資訊待確認');
      expect(d.basis, '依政府公開資料，更新於 2026-10-20');
      expect(d.zones.single.label, '不可停');
    });

    test('管理員確認過的社群停車場分區不完整：不是「車友回報」', () {
      final d = showDecision(
        zoned('community', checked: now.subtract(const Duration(days: 3))),
      );
      expect(d.reported, isFalse);
      expect(d.label, '開放資訊待確認');
      expect(d.basis, startsWith('管理員確認，'));
    });

    test('未確認的社群停車場不列分區：分區是同一份未確認的回報', () {
      final d = showDecision(zoned('community'));
      expect(d.reported, isTrue);
      expect(d.zones, isEmpty);
    });
  });

  test('確認狀態逐類列出（決定 30）：只有停放車種，同日合併', () {
    final day = DateTime(2026, 10, 20);
    expect(
      confirmationLines(
        lot(
          scooter: true,
          heavy: false,
          scooterChecked: day,
          heavyChecked: day,
        ),
        now: now,
      ),
      ['停放車種・管理員確認，2026-10-20'],
    );
    expect(
      confirmationLines(
        lot(
          scooter: true,
          heavy: false,
          scooterChecked: day,
          heavyChecked: DateTime(2025, 1, 1),
        ),
        now: now,
      ),
      ['停放車種（普通機車）・管理員確認，2026-10-20', '停放車種（大型重機）・管理員確認，2025-01-01，已超過 180 天'],
    );
    expect(confirmationLines(lot(scooter: true), now: now), isEmpty);
  });
}

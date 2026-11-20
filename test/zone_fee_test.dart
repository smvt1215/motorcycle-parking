import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';

ParkingSpot lot({Fee? fee, List<ParkingZone> zones = const []}) => ParkingSpot(
  id: 'zone-fees',
  name: '分區費率停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  fee: fee,
  zones: zones,
  feeNote: '舊文字',
);

void main() {
  test('點位和分區結構化費率隨收藏完整往返，舊字串保持原值', () {
    final original = lot(
      fee: const Fee(
        scooter: Rate(FeeMode.perVisit, amount: 30, renew: Renew.midnight),
      ),
      zones: const [
        ParkingZone(
          name: 'B2',
          access: ParkingAccess.scooterHeavy,
          scooterFeeNote: '舊普機文字',
          heavyFeeNote: '舊重機文字',
          carFeeNote: '汽車原文',
          fee: Fee(
            scooter: Rate(FeeMode.free),
            heavy: Rate(
              FeeMode.hourly,
              amount: 20,
              perMinutes: 30,
              dailyCap: 100,
            ),
          ),
        ),
      ],
    );
    final restored = ParkingSpot.fromJson(original.toJson());
    expect(restored.fee, original.fee);
    expect(restored.zones.single.fee, original.zones.single.fee);
    expect(restored.zones.single.scooterFeeNote, '舊普機文字');
    expect(restored.zones.single.carFeeNote, '汽車原文');
    final legacy = ParkingSpot.fromJson({
      ...original.toJson(),
      'fee': null,
      'parking_zones': [
        {'name': '舊區', 'fee_note': '免費'},
      ],
    });
    expect(legacy.fee, isNull);
    expect(legacy.toJson().containsKey('fee'), isFalse);
    expect(legacy.zones.single.toJson(), {'name': '舊區', 'fee_note': '免費'});
  });

  test('明確的空費率保持未確認，不退回舊文字並隨收藏保留', () {
    final spot = ParkingSpot.fromJson({
      ...lot().toJson(),
      'fee': <String, Object>{},
      'parking_zones': [
        {
          'name': 'B2',
          'fee': <String, Object>{},
          'fee_note': '每次 20 元，隔日另計',
          'heavy_fee_note': '舊重機免費',
        },
      ],
    });
    // A spot's fee = {} holds no structured rate (#114) and reads as none;
    // a zone's explicit empty fee still keeps its legacy strings out.
    expect(spot.fee, isNull);
    expect(spot.zones.single.fee, const Fee());
    expect(spot.zones.single.heavyFeeText, '');
    expect(spot.toJson()['fee'], isNull);
    expect(
      (spot.toJson()['parking_zones'] as List).single['fee'],
      <String, Object>{},
    );
  });

  test('分區有結構化費率而未填某車種時，該車種不退回舊文字', () {
    const partial = ParkingZone(
      name: 'B2',
      access: ParkingAccess.scooterHeavy,
      heavyFeeNote: '舊重機每次 50 元，隔日另計',
      fee: Fee(scooter: Rate(FeeMode.free)),
    );
    expect(partial.heavyFeeText, '');
  });

  test('共用格不同車種費率在點位序列化往返後完整保留，舊資料不產生費率', () {
    final original = lot(
      zones: const [
        ParkingZone(
          name: '共用車格',
          access: ParkingAccess.scooterHeavy,
          scooterFeeNote: '20 元／次',
          heavyFeeNote: '30 元／小時',
        ),
      ],
    );
    final restored = ParkingSpot.fromJson(original.toJson());
    expect(restored.zones.single.access, ParkingAccess.scooterHeavy);
    expect(restored.zones.single.scooterFeeNote, '20 元／次');
    expect(restored.zones.single.heavyFeeNote, '30 元／小時');
    final legacy = ParkingZone.fromJson({'name': '舊分區', 'fee_note': '請依現場公告'});
    expect(legacy.scooterFeeNote, isEmpty);
    expect(legacy.heavyFeeNote, isEmpty);
    final malformed = ParkingZone.fromJson({
      'name': '未確認費率',
      'scooter_fee_note': 20,
      'heavy_fee_note': {'price': 30},
    });
    expect(malformed.scooterFeeNote, isEmpty);
    expect(malformed.heavyFeeNote, isEmpty);
    expect(legacy.toJson(), {'name': '舊分區', 'fee_note': '請依現場公告'});
  });
}

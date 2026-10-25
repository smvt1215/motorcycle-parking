import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/parking.dart';

const spot = ParkingSpot(
  id: 'contributor-test',
  name: '回報者測試',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
);

void main() {
  test('公開回報者快照隨收藏完整往返，沒有加入帳號識別欄位', () {
    final row = {
      ...spot.toJson(),
      'contributor_name': '小哲',
      'contributor_role': 'rider',
    };
    final parsed = ParkingSpot.fromJson(row);
    expect(parsed.contributorName, '小哲');
    expect(parsed.contributorRole, 'rider');
    final restored = ParkingSpot.fromJson(parsed.toJson());
    expect(restored.contributorName, parsed.contributorName);
    expect(restored.contributorRole, parsed.contributorRole);
    expect(restored.toJson().containsKey('user_id'), isFalse);
    expect(restored.toJson().containsKey('email'), isFalse);
  });

  test('管理員與匯入角色可讀取，未知角色與錯誤型別維持空值', () {
    for (final role in ['admin', 'import']) {
      final parsed = ParkingSpot.fromJson({
        ...spot.toJson(),
        'contributor_role': role,
      });
      expect(parsed.contributorRole, role);
      expect(ParkingSpot.fromJson(parsed.toJson()).contributorRole, role);
    }
    final malformed = ParkingSpot.fromJson({
      ...spot.toJson(),
      'contributor_name': 42,
      'contributor_role': 'superuser',
    });
    expect(malformed.contributorName, '');
    expect(malformed.contributorRole, '');
    expect(malformed.toJson().containsKey('contributor_name'), isFalse);
    expect(malformed.toJson().containsKey('contributor_role'), isFalse);
  });

  test('舊資料沒有回報者欄位仍可使用，序列化不寫出空欄位', () {
    final legacy = ParkingSpot.fromJson(spot.toJson());
    expect(legacy.contributorName, '');
    expect(legacy.contributorRole, '');
    expect(legacy.toJson().containsKey('contributor_name'), isFalse);
    expect(legacy.toJson().containsKey('contributor_role'), isFalse);
  });
}

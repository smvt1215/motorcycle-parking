import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/repositories.dart';

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
  test('即時資料可讀取回報者名稱，收藏不保存名稱也不加入帳號識別欄位', () {
    final row = {
      ...spot.toJson(),
      'contributor_name': '小哲',
      'contributor_role': 'rider',
    };
    final parsed = ParkingSpot.fromJson(row);
    expect(parsed.contributorName, '小哲');
    expect(parsed.contributorRole, 'rider');
    final saved = parsed.toJson();
    expect(saved.containsKey('contributor_name'), isFalse);
    expect(saved['contributor_role'], 'rider');
    expect(saved.containsKey('user_id'), isFalse);
    expect(saved.containsKey('email'), isFalse);
    final restored = ParkingSpot.favorite(saved).single;
    expect(restored.contributorName, '');
    expect(restored.contributorRole, 'rider');
  });

  test('舊版收藏裡已存的回報者名稱在讀取時忽略', () {
    final legacy = {
      ...spot.toJson(),
      'contributor_name': '已清除的名稱',
      'contributor_role': 'rider',
    };
    final restored = ParkingSpot.favorite(legacy).single;
    expect(restored.contributorName, '');
    expect(restored.contributorRole, 'rider');
    expect(legacy['contributor_name'], '已清除的名稱', reason: '不改動傳入的資料');
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

  test('本機收藏不寫入回報者名稱，舊資料讀回時也忽略', () async {
    SharedPreferences.setMockInitialValues({
      'favorites:guest': jsonEncode([
        {
          ...spot.toJson(),
          'contributor_name': '舊快照',
          'contributor_role': 'rider',
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final local = LocalRepository(prefs);
    final loaded = local.favorites('guest').single;
    expect(loaded.contributorName, '');
    expect(loaded.contributorRole, 'rider');
    await local.setFavorites('guest', [
      ParkingSpot.fromJson({
        ...spot.toJson(),
        'contributor_name': '小哲',
        'contributor_role': 'rider',
      }),
    ]);
    expect(prefs.getString('favorites:guest'), isNot(contains('小哲')));
    expect(
      prefs.getString('favorites:guest'),
      isNot(contains('contributor_name')),
    );
  });

  test('公開代號與 is_own 只在即時資料，收藏與序列化都不保存（#280）', () {
    const handle = '3fa8c1d27b9e40a6c55d0e1f2a3b4c5d';
    final parsed = ParkingSpot.fromJson({
      ...spot.toJson(),
      'contributor_handle': handle,
      'is_own': true,
    });
    expect(parsed.contributorHandle, handle);
    expect(parsed.isOwn, isTrue);
    final saved = parsed.toJson();
    expect(saved.containsKey('contributor_handle'), isFalse);
    expect(saved.containsKey('is_own'), isFalse);
    final legacy = {
      ...spot.toJson(),
      'contributor_handle': handle,
      'is_own': true,
    };
    final restored = ParkingSpot.favorite(legacy).single;
    expect(restored.contributorHandle, isNull);
    expect(restored.isOwn, isFalse);
    expect(legacy['contributor_handle'], handle, reason: '不改動傳入的資料');
  });

  test('缺少或型別不對的代號與 is_own 視為沒有', () {
    final missing = ParkingSpot.fromJson(spot.toJson());
    expect(missing.contributorHandle, isNull);
    expect(missing.isOwn, isFalse);
    final malformed = ParkingSpot.fromJson({
      ...spot.toJson(),
      'contributor_handle': 42,
      'is_own': 'true',
    });
    expect(malformed.contributorHandle, isNull);
    expect(malformed.isOwn, isFalse);
    final nulls = ParkingSpot.fromJson({
      ...spot.toJson(),
      'contributor_handle': null,
      'is_own': null,
    });
    expect(nulls.contributorHandle, isNull);
    expect(nulls.isOwn, isFalse);
  });
}

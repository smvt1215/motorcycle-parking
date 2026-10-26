import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/admin/spots/spot_map.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/parking.dart';

import 'fake_admin_gateway.dart';

Map<String, dynamic> row(
  String id, {
  bool official = false,
  bool hidden = false,
}) => {
  'id': official ? 'official:$id' : id,
  'source': official ? 'official' : 'community',
  'name': id,
  'lat': 25.0,
  'lng': 121.5,
  'city': '臺北市',
  'space_type': 'paidMotorcycle',
  'status': hidden ? 'hidden' : 'confirmed',
  'hidden': hidden,
};

void main() {
  const taipei = MapViewport(
    south: 24.9,
    west: 121.3,
    north: 25.2,
    east: 121.7,
  );

  test('每個圖層最多 500 筆，多出的一筆只表示被截斷', () {
    final page = MapSpotPage.fromRows([
      for (var i = 0; i < 501; i++) row('c$i'),
      row('o', official: true),
      row('h', hidden: true),
    ]);
    expect(page.truncated, isTrue);
    expect(page.spots.length, 502);
    expect(page.spots.where((s) => s.hidden).single.spot.id, 'h');
    expect(MapSpotPage.fromRows([row('c')]).truncated, isFalse);
  });

  test('不認得的格位類型略過，不讓整張地圖失敗', () {
    final page = MapSpotPage.fromRows([
      {...row('x'), 'space_type': 'futureKind'},
      row('c'),
    ]);
    expect(page.spots.map((s) => s.spot.id), ['c']);
  });

  test('圖層關閉時立即移除該圖層的點，並以新的圖層重新查詢', () async {
    final gateway = FakeAdminGateway(access: adminAal2);
    final map = SpotMapController(gateway);
    await map.show(taipei);
    expect(map.shown.length, 2);
    map.toggle(SpotLayer.community);
    expect(map.shown.map((s) => s.id), [officialId]);
    await map.refresh();
    expect(gateway.mapRequests.last.$2, isFalse);
    map.toggle(SpotLayer.hidden);
    await map.refresh();
    expect(
      map.isHidden(map.shown.firstWhere((s) => s.id != officialId)),
      isTrue,
    );
    await gateway.dispose();
  });

  test('範圍太大時不查詢並提示放大', () async {
    final gateway = FakeAdminGateway(access: adminAal2);
    final map = SpotMapController(gateway);
    await map.show(
      const MapViewport(south: 24, west: 120, north: 25, east: 121),
    );
    expect(map.tooWide, isTrue);
    expect(gateway.mapRequests, isEmpty);
    await gateway.dispose();
  });

  test('登出後清除地圖資料', () async {
    final gateway = FakeAdminGateway(access: adminAal2);
    final map = SpotMapController(gateway);
    await map.show(taipei);
    map.reset();
    expect(map.spots, isEmpty);
    expect(map.viewport, isNull);
    await gateway.dispose();
  });

  test('開啟的點位以表單中的位置畫成選取標記；新點位沒有格位類型時為待確認', () {
    const record = SpotRecord(
      sourceId: officialId,
      values: {
        'name': '官方點',
        'lat': 25.0,
        'lng': 121.5,
        'city': '新北市',
        'space_type': 'offStreet',
        'heavy_allowed': true,
      },
    );
    final spot = selectedSpot(record, {'lat': 25.001, 'lng': 121.5}, null)!;
    expect(spot.id, officialId);
    expect(spot.isOfficial, isTrue);
    expect(spot.lat, 25.001);
    final fresh = selectedSpot(
      const SpotRecord.create(SpotKind.community, {'lat': 25.0, 'lng': 121.5}),
      {'lat': 25.0, 'lng': 121.5},
      null,
    )!;
    expect(
      eligibility(fresh, VehicleType.scooter, null).status,
      EligibilityStatus.unverified,
    );
  });
}

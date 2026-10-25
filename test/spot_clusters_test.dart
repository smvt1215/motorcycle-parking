import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/spot_clusters.dart';
import 'package:motorcycle_parking/models/parking.dart';

ParkingSpot point(String id, double lat, double lng) => ParkingSpot(
  id: id,
  name: id,
  lat: lat,
  lng: lng,
  city: '臺北市',
  spaceType: SpaceType.freeMotorcycle,
);
void main() {
  test('六個近點聚合、遠處單點不加入，放大後可分別選取', () {
    final near = [
      for (var i = 0; i < 6; i++) point('$i', 25.03 + i * .00002, 121.56),
    ];
    final far = point('far', 25.04, 121.57);
    final groups = clusterSpots([...near, far], 16);
    expect(groups.map((g) => g.spots.length), [6, 1]);
    expect(groups.first.center.latitude, closeTo(25.03005, .000001));
    expect(clusterSpots([...near, far], 20), hasLength(7));
    expect(
      clusterSpots([...near.reversed, far], 16).first.spots.map((s) => s.id),
      near.map((s) => s.id),
    );
  });
  test('鄰近點位至少五個才顯示群聚，稀疏點位保留各自位置', () {
    for (final count in [1, 2, 3, 4, 5]) {
      final spots = [
        for (var i = 0; i < count; i++) point('$i', 25.03 + i * .00002, 121.56),
      ];
      final groups = clusterSpots(spots, 16);
      expect(groups.length, count < 5 ? count : 1);
      expect(groups.expand((g) => g.spots).toSet(), spots.toSet());
      if (count < 5) {
        for (final group in groups) {
          expect(group.center.latitude, group.spots.single.lat);
          expect(group.center.longitude, group.spots.single.lng);
        }
      }
    }
    final spread = [
      for (var i = 0; i < 10; i++) point('$i', 25.03 + i * .01, 121.56),
    ];
    expect(clusterSpots(spread, 16), hasLength(10));
  });
  test('格線兩側的密集點仍聚合，空資料不產生群聚', () {
    expect(clusterSpots([], 16), isEmpty);
    for (var i = 0; i < 100; i++) {
      final lng = 121.56 + i * .0001;
      expect(
        clusterSpots([
          for (var j = 0; j < 5; j++) point('$j', 25.03, lng + j * .00001),
        ], 16),
        hasLength(1),
      );
    }
  });
}

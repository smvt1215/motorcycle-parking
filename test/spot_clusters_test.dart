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
  test('格線兩側近點仍聚合，空資料不產生群聚', () {
    expect(clusterSpots([], 16), isEmpty);
    for (var i = 0; i < 100; i++) {
      final lng = 121.56 + i * .0001;
      expect(
        clusterSpots([
          point('a', 25.03, lng),
          point('b', 25.03, lng + .00001),
        ], 16),
        hasLength(1),
      );
    }
  });
}

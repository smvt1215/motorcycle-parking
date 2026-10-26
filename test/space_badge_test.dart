import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/models/parking.dart';

void main() {
  ParkingSpot spot(
    SpaceType type, {
    ParkingAccess? access,
    bool? scooter,
    bool? heavy,
  }) => ParkingSpot(
    id: 'test',
    name: 'test',
    lat: 25,
    lng: 121,
    city: '臺北市',
    spaceType: type,
    access: access,
    scooterAllowed: scooter,
    heavyAllowed: heavy,
  );

  test('汽車格、重機專用格與普大共用格各有角落圖示', () {
    expect(spaceBadge(spot(SpaceType.car)), SpaceBadge.car);
    expect(
      spaceBadge(
        spot(SpaceType.paidMotorcycle, access: ParkingAccess.heavyCar),
      ),
      SpaceBadge.car,
    );
    expect(spaceBadge(spot(SpaceType.heavyOnly)), SpaceBadge.heavyOnly);
    expect(
      spaceBadge(spot(SpaceType.offStreet, access: ParkingAccess.heavyOnly)),
      SpaceBadge.heavyOnly,
    );
    expect(
      spaceBadge(spot(SpaceType.paidMotorcycle, scooter: true, heavy: true)),
      SpaceBadge.shared,
    );
    // A car-and-motorcycle flex bay admitting both is not a 共 bay.
    expect(
      spaceBadge(spot(SpaceType.flexShared, scooter: true, heavy: true)),
      isNull,
    );
    // Ordinary scooter bays carry no badge.
    expect(spaceBadge(spot(SpaceType.paidMotorcycle)), isNull);
    expect(
      spaceBadge(spot(SpaceType.freeMotorcycle, scooter: true, heavy: false)),
      isNull,
    );
  });
}

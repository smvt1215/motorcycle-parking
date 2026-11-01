import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

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
    // A car-and-motorcycle flex bay is its own square, never 普大共用.
    expect(
      spaceBadge(spot(SpaceType.flexShared, scooter: true, heavy: true)),
      SpaceBadge.carMotorcycle,
    );
    // Ordinary scooter bays carry no badge.
    expect(spaceBadge(spot(SpaceType.paidMotorcycle)), isNull);
    expect(
      spaceBadge(spot(SpaceType.freeMotorcycle, scooter: true, heavy: false)),
      isNull,
    );
  });

  test('徽章依格位 7 類推出：一般機車格（含限時）不掛，充電格新增', () {
    expect(spaceBadge(spot(SpaceType.evMotorcycle)), SpaceBadge.ev);
    expect(spaceBadge(spot(SpaceType.disabledMotorcycle)), SpaceBadge.disabled);
    expect(spaceBadge(spot(SpaceType.timedMotorcycle)), isNull);
    expect(spaceBadge(spot(SpaceType.freeMotorcycle)), isNull);
    expect(spaceBadge(spot(SpaceType.offStreet)), isNull);
  });

  test('白圓＝專用，方形＝共用；改名身障格', () {
    expect(
      [
        for (final b in SpaceBadge.values)
          if (b.square) b,
      ],
      [SpaceBadge.shared, SpaceBadge.carMotorcycle],
    );
    expect(spaceBadgeAccent(SpaceBadge.shared), const Color(0xfff2c200));
    expect(spaceBadgeAccent(SpaceBadge.carMotorcycle), const Color(0xff6aaad6));
    expect(spaceBadgeLabel(SpaceBadge.disabled), '身障格');
    expect(spaceBadgeIcon(SpaceBadge.ev), Icons.ev_station);
  });
}

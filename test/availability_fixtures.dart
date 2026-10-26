import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';

/// The pinned clock for availability tests: 17:05 local.
final availabilityNow = DateTime(2026, 10, 26, 17, 5);

/// Spots as given, whatever the viewport, in place of the example data.
class FixedParking extends ParkingRepository {
  FixedParking(this.fixed) : super(null);
  final List<ParkingSpot> fixed;
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) async =>
      ParkingResult(fixed.where((s) => bounds.contains(s.lat, s.lng)).toList());
}

const _lat = 25.0339, _lng = 121.5623;

/// A lot placed [dx], [dy] pixels from the map centre at zoom 16.
ParkingSpot lotAt(
  String id,
  double dx,
  double dy, {
  bool? scooter = true,
  bool? heavy,
  SpaceType type = SpaceType.offStreet,
  String source = 'official',
  ParkingAccess? access,
}) => ParkingSpot(
  id: id,
  name: '測試停車場 $id',
  lat: _lat - dy * 1.95e-5,
  lng: _lng + dx * 2.15e-5,
  city: '臺北市',
  district: '信義區',
  spaceType: type,
  facilityType: FacilityType.underground,
  source: source,
  status: TrustStatus.confirmed,
  scooterAllowed: scooter,
  heavyAllowed: heavy,
  scooterTotal: 80,
  access: access,
  updatedAt: DateTime(2026, 10, 20),
);

AvailabilitySnapshot count(
  String spot,
  AvailabilityVehicle vehicle, {
  int? total = 80,
  int? available = 12,
  int minutes = 3,
  bool suspended = false,
}) => AvailabilitySnapshot(
  spotId: spot,
  vehicle: vehicle,
  provider: '臺北市停管處',
  window: AvailabilityWindow.taipei,
  total: total,
  available: available,
  sourceUpdatedAt: availabilityNow.subtract(Duration(minutes: minutes)),
  fetchedAt: availabilityNow,
  suspended: suspended,
);

/// The canvas's map board (Main.dc.html): fresh, conditional, full,
/// delayed, unverified without a pill and not-allowed with a count.
final canvasSpots = [
  lotAt('fresh', 83 - 195, 255 - 422),
  lotAt('conditional', 231 - 195, 391 - 422, type: SpaceType.flexShared),
  lotAt('full', 145 - 195, 585 - 422),
  lotAt('delayed', 319 - 195, 457 - 422),
  lotAt('unverified', 59 - 195, 429 - 422, source: 'community'),
  lotAt('denied', 337 - 195 - 20, 615 - 422, scooter: false),
];

final canvasCounts = [
  count('fresh', AvailabilityVehicle.scooter),
  count('conditional', AvailabilityVehicle.scooter, available: 2),
  count('full', AvailabilityVehicle.scooter, available: 0),
  count('delayed', AvailabilityVehicle.scooter, available: 7, minutes: 14),
  // An unknown count: no pill, never 「已滿」.
  count('unverified', AvailabilityVehicle.scooter, available: -9),
  count('denied', AvailabilityVehicle.scooter, total: 40, available: 20),
];

Future<AppStore> availabilityStore(
  List<ParkingSpot> spots,
  List<AvailabilitySnapshot> counts, {
  bool enabled = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: FixedParking(spots),
    availabilitySource: enabled
        ? FakeAvailabilitySource(() => counts)
        : const NoAvailabilitySource(),
    clock: () => availabilityNow,
  );
  await store.init();
  return store;
}

/// The canvas's empty-result board (FilterEmpty.dc.html), heavy bikes: two
/// lots without heavy counts, one with space but closed to heavy bikes and
/// one delayed. None is 「目前有位」.
final emptySpots = [
  lotAt('e-nodata1', -112, -167, heavy: true),
  lotAt('e-nodata2', 36, -31, heavy: true),
  lotAt('e-denied', 142, 193, heavy: false),
  lotAt('e-delayed', -50, 163, heavy: true),
];

final emptyCounts = [
  count('e-nodata1', AvailabilityVehicle.scooter),
  count('e-nodata2', AvailabilityVehicle.heavy, available: -9),
  count('e-denied', AvailabilityVehicle.heavy, total: 10, available: 4),
  count(
    'e-delayed',
    AvailabilityVehicle.heavy,
    total: 10,
    available: 2,
    minutes: 14,
  ),
];

/// The MapDensity board, heavy bikes: a row of five lots 70px apart and a
/// column of four 60px apart, each with a heavy count and car bays.
final denseSpots = [
  for (var i = 0; i < 5; i++)
    lotAt(
      'row$i',
      49.0 + 70 * i - 195,
      249 - 422,
      heavy: true,
      access: ParkingAccess.heavyCar,
    ),
  for (var i = 0; i < 4; i++)
    lotAt(
      'col$i',
      189 - 195,
      459.0 + 60 * i - 422,
      heavy: true,
      access: ParkingAccess.heavyCar,
    ),
];

final denseCounts = [
  for (final spot in denseSpots) ...[
    count(spot.id, AvailabilityVehicle.heavy, total: 12, available: 3),
    count(spot.id, AvailabilityVehicle.car, total: 100, available: 30),
  ],
];

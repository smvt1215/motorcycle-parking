import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/models/closure.dart';
import 'package:motorcycle_parking/models/parking.dart';

/// Works or a closure (#116) override the verdict while they hold, so the
/// map markers, ranking and details agree with the closure card.
void main() {
  final now = DateTime.utc(2026, 10, 27, 4);
  ParkingSpot spot(SpotClosure? closure) => ParkingSpot(
    id: 'official:x',
    name: '測試',
    lat: 25.03,
    lng: 121.56,
    city: '臺北市',
    source: 'official',
    spaceType: SpaceType.paidMotorcycle,
    scooterAllowed: true,
    closure: closure,
  );

  test('生效中的封閉判為不可停，到期後恢復原判斷', () {
    final open = decideParking(
      spot(null),
      VehicleType.scooter,
      const [],
      now: now,
    );
    expect(open.status, isNot(EligibilityStatus.notAllowed));
    final active = decideParking(
      spot(
        SpotClosure(
          reason: ClosureReason.works,
          since: DateTime(2026, 10, 26),
          until: DateTime(2026, 11, 30),
        ),
      ),
      VehicleType.scooter,
      const [],
      now: now,
    );
    expect(active.status, EligibilityStatus.notAllowed);
    expect(active.reason, '施工中，暫時不能停');
    final expired = decideParking(
      spot(
        SpotClosure(
          reason: ClosureReason.closed,
          since: DateTime(2026, 10, 1),
          state: ClosureState.expired,
        ),
      ),
      VehicleType.scooter,
      const [],
      now: now,
    );
    expect(expired.status, open.status);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/parking_access_view.dart';
import 'package:motorcycle_parking/features/map/spot_fees.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

ParkingSpot point({
  ParkingAccess? access,
  List<ParkingZone> zones = const [],
  bool facility = false,
}) => ParkingSpot(
  id: 'access',
  name: '車種資料',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: facility ? SpaceType.offStreet : SpaceType.freeMotorcycle,
  access: access,
  scooterAllowed: true,
  heavyAllowed: true,
  zones: zones,
);
void main() {
  test('共用格不同車種費率在點位序列化往返後完整保留，舊資料不產生費率', () {
    final original = point(
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
  testWidgets('共用車格保持共用圖示，普通與大型重機各自顯示不同費率與單位', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _AccessAndFees(
            spot: point(
              zones: const [
                ParkingZone(
                  name: '共用車格',
                  access: ParkingAccess.scooterHeavy,
                  scooterFeeNote: '20 元／次',
                  heavyFeeNote: '30 元／小時',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    // Rates are on the fee board, each beside its own vehicle.
    expect(legacyRow(t, '普通機車'), '20 元／次');
    expect(legacyRow(t, '大型重機'), '30 元／小時');
  });
  testWidgets('只有普通機車費率時，大型重機標示未確認，不套用共同備註價格', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _AccessAndFees(
            spot: point(
              zones: const [
                ParkingZone(
                  name: '共用車格',
                  access: ParkingAccess.scooterHeavy,
                  scooterFeeNote: '20 元／次',
                  feeNote: '每日上限 150 元',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(legacyRow(t, '普通機車'), '20 元／次');
    expect(legacyRow(t, '大型重機'), contains('費率未確認'));
    expect(find.text('20 元／次'), findsOneWidget);
    expect(find.text('每日上限 150 元'), findsOneWidget);
  });

  testWidgets('專用以單一車種呈現，共用格明確連接兩個車種圖示', (t) async {
    for (final access in [
      ParkingAccess.scooterOnly,
      ParkingAccess.heavyOnly,
      ParkingAccess.scooterHeavy,
      ParkingAccess.heavyCar,
    ]) {
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ParkingAccessView(spot: point(access: access)),
          ),
        ),
      );
      final shared =
          access == ParkingAccess.scooterHeavy ||
          access == ParkingAccess.heavyCar;
      expect(
        find.byIcon(Icons.swap_horiz),
        shared ? findsOneWidget : findsNothing,
      );
      expect(
        find.byIcon(Icons.moped_outlined),
        access == ParkingAccess.scooterOnly ||
                access == ParkingAccess.scooterHeavy
            ? findsOneWidget
            : findsNothing,
      );
      expect(
        find.byIcon(Icons.two_wheeler),
        access == ParkingAccess.scooterOnly ? findsNothing : findsOneWidget,
      );
      expect(
        find.byIcon(Icons.directions_car_outlined),
        access == ParkingAccess.heavyCar ? findsOneWidget : findsNothing,
      );
      expect(t.takeException(), isNull);
    }
  });
  testWidgets('兩種機車皆可進場仍保留格位未確認，不顯示共用連接符號', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ParkingAccessView(spot: point(facility: true))),
      ),
    );
    expect(find.text('格位配置未確認'), findsOneWidget);
    expect(find.byIcon(Icons.swap_horiz), findsNothing);
    expect(find.text('可停'), findsNWidgets(2));
    expect(find.text('共用'), findsNothing);
  });
  testWidgets('分區分別保留車種、費率與指引，未知分區不繼承其他區的車種', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(320, 900);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: _AccessAndFees(
                spot: point(
                  facility: true,
                  zones: const [
                    ParkingZone(
                      name: '機車區',
                      access: ParkingAccess.scooterOnly,
                      feeNote: '20 元／次',
                      guide: 'B1',
                    ),
                    ParkingZone(
                      name: '重機與汽車區',
                      access: ParkingAccess.heavyCar,
                      feeNote: '30 元／時',
                      guide: 'B2',
                    ),
                    ParkingZone(name: '未確認區'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Each zone's name heads its access and its fee board.
    expect(find.text('機車區'), findsNWidgets(2));
    expect(find.text('重機與汽車區'), findsNWidgets(2));
    expect(find.text('20 元／次'), findsOneWidget);
    expect(find.text('30 元／時'), findsOneWidget);
    expect(find.text('指引：B2'), findsOneWidget);
    expect(find.text('未確認'), findsNWidgets(2));
    expect(find.byIcon(Icons.swap_horiz), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

/// The details' access list with the fee section, as the sheet shows them.
class _AccessAndFees extends StatelessWidget {
  const _AccessAndFees({required this.spot});
  final ParkingSpot spot;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ParkingAccessView(spot: spot),
      const SizedBox(height: 16),
      SpotFees(spot: spot, vehicle: VehicleType.scooter),
    ],
  );
}

/// The text beside [vehicle] on a text fee board.
String legacyRow(WidgetTester t, String vehicle) {
  final row = find
      .ancestor(
        of: find.descendant(
          of: find.byKey(const ValueKey('fee-legacy-board')),
          matching: find.text(vehicle),
        ),
        matching: find.byType(Row),
      )
      .first;
  return t
      .widgetList<Text>(find.descendant(of: row, matching: find.byType(Text)))
      .map((w) => w.data ?? w.textSpan!.toPlainText())
      .last;
}

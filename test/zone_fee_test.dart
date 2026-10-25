import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/features/map/parking_access_view.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

ParkingSpot lot({Fee? fee, List<ParkingZone> zones = const []}) => ParkingSpot(
  id: 'zone-fees',
  name: '分區費率停車場',
  lat: 25.03,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.offStreet,
  fee: fee,
  zones: zones,
  feeNote: '舊文字',
);

void main() {
  test('點位和分區結構化費率隨收藏完整往返，舊字串保持原值', () {
    final original = lot(
      fee: const Fee(scooter: Rate(FeeMode.daily, amount: 30)),
      zones: const [
        ParkingZone(
          name: 'B2',
          access: ParkingAccess.scooterHeavy,
          scooterFeeNote: '舊普機文字',
          heavyFeeNote: '舊重機文字',
          carFeeNote: '汽車原文',
          fee: Fee(
            scooter: Rate(FeeMode.free),
            heavy: Rate(
              FeeMode.hourly,
              amount: 20,
              perMinutes: 30,
              dailyCap: 100,
            ),
          ),
        ),
      ],
    );
    final restored = ParkingSpot.fromJson(original.toJson());
    expect(restored.fee, original.fee);
    expect(restored.zones.single.fee, original.zones.single.fee);
    expect(restored.zones.single.scooterFeeNote, '舊普機文字');
    expect(restored.zones.single.carFeeNote, '汽車原文');
    final legacy = ParkingSpot.fromJson({
      ...original.toJson(),
      'fee': null,
      'parking_zones': [
        {'name': '舊區', 'fee_note': '免費'},
      ],
    });
    expect(legacy.fee, isNull);
    expect(legacy.toJson().containsKey('fee'), isFalse);
    expect(legacy.zones.single.toJson(), {'name': '舊區', 'fee_note': '免費'});
  });

  test('明確的空費率保持未確認，不退回舊文字並隨收藏保留', () {
    final spot = ParkingSpot.fromJson({
      ...lot().toJson(),
      'fee': <String, Object>{},
      'parking_zones': [
        {
          'name': 'B2',
          'fee': <String, Object>{},
          'fee_note': '每日 20 元',
          'heavy_fee_note': '舊重機免費',
        },
      ],
    });
    expect(spot.fee, const Fee());
    expect(spot.zones.single.fee, const Fee());
    expect(spotFeeSummary(spot, VehicleType.heavy), '費率未確認');
    expect(spot.zones.single.heavyFeeText, '');
    expect(spot.toJson()['fee'], <String, Object>{});
    expect(
      (spot.toJson()['parking_zones'] as List).single['fee'],
      <String, Object>{},
    );
    expect(spotFeeSummary(lot(fee: const Fee()), VehicleType.scooter), '費率未確認');
  });

  test('單一分區顯示實際費率，多分區逐區計費，未知車種不繼承其他費率', () {
    const partial = ParkingZone(
      name: 'B2',
      access: ParkingAccess.scooterHeavy,
      heavyFeeNote: '舊重機每日 50 元',
      fee: Fee(scooter: Rate(FeeMode.free)),
    );
    expect(spotFeeSummary(lot(zones: [partial]), VehicleType.scooter), '免費');
    expect(
      spotFeeSummary(
        lot(
          fee: const Fee(heavy: Rate(FeeMode.daily, amount: 90)),
          zones: [partial],
        ),
        VehicleType.heavy,
      ),
      '費率未確認',
    );
    expect(partial.heavyFeeText, '');
    expect(
      spotFeeSummary(
        lot(
          zones: [
            partial,
            const ParkingZone(name: '1F', feeNote: '每次 30 元'),
          ],
        ),
        VehicleType.scooter,
      ),
      '依分區計費',
    );
    expect(
      spotFeeSummary(
        lot(
          zones: const [ParkingZone(name: '舊區', feeNote: '免費')],
        ),
        VehicleType.heavy,
      ),
      '免費',
    );
    expect(
      spotFeeSummary(
        lot(fee: const Fee(heavy: Rate(FeeMode.sameAsCar))),
        VehicleType.heavy,
      ),
      '比照汽車費率',
    );
    expect(
      spotFeeSummary(
        lot(fee: const Fee(heavy: Rate(FeeMode.sameAsCar))),
        VehicleType.scooter,
      ),
      '費率未確認',
    );
  });

  for (final width in [390.0, 700.0]) {
    testWidgets('分區費率在寬 $width、深色放大字級下完整顯示', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ParkingAccessView(
                  spot: lot(
                    zones: const [
                      ParkingZone(
                        name: 'B2',
                        access: ParkingAccess.scooterHeavy,
                        feeNote: '不應重複的舊費率',
                        fee: Fee(
                          scooter: Rate(FeeMode.free),
                          heavy: Rate(
                            FeeMode.hourly,
                            amount: 20,
                            perMinutes: 30,
                            dailyCap: 100,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('普通機車：免費'), findsOneWidget);
      expect(find.text('大型重機：每 30 分鐘 20 元，當日上限 100 元'), findsOneWidget);
      expect(find.textContaining('不應重複'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('分區編輯器驗證金額並把各車種費率保存在該區', (tester) async {
    final zone = ZoneDraft()..name.text = 'B2';
    addTearDown(zone.dispose);
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: form,
            child: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => ZoneEditor(
                  zones: [zone],
                  onAdd: () {},
                  onRemove: (_) {},
                  onChanged: () => setState(() {}),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('fee-mode-heavy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('fee-mode-heavy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('計時').last);
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, '金額'), '25');
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isTrue);
    expect(zone.toJson(), {
      'name': 'B2',
      'fee': {
        'heavy': {'mode': 'hourly', 'amount': 25, 'per_minutes': 60},
      },
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

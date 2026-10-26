import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/features/map/parking_access_view.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'fee_editor_steps.dart';

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
    // A spot's fee = {} holds no structured rate (#114) and reads as none;
    // a zone's explicit empty fee still keeps its legacy strings out.
    expect(spot.fee, isNull);
    expect(spot.zones.single.fee, const Fee());
    expect(spotFeeSummary(spot, VehicleType.heavy), '費率未確認');
    expect(spot.zones.single.heavyFeeText, '');
    expect(spot.toJson()['fee'], isNull);
    expect(
      (spot.toJson()['parking_zones'] as List).single['fee'],
      <String, Object>{},
    );
    expect(spotFeeSummary(lot(fee: const Fee()), VehicleType.scooter), '費率未確認');
  });

  test('點位有結構化費率而分區只有舊文字時，以點位費率為準', () {
    const fee = Fee(scooter: Rate(FeeMode.free));
    const legacy = ParkingZone(name: 'B2', feeNote: '舊：每次 10 元');
    final single = lot(fee: fee, zones: [legacy]);
    expect(spotFeeSummary(single, VehicleType.scooter), '免費');
    expect(spotFeeSummary(single, VehicleType.heavy), '費率未確認');
    expect(spotFeeIsVehicleRate(single), isTrue);
    expect(lotWideFee(single), fee);
    final multi = lot(fee: fee, zones: [legacy, legacy]);
    expect(spotFeeSummary(multi, VehicleType.scooter), '免費');
    // A zone's own structured rate still wins over the lot's.
    const own = ParkingZone(name: 'B1', fee: Fee());
    expect(lotWideFee(lot(fee: fee, zones: [own, legacy])), isNull);
    expect(
      spotFeeSummary(lot(fee: fee, zones: [own]), VehicleType.scooter),
      '費率未確認',
    );
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
      '費率未提供',
    );
    // A follow shows the amounts it works out to (#140).
    expect(
      spotFeeSummary(
        lot(
          fee: const Fee(
            scooter: Rate(FeeMode.hourly, amount: 20, perMinutes: 60),
            heavy: Rate(FeeMode.sameAsScooter, factorPct: 200),
          ),
        ),
        VehicleType.heavy,
      ),
      '每小時 40 元',
    );
    expect(
      spotFeeSummary(
        lot(fee: const Fee(heavy: Rate(FeeMode.sameAsCar))),
        VehicleType.scooter,
      ),
      '費率未確認',
    );
  });

  for (final width in [320.0, 360.0, 390.0, 700.0, 1280.0]) {
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
      expect(
        find.text('大型重機：每 30 分鐘 20 元，當日上限 100 元（上限計算方式未確認）'),
        findsOneWidget,
      );
      expect(find.textContaining('不應重複'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> pumpAccess(WidgetTester tester, double width, ParkingSpot spot) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1100);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ParkingAccessView(spot: spot),
            ),
          ),
        ),
      ),
    );
  }

  for (final width in [320.0, 390.0]) {
    testWidgets('寬 $width：部分分區有費率時逐區顯示，沒有 fee 的分區照舊文字', (tester) async {
      final spot = lot(
        fee: const Fee(scooter: Rate(FeeMode.perVisit, amount: 20)),
        zones: const [
          ParkingZone(
            name: 'B1',
            access: ParkingAccess.scooterOnly,
            fee: Fee(scooter: Rate(FeeMode.free)),
          ),
          ParkingZone(
            name: 'B2',
            access: ParkingAccess.scooterOnly,
            feeNote: '舊 B2 每次 10 元',
          ),
        ],
      );
      expect(spotFeeSummary(spot, VehicleType.scooter), '依分區計費');
      await pumpAccess(tester, width, spot);
      expect(find.text('全場費率'), findsNothing);
      expect(find.text('普通機車：免費'), findsOneWidget);
      expect(find.text('費率：舊 B2 每次 10 元'), findsOneWidget);
      expect(find.textContaining('每次 20 元'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('寬 $width：全場費率模式仍顯示分區的汽車費率', (tester) async {
      final spot = lot(
        fee: const Fee(heavy: Rate(FeeMode.sameAsCar)),
        zones: const [
          ParkingZone(
            name: '1F',
            access: ParkingAccess.heavyCar,
            heavyFeeNote: '舊重機費率',
            carFeeNote: '每小時 30 元',
          ),
        ],
      );
      await pumpAccess(tester, width, spot);
      expect(find.text('全場費率'), findsOneWidget);
      expect(find.text('汽車：每小時 30 元'), findsOneWidget);
      // 比照 resolves within the same fee only (design §2.1); the car rate
      // here is legacy zone text, so the heavy rate is not provided (#140).
      expect(find.text('大型重機：費率未提供'), findsNWidgets(2));
      expect(find.textContaining('舊重機'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width：詳情費率句子寫算好的金額與汽車費率，不寫比照（#140）', (tester) async {
      final spot = lot(
        fee: const Fee(
          scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60),
          heavy: Rate(FeeMode.sameAsScooter, factorPct: 200),
          car: Rate(FeeMode.hourly, amount: 40, perMinutes: 60),
        ),
        zones: const [
          ParkingZone(name: '機車區', access: ParkingAccess.scooterHeavy),
        ],
      );
      expect(spotFeeSummary(spot, VehicleType.heavy), '每小時 20 元');
      await pumpAccess(tester, width, spot);
      // The lot's rates, repeated beside the zone's vehicles.
      expect(find.text('大型重機：每小時 20 元'), findsWidgets);
      // The lot's car rate is listed once, not again in every zone.
      expect(find.text('汽車：每小時 40 元'), findsOneWidget);
      expect(find.textContaining('比照'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 360.0, 390.0, 1280.0]) {
    testWidgets('分區編輯器在寬 $width 驗證金額並把各車種費率保存在該區', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      await chooseFeeMode(tester, 'heavy', 'hourly');
      expect(form.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      await tester.enterText(feeField('amount', 'heavy'), '25');
      await tester.pumpAndSettle();
      expect(form.currentState!.validate(), isTrue);
      expect(zone.toJson(), {
        'name': 'B2',
        'fee': {
          'heavy': {'mode': 'hourly', 'amount': 25, 'per_minutes': 60},
        },
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

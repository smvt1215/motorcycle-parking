import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/features/map/spot_photos.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

ParkingSpot facility({int? available, List<String> photos = const []}) =>
    ParkingSpot(
      id: 'detail-facility',
      name: '測試地下停車場',
      lat: 25.08,
      lng: 121.56,
      city: '臺北市',
      district: '內湖區',
      spaceType: SpaceType.offStreet,
      facilityType: FacilityType.underground,
      source: 'official',
      status: TrustStatus.confirmed,
      scooterAllowed: true,
      heavyAllowed: false,
      feeNote: '平日與假日依各區費率計收',
      address: '測試路 18 號',
      entranceNote: '機車入口位於巷內，汽車入口位於正門',
      parkingGuide: '進場後循機車區標示停放',
      specialRules: '限停指定格位；夜間請使用側門',
      note: '此為測試資料',
      photoUrls: photos,
      available: available,
      scooterTotal: 20,
      updatedAt: DateTime.utc(2026, 10, 12, 1),
      zones: const [
        ParkingZone(
          name: '機車區',
          access: ParkingAccess.scooterOnly,
          feeNote: '20 元／次',
          guide: '位於 B1',
        ),
        ParkingZone(name: '另一區'),
      ],
    );

const roadside = ParkingSpot(
  id: 'detail-road',
  name: '測試路邊共用格',
  lat: 25.08,
  lng: 121.56,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  scooterAllowed: true,
  heavyAllowed: true,
  available: 7,
  roadSegment: '測試路：甲路口至乙路口，北側',
);

Finder get detailScroll => find
    .descendant(
      of: find.byKey(const ValueKey('parking-spot-sheet')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> openDetails(
  WidgetTester tester,
  AppStore store,
  ParkingSpot spot, {
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpot(context, store, spot),
            child: const Text('開啟詳情'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟詳情'));
  await tester.pumpAndSettle();
  await tester.drag(
    find.byKey(const ValueKey('parking-spot-sheet')),
    const Offset(0, -500),
  );
  await tester.pumpAndSettle();
}

Future<AppStore> createStore() async {
  SharedPreferences.setMockInitialValues({});
  return AppStore(LocalRepository(await SharedPreferences.getInstance()), null);
}

void usePhone(WidgetTester tester, {double width = 390}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> showField(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    160,
    scrollable: detailScroll,
  );
  await tester.pumpAndSettle();
  expect(find.text(text), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  test('收藏重新讀取後保留場地、分區、入口與照片等新增資料', () async {
    final store = await createStore();
    addTearDown(store.dispose);
    final spot = facility(photos: ['https://photos.invalid/entry.jpg']);
    await store.local.setFavorites('guest', [spot]);
    final saved = store.local.favorites('guest').single;
    expect(saved.facilityType, FacilityType.underground);
    expect(saved.address, '測試路 18 號');
    expect(saved.entranceNote, contains('巷內'));
    expect(saved.specialRules, contains('夜間'));
    expect(saved.photoUrls, ['https://photos.invalid/entry.jpg']);
    expect(saved.zones.first.access, ParkingAccess.scooterOnly);
    expect(saved.zones.first.guide, '位於 B1');
    expect(saved.zones.last.access, isNull);
  });

  test('舊資料不增加空白新欄位，未知場地代碼維持未提供', () {
    final json = roadside.toJson();
    expect(json.containsKey('facility_type'), isFalse);
    expect(json.containsKey('parking_zones'), isFalse);
    final unknown = ParkingSpot.fromJson({
      ...json,
      'space_type': 'offStreet',
      'facility_type': 'future-type',
      'parking_access': 'future-access',
    });
    expect(facilitySummary(unknown), '路外停車場（型式未提供）');
    expect(reportedAccess(unknown), isNull);
    expect(accessSummary(unknown), contains('格位配置未確認'));
  });

  test('停車場兩種車種皆可停不推定共用格，路邊明確共用可分類', () {
    final both = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'space_type': 'offStreet',
    });
    expect(reportedAccess(both), isNull);
    expect(reportedAccess(roadside), ParkingAccess.scooterHeavy);
  });

  test('舊 TDX 停車場回應保留車位時間，新時間優先且不套用其他來源', () {
    final liveTime = DateTime.utc(2026, 10, 12, 1);
    final explicitTime = liveTime.add(const Duration(minutes: 1));
    final payload = {
      ...facility(available: 0).toJson(),
      'id': 'tdx:Taipei:park:TEST',
      'source': 'tdx',
      'updated_at': liveTime.toIso8601String(),
    };
    final legacy = ParkingSpot.fromJson(payload);
    expect(availabilitySummary(legacy), contains(formatSpotTime(liveTime)));
    expect(availabilitySummary(legacy), contains('機車剩餘 0 格'));
    final explicit = ParkingSpot.fromJson({
      ...payload,
      'availability_updated_at': explicitTime.toIso8601String(),
    });
    expect(
      availabilitySummary(explicit),
      contains(formatSpotTime(explicitTime)),
    );
    for (final source in ['official', 'community', 'import']) {
      final other = ParkingSpot.fromJson({...payload, 'source': source});
      expect(availabilitySummary(other), contains('車位資料時間未提供'));
    }
    final unknown = ParkingSpot.fromJson({...payload, 'available': null});
    expect(availabilitySummary(unknown), '暫無即時資訊');
    final untimed = ParkingSpot.fromJson({...payload, 'updated_at': null});
    expect(availabilitySummary(untimed), contains('車位資料時間未提供'));
  });

  testWidgets('停車場依四組顯示欄位、分區與未知車位，深色大字不溢出', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(
      tester,
      store,
      facility(),
      scale: 1.6,
      brightness: Brightness.dark,
    );
    expect(find.text('測試地下停車場'), findsOneWidget);
    for (final field in [
      '基本資訊',
      '類型',
      '費率',
      '停放車種',
      '位置與停放',
      '入口',
      '停車指引',
      '位置',
      '特殊規則',
      '現場補充',
      '照片',
      '備註',
      '資料資訊',
      '資料來源',
      '查核狀態',
      '更新時間',
      '即時車位狀態',
    ]) {
      await showField(tester, field);
    }
    expect(find.text('暫無即時資訊'), findsOneWidget);
    expect(find.textContaining('機車剩餘'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('路邊格有殘留車位數也隱藏即時欄與入口，保留路段指引', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, roadside);
    await showField(tester, '位置與停放');
    expect(find.text('入口'), findsNothing);
    expect(find.textContaining('測試路：甲路口'), findsOneWidget);
    await showField(tester, '資料資訊');
    expect(find.text('即時車位狀態'), findsNothing);
    expect(find.textContaining('機車剩餘'), findsNothing);
    expect(find.text('更新時間'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停車場零格顯示零而非未知，點位時間不冒充車位資料時間', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, facility(available: 0));
    await showField(tester, '即時車位狀態');
    expect(find.textContaining('機車剩餘 0 格 / 20 格'), findsOneWidget);
    expect(find.textContaining('車位資料時間未提供'), findsOneWidget);
    expect(find.text('暫無即時資訊'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('詳情開啟期間切換車種會即時重算資格提示', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, facility());
    expect(find.text('普通機車 · 可停'), findsOneWidget);
    await store.setVehicle(VehicleType.heavy);
    await tester.pumpAndSettle();
    expect(find.text('大型重機 · 不可停'), findsOneWidget);
    expect(find.text('普通機車 · 可停'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('照片可放大並關閉，失敗或無效連結有可讀提示', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SpotPhotos(urls: ['not-a-photo-url'])),
      ),
    );
    expect(find.text('照片連結無法使用'), findsOneWidget);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(
      tester,
      store,
      facility(photos: ['https://photos.invalid/entry.jpg']),
    );
    await tester.scrollUntilVisible(
      find.byTooltip('放大照片 1').hitTestable(),
      160,
      scrollable: detailScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('放大照片 1').hitTestable());
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('照片無法載入'), findsWidgets);
    await tester.tap(find.byTooltip('關閉照片'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
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
  test('官方保留政府來源，社群標示車友、管理員與匯入整理', () {
    ParkingSpot spot(
      String source, {
      String sourceName = '',
      String city = '新竹市',
      String contributorName = '',
      String contributorRole = '',
    }) => ParkingSpot(
      id: '$source-1',
      name: '測試點',
      lat: 24.8,
      lng: 120.97,
      city: city,
      spaceType: SpaceType.offStreet,
      source: source,
      sourceName: sourceName,
      contributorName: contributorName,
      contributorRole: contributorRole,
    );
    expect(spot('official', sourceName: '新竹市政府').isOfficial, isTrue);
    expect(spot('tdx').isOfficial, isTrue);
    expect(spot('import').isOfficial, isFalse);
    expect(spot('community').isOfficial, isFalse);
    expect(
      sourceSummary(spot('official', sourceName: '新竹市政府'), demo: false),
      '新竹市政府',
    );
    expect(sourceSummary(spot('official'), demo: false), '新竹市政府');
    expect(sourceSummary(spot('tdx'), demo: false), '新竹市政府');
    expect(sourceSummary(spot('tdx', city: ''), demo: false), '政府公開資料');
    expect(
      sourceSummary(spot('import', sourceName: '社群回報整理'), demo: false),
      '由管理員匯入整理',
    );
    expect(sourceSummary(spot('community'), demo: false), '由車友回報');
    expect(
      sourceSummary(
        spot('community', contributorName: '小哲', contributorRole: 'rider'),
        demo: false,
      ),
      '由車友 小哲 回報',
    );
    expect(
      sourceSummary(
        spot(
          'community',
          contributorName: 'rider@example.com',
          contributorRole: 'rider',
        ),
        demo: false,
      ),
      '由車友回報',
    );
    expect(
      sourceSummary(spot('community', contributorRole: 'admin'), demo: false),
      '由管理員新增',
    );
    expect(trustSummary(spot('import'), demo: false), '待確認');
  });

  testWidgets('社群移除來源與內部授權文字，官方僅提供固定授權首頁', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    for (final source in ['community', 'import', 'official', 'tdx']) {
      final spot = ParkingSpot.fromJson({
        ...facility().toJson(),
        'source': source,
        'source_url': 'https://example.com/community-map',
        'license_note': '整理自 Alan 停車地圖；未通過官方核驗',
      });
      await openDetails(tester, store, spot);
      await showField(tester, '資料與查核');
      await tester.drag(detailScroll, const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(
        find.text('查看政府資料授權'),
        spot.isOfficial ? findsOneWidget : findsNothing,
        reason: source,
      );
      if (spot.isOfficial) {
        final link = find.widgetWithText(TextButton, '查看政府資料授權');
        await tester.ensureVisible(link);
        await tester.pumpAndSettle();
        expect(link.hitTestable(), findsOneWidget, reason: source);
        expect(tester.getSize(link).height, greaterThanOrEqualTo(48));
      }
      expect(
        licenseLinkUri(spot),
        spot.isOfficial ? Uri.parse('https://data.gov.tw/license') : null,
      );
      expect(find.text('查看停車點資料來源'), findsNothing);
      expect(find.text('授權說明'), findsNothing);
      expect(find.textContaining('Alan'), findsNothing);
      expect(find.text('查核狀態'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

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

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width 的停車場深色大字，車位只在頂部顯示一次', (tester) async {
      usePhone(tester, width: width);
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
      expect(find.text('地下停車場 · 臺北市內湖區'), findsOneWidget);
      expect(find.text('尚無即時資料'), findsOneWidget);
      for (final field in [
        '停車資訊',
        '類型',
        '分區',
        '位置與指引',
        '入口',
        '停車指引',
        '位置',
        '特殊規則',
        '現場補充',
        '照片',
        '備註',
        '資料與查核',
        '資料來源',
        '更新時間',
      ]) {
        await showField(tester, field);
      }
      expect(find.text('查核狀態'), findsNothing);
      expect(find.text('即時車位狀態'), findsNothing);
      final navigate = find.text('導航到這裡');
      expect(navigate.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('路邊格有殘留車位數也隱藏即時欄與入口，保留路段指引', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, roadside);
    await showField(tester, '位置與指引');
    expect(find.text('入口'), findsNothing);
    expect(find.textContaining('測試路：甲路口'), findsOneWidget);
    await showField(tester, '資料與查核');
    expect(find.text('即時車位狀態'), findsNothing);
    expect(find.textContaining('機車剩餘'), findsNothing);
    expect(find.textContaining('更新時間'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('停車場零格顯示零而非未知，點位時間不冒充車位資料時間', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, facility(available: 0));
    expect(find.text('車位時間未提供'), findsOneWidget);
    expect(find.text('0 格 / 20 格'), findsOneWidget);
    await showField(tester, '資料與查核');
    expect(find.text('即時車位狀態'), findsNothing);
    expect(find.text('暫無即時資訊'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('未確認的匯入點保留查核狀態，已確認點不顯示', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final spot = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'import',
      'status': 'pending',
      'contributor_role': 'import',
    });
    await openDetails(tester, store, spot);
    await showField(tester, '查核狀態');
    expect(trustSummary(spot, demo: false), '待確認');
    expect(sourceSummary(spot, demo: false), '由管理員匯入整理');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('社群點已確認存在仍清楚提示車種開放待查核', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final spot = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'community',
      'scooter_allowed': true,
      'status': 'confirmed',
      'last_confirmed_at': DateTime.now().toIso8601String(),
    });
    expect(store.eligible(spot).status, EligibilityStatus.unverified);
    await openDetails(tester, store, spot);
    expect(find.text('普通機車 · 開放資訊待確認'), findsOneWidget);
    expect(find.text('已確認此停車點存在；目前車種是否開放仍待查核，請以入口公告為準。'), findsOneWidget);
    expect(store.eligible(spot).status, EligibilityStatus.unverified);
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

  testWidgets('詳情名稱保留完整寬度，收藏分享移到副標操作列', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    store
      ..lat = 25.077
      ..lng = 121.56
      ..located = true;
    await openDetails(tester, store, facility());
    final title = tester.getRect(find.text('測試地下停車場'));
    expect(title.height, lessThan(40));
    expect(title.width, greaterThan(240));
    expect(
      tester.getCenter(find.byTooltip('關閉詳情')).dy,
      closeTo(title.center.dy, 24),
    );
    for (final tooltip in ['收藏停車點', '分享停車點']) {
      expect(
        tester.getCenter(find.byTooltip(tooltip)).dy,
        greaterThan(title.bottom),
      );
    }
    expect(find.text('地下停車場 · 臺北市內湖區 · 330 公尺'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('捲到資料查核仍可直接導航或修改建議，空白指引省略', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, roadside);
    final action = tester.getRect(find.text('導航到這裡'));
    await showField(tester, '位置與指引');
    expect(find.textContaining('尚未提供：停車指引'), findsNothing);
    expect(find.text('停車指引'), findsNothing);
    expect(find.text('特殊規則'), findsNothing);
    await showField(tester, '資料與查核');
    expect(tester.getRect(find.text('導航到這裡')), action);
    expect(find.text('修改建議').hitTestable(), findsOneWidget);
    expect(find.text('未提供'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('橫向矮畫面加大字級時，操作列改放清單末端，標題不被擠掉', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 320);
    tester.view.padding = const FakeViewPadding(top: 24);
    addTearDown(tester.view.reset);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSpot(context, store, roadside),
              child: const Text('開啟詳情'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟詳情'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(roadside.name).hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('導航到這裡'),
      80,
      scrollable: detailScroll,
    );
    await tester.pumpAndSettle();
    expect(find.text('導航到這裡').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('共用格的摘要跟隨目前車種，缺少大型重機費率不沿用普通機車價格', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final spot = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'parking_zones': [
        {
          'name': '共用機車格',
          'access': 'scooterHeavy',
          'scooter_fee_note': '20 元／次',
        },
      ],
    });
    await openDetails(tester, store, spot);
    expect(find.text('普通機車費率'), findsOneWidget);
    expect(find.text('費率'), findsNothing);
    expect(find.text('分區'), findsOneWidget);
    expect(find.text('20 元／次'), findsOneWidget);
    store.vehicle = VehicleType.heavy;
    store.notifyListeners();
    await tester.pumpAndSettle();
    final summary = find
        .ancestor(of: find.text('大型重機費率'), matching: find.byType(Column))
        .first;
    expect(
      find.descendant(of: summary, matching: find.text('費率未確認')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: summary, matching: find.text('20 元／次')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width：只有一區的舊費率直接顯示免費，移除重複的零元說明', (tester) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      final spot = ParkingSpot.fromJson({
        ...facility().toJson(),
        'fee_note': '0',
        'parking_zones': [
          {'name': '機車區', 'access': 'scooterHeavy', 'fee_note': '免費'},
        ],
      });
      await openDetails(tester, store, spot);
      expect(find.text('免費'), findsOneWidget);
      expect(find.text('依分區計費'), findsNothing);
      await showField(tester, '位置與指引');
      expect(find.text('收費說明'), findsNothing);
      expect(find.text('0'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('照片可放大並關閉，失敗或無效連結有可讀提示', (tester) async {
    usePhone(tester);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SpotPhotos(
            urls: ['not-a-photo-url', 'http://photos.invalid/entry.jpg'],
          ),
        ),
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
    // Photos follow the parking and arrival information under 現場補充.
    await showField(tester, '現場補充');
    expect(find.byKey(const ValueKey('spot-photo-strip')), findsOneWidget);
    expect(find.text('尚無照片'), findsNothing);
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

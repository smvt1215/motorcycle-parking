import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/eligibility_display.dart';
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

/// The summary row's rate as it reads, its icon dropped.
String feeNowMain(WidgetTester tester) => tester
    .widget<Text>(
      find.byKey(const ValueKey('fee-now-main'), skipOffstage: false),
    )
    .textSpan!
    .toPlainText()
    .replaceAll('\uFFFC', '')
    .trim();

/// Scrolls the details until the widget keyed [key] is on screen.
Future<void> showKey(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(
    find.byKey(ValueKey(key)),
    160,
    scrollable: detailScroll,
  );
  await tester.pumpAndSettle();
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

/// The banner's vehicle and headline, as 「普通機車 · 可停」.
String decisionText(WidgetTester tester) {
  final texts = tester
      .widgetList<Text>(
        // The banner sits under the preview; it may be scrolled past.
        find.descendant(
          of: find.byKey(const ValueKey('spot-decision'), skipOffstage: false),
          matching: find.byType(Text, skipOffstage: false),
          skipOffstage: false,
        ),
      )
      .map((text) => text.data)
      .toList();
  return '${texts[0]} · ${texts[1]}';
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
      '由管理員自其他社群統整後匯入',
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

  test('多個場站型式：詳情寫「地下、平面停車場」，收藏保留，舊資料只有一個型式', () {
    final lot = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'space_type': 'offStreet',
      'facility_type': 'underground',
      'facility_types': ['surface', 'underground', 'future-type'],
    });
    // In the contract's order; unknown names left out.
    expect(lot.facilityTypes, [FacilityType.underground, FacilityType.surface]);
    expect(lot.facilityType, FacilityType.underground);
    expect(facilitySummary(lot), '地下、平面停車場');
    final saved = ParkingSpot.fromJson(lot.toJson());
    expect(saved.facilities, lot.facilities);
    final old = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'space_type': 'offStreet',
      'facility_type': 'multiStorey',
    });
    expect(old.facilities, [FacilityType.multiStorey]);
    expect(facilitySummary(old), '立體停車場');
    expect(
      facilityTypesLabel([FacilityType.surface, FacilityType.roadside]),
      '平面停車場、路邊停車格',
    );
  });

  test('停車場兩種車種皆可停不推定共用格，路邊明確共用可分類', () {
    final both = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'space_type': 'offStreet',
    });
    expect(reportedAccess(both), isNull);
    expect(reportedAccess(roadside), ParkingAccess.scooterHeavy);
  });

  test('汽機共用、身障與電動機車格兩種車種皆可停也不推定為普大共用', () {
    for (final type in [
      SpaceType.flexShared,
      SpaceType.disabledMotorcycle,
      SpaceType.evMotorcycle,
    ]) {
      final spot = ParkingSpot.fromJson({
        ...roadside.toJson(),
        'space_type': type.name,
      });
      expect(reportedAccess(spot), isNull, reason: type.name);
      expect(accessSummary(spot), isNot(contains('普大共用')), reason: type.name);
    }
    for (final type in [
      SpaceType.paidMotorcycle,
      SpaceType.freeMotorcycle,
      SpaceType.timedMotorcycle,
    ]) {
      final spot = ParkingSpot.fromJson({
        ...roadside.toJson(),
        'space_type': type.name,
      });
      expect(
        reportedAccess(spot),
        ParkingAccess.scooterHeavy,
        reason: type.name,
      );
    }
    // An explicit access value is the source's own statement and stays.
    final labelled = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'space_type': SpaceType.flexShared.name,
      'parking_access': ParkingAccess.scooterHeavy.name,
    });
    expect(reportedAccess(labelled), ParkingAccess.scooterHeavy);
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
      expect(find.text('地下停車場　臺北市內湖區'), findsOneWidget);
      // Once in the four signs' 有沒有位 plate, once in the summary.
      expect(find.text('空位未知', skipOffstage: false), findsNWidgets(2));
      await showField(tester, '共 20 格（靜態資料）');
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
        '最近更新',
      ]) {
        await showField(tester, field);
      }
      expect(find.text('查核狀態'), findsNothing);
      expect(find.text('即時車位狀態'), findsNothing);
      final navigate = find.text('導航到入口');
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
    expect(find.textContaining('最近更新'), findsOneWidget);
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

  for (final width in [320.0, 390.0]) {
    for (final status in ['pending', 'confirmed']) {
      testWidgets('寬 $width 的 $status 匯入點不顯示查核狀態', (tester) async {
        usePhone(tester, width: width);
        final store = (await tester.runAsync(createStore))!;
        addTearDown(store.dispose);
        final spot = ParkingSpot.fromJson({
          ...facility().toJson(),
          'source': 'import',
          'status': status,
          'contributor_role': 'import',
        });
        expect(sourceSummary(spot, demo: false), '由管理員自其他社群統整後匯入');
        await openDetails(tester, store, spot);
        await showField(tester, '最近更新');
        expect(find.text('資料來源'), findsOneWidget);
        expect(find.text('查核狀態'), findsNothing);
        expect(find.text('導航到入口').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('從收藏開啟的社群點不帶回報者名稱，資料來源顯示由車友回報', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final live = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'community',
      'contributor_name': '小哲',
      'contributor_role': 'rider',
    });
    expect(sourceSummary(live, demo: false), '由車友 小哲 回報');
    // Older builds saved the name; a favorite never shows it again.
    final saved = ParkingSpot.favorite({
      ...live.toJson(),
      'contributor_name': '小哲',
    }).single;
    expect(saved.contributorName, isEmpty);
    expect(sourceSummary(saved, demo: false), '由車友回報');
    await openDetails(tester, store, saved);
    await showField(tester, '資料來源');
    expect(find.textContaining('小哲'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('社群點已確認存在，車友回報可停仍只是未核實的回報', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final spot = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'community',
      'scooter_allowed': true,
      'status': 'confirmed',
      'last_confirmed_at': DateTime.now().toIso8601String(),
      'created_at': DateTime(2026, 3, 1, 9).toIso8601String(),
    });
    expect(store.eligible(spot).status, EligibilityStatus.unverified);
    await openDetails(tester, store, spot);
    expect(decisionText(tester), '普通機車 · 車友回報可停');
    expect(find.text('此處確實有停車點，可停放車種未經確認，請以入口公告為準。'), findsOneWidget);
    expect(find.text('回報於 2026-03-01'), findsOneWidget);
    // The banner keeps the unverified colour: a claim never reads as open.
    expect(find.byIcon(Icons.local_parking), findsNothing);
    expect(store.eligible(spot).status, EligibilityStatus.unverified);
    await showField(tester, '確認狀態');
    expect(find.text('尚未確認'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (width, scale, brightness) in [
    (320.0, 1.6, Brightness.dark),
    (390.0, 1.6, Brightness.light),
    (390.0, 1.0, Brightness.dark),
    (700.0, 1.0, Brightness.light),
    (1280.0, 1.6, Brightness.dark),
  ]) {
    testWidgets('資格分層橫幅不溢出（寬 $width、字級 $scale、$brightness）', (tester) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      final expired = DateTime.now().subtract(const Duration(days: 400));
      final spot = ParkingSpot.fromJson({
        ...facility().toJson(),
        'name': '很長很長的社群回報地下停車場名稱，用來測試換行與不溢出',
        'source': 'community',
        'scooter_allowed': true,
        'heavy_allowed': false,
        'status': 'pending',
        'created_at': DateTime(2026, 3, 1, 9).toIso8601String(),
        'heavy_verified_at': expired.toIso8601String(),
      });
      await openDetails(
        tester,
        store,
        spot,
        scale: scale,
        brightness: brightness,
      );
      await showKey(tester, 'spot-decision');
      expect(decisionText(tester), '普通機車 · 車友回報可停');
      expect(find.text('回報於 2026-03-01'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await store.setVehicle(VehicleType.heavy);
      await tester.pumpAndSettle();
      expect(decisionText(tester), '大型重機 · 曾確認不能停');
      // An administrator's lapsed check, not a rider's report: the question
      // mark stays, never the people icon.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('spot-decision')),
          matching: find.byIcon(Icons.groups_outlined),
        ),
        findsNothing,
      );
      expect(
        find.textContaining('管理員確認，${formatSpotDate(expired)}'),
        findsWidgets,
      );
      final banner = tester.getRect(
        find.byKey(const ValueKey('spot-decision')),
      );
      expect(banner.right, lessThanOrEqualTo(width));
      for (final key in ['spot-decision-label', 'spot-decision-basis']) {
        if (find.byKey(ValueKey(key)).evaluate().isEmpty) continue;
        expect(
          tester.getRect(find.byKey(ValueKey(key))).right,
          lessThanOrEqualTo(banner.right),
        );
      }
      expect(tester.takeException(), isNull);
      await showField(tester, '確認狀態');
      expect(
        find.textContaining(
          '停放車種（大型重機）・管理員確認，${formatSpotDate(expired)}，已超過 180 天',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('核實過的社群點以「管理員確認，日期」依據行標示，說明不重複可停（#132）', (tester) async {
    usePhone(tester, width: 320);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    final checked = DateTime.now().subtract(const Duration(days: 2));
    final spot = ParkingSpot.fromJson({
      ...facility().toJson(),
      'source': 'community',
      'scooter_allowed': true,
      'scooter_verified_at': checked.toIso8601String(),
    });
    await openDetails(tester, store, spot, scale: 1.6);
    expect(decisionText(tester), '普通機車 · 可停');
    expect(find.text('管理員確認，${formatSpotDate(checked)}'), findsOneWidget);
    expect(find.text('請確認現場公告'), findsOneWidget);
    expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
    await showField(tester, '確認狀態');
    // Decision 30: per kind, not per vehicle; only 停放車種 is recorded.
    expect(
      find.text('停放車種（普通機車）・管理員確認，${formatSpotDate(checked)}'),
      findsOneWidget,
    );
    expect(find.textContaining('核驗'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('管理員核驗過車種的社群停車場不顯示待確認橫幅（寬 $width）', (tester) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      final checked = DateTime.now().subtract(const Duration(days: 1));
      final spot = ParkingSpot.fromJson({
        ...facility().toJson(),
        'source': 'import',
        'scooter_allowed': true,
        'heavy_allowed': true,
        // No zones: the lot's verified flags decide (§3.2 step 3).
        'parking_zones': <Object>[],
        'status': 'confirmed',
        'last_confirmed_at': checked.toIso8601String(),
        'scooter_verified_at': checked.toIso8601String(),
        'heavy_verified_at': checked.toIso8601String(),
      });
      expect(store.eligible(spot).status, EligibilityStatus.allowed);
      await openDetails(tester, store, spot);
      expect(decisionText(tester), '普通機車 · 可停');
      expect(find.textContaining('待確認'), findsNothing);
      await store.setVehicle(VehicleType.heavy);
      await tester.pumpAndSettle();
      expect(decisionText(tester), '大型重機 · 可停');
      expect(find.textContaining('待確認'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('詳情開啟期間切換車種會即時重算資格提示', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, facility());
    expect(decisionText(tester), '普通機車 · 可停');
    await store.setVehicle(VehicleType.heavy);
    await tester.pumpAndSettle();
    expect(decisionText(tester), '大型重機 · 不能停');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('預覽標題列：名稱不截斷，收藏、分享和關閉並排（使用者決定 2026-10-31）', (tester) async {
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
    final close = tester.getCenter(find.byTooltip('關閉詳情'));
    expect(close.dy, closeTo(title.center.dy, 24));
    for (final tooltip in ['收藏停車點', '分享停車點']) {
      final icon = tester.getCenter(find.byTooltip(tooltip));
      expect(icon.dy, close.dy);
      expect(icon.dx, greaterThan(title.right));
    }
    expect(find.text('地下停車場　臺北市內湖區　330 m'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('捲到資料查核仍可直接導航或修改建議，空白指引省略', (tester) async {
    usePhone(tester);
    final store = (await tester.runAsync(createStore))!;
    addTearDown(store.dispose);
    await openDetails(tester, store, roadside);
    final action = tester.getRect(find.text('導航'));
    await showField(tester, '位置與指引');
    expect(find.textContaining('尚未提供：停車指引'), findsNothing);
    expect(find.text('停車指引'), findsNothing);
    expect(find.text('特殊規則'), findsNothing);
    await showField(tester, '資料與查核');
    expect(tester.getRect(find.text('導航')), action);
    expect(find.text('修改建議').hitTestable(), findsOneWidget);
    // Only 最近更新 says 未提供 in the details (the fee plate above says it
    // too): this spot has no update time or history.
    expect(
      find.descendant(
        of: find
            .ancestor(of: find.text('最近更新'), matching: find.byType(Row))
            .first,
        matching: find.text('未提供'),
      ),
      findsOneWidget,
    );
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
      find.text('導航'),
      80,
      scrollable: detailScroll,
    );
    await tester.pumpAndSettle();
    expect(find.text('導航').hitTestable(), findsOneWidget);
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
    // The summary says 機車費率 (decision 28), never a bare 費率.
    expect(find.text('機車費率'), findsOneWidget);
    expect(find.text('費率'), findsNothing);
    expect(find.text('分區'), findsOneWidget);
    expect(feeNowMain(tester), '20 元／次');
    store.vehicle = VehicleType.heavy;
    store.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('大型重機費率'), findsOneWidget);
    expect(feeNowMain(tester), endsWith('費率未確認，請依現場公告'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('寬 $width：點位結構化費率取代分區舊文字，摘要與正文都看得到', (tester) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      final spot = ParkingSpot.fromJson({
        ...facility().toJson(),
        'fee_note': '舊場站說明',
        'fee': {
          'scooter': {'mode': 'per_visit', 'amount': 20},
        },
        'parking_zones': [
          {'name': 'B1', 'access': 'scooterOnly', 'fee_note': '舊 B1 免費'},
          {'name': 'B2', 'access': 'scooterHeavy', 'fee_note': '舊 B2 每次 10 元'},
        ],
      });
      await openDetails(tester, store, spot);
      await showField(tester, '機車費率');
      expect(find.text('依分區計費'), findsNothing);
      expect(feeNowMain(tester), '每次 20 元');
      await showField(tester, '全場');
      // The board repeats the rate with its rule.
      expect(find.text('每次 20 元'), findsWidgets);
      // An old rate without renew says nothing of it (Un-1).
      expect(find.textContaining('隔日是否另計未確認'), findsNothing);
      expect(find.textContaining('費率未確認'), findsOneWidget);
      expect(find.textContaining('舊 B'), findsNothing);
      expect(find.byKey(const ValueKey('fee-extra-note')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  test('儲存的 fee = {} 視為沒有結構化費率（#114）', () {
    final spot = ParkingSpot.fromJson({
      ...roadside.toJson(),
      'fee_note': '每次 25 元（依現場牌面）',
      'fee': <String, Object>{},
    });
    expect(spot.fee, isNull);
    expect(ParkingSpot.fromJson(spot.toJson()).fee, isNull);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('寬 $width：fee = {} 的點位顯示收費文字，不顯示費率未確認', (tester) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      final spot = ParkingSpot.fromJson({
        ...roadside.toJson(),
        'fee_note': '每次 25 元（依現場牌面）',
        'fee': <String, Object>{},
      });
      await openDetails(tester, store, spot);
      expect(find.textContaining('每次 25 元（依現場牌面）'), findsWidgets);
      expect(find.textContaining('費率未確認'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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
      await showKey(tester, 'fee-now-main');
      expect(feeNowMain(tester), '免費');
      expect(find.text('依分區計費'), findsNothing);
      await showField(tester, '位置與指引');
      expect(find.byKey(const ValueKey('fee-extra-note')), findsNothing);
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

  test('場站型式不是路外格位時，說明與橫幅一樣依 isFacility 判斷', () {
    final lot = ParkingSpot(
      id: 'lot',
      name: '地下停車場',
      lat: 25.08,
      lng: 121.55,
      city: '臺北市',
      spaceType: SpaceType.paidMotorcycle,
      facilityType: FacilityType.underground,
      status: TrustStatus.confirmed,
      source: 'community',
    );
    expect(
      decisionExplanation(
        lot,
        const Eligibility(EligibilityStatus.unverified, '規則說明'),
      ),
      '此處確實有停車點；可停放車種未經確認，請以入口公告為準。',
    );
  });

  group('C4 資格依據：逐區資格、試辦期限、缺口說明', () {
    Map<String, Object?> trial(String ends) => {
      'name': '機車區',
      'access': 'scooterHeavy',
      'condition': {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'toll',
        'allow': {'scooter': true, 'heavy': true},
        'basis': {
          'source_url': 'https://example.test/pilot',
          'effective_date': '2026-04-06',
          'expires_on': ends,
        },
      },
    };
    ParkingSpot lot(List<Map<String, Object?>> zones) => ParkingSpot.fromJson({
      ...facility().toJson(),
      'name': '市府轉運站地下停車場',
      'heavy_allowed': true,
      'parking_zones': zones,
    });
    final trialLot = lot([
      trial('2099-12-31'),
      {'name': '汽車區', 'access': 'heavyCar'},
    ]);
    final endedLot = lot([
      trial('2026-10-05'),
      {'name': '汽車區', 'access': 'heavyCar'},
    ]);
    final partialLot = lot([
      {'name': 'B1 機車區', 'access': 'scooterOnly'},
      {'name': 'B2'},
    ]);

    Future<void> open(
      WidgetTester tester,
      ParkingSpot spot, {
      double width = 390,
      double scale = 1,
      Brightness brightness = Brightness.light,
    }) async {
      usePhone(tester, width: width);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await store.setVehicle(VehicleType.heavy);
      await openDetails(
        tester,
        store,
        spot,
        scale: scale,
        brightness: brightness,
      );
    }

    void expectInside(WidgetTester tester, double width) {
      final banner = tester.getRect(
        find.byKey(const ValueKey('spot-decision')),
      );
      expect(banner.right, lessThanOrEqualTo(width));
      for (final finder in [
        find.byKey(const ValueKey('spot-decision-label')),
        find.byKey(const ValueKey('spot-decision-notice-0')),
        find.byKey(const ValueKey('spot-zone-0')),
        find.byKey(const ValueKey('spot-zone-1')),
      ]) {
        if (finder.evaluate().isEmpty) continue;
        expect(tester.getRect(finder).right, lessThanOrEqualTo(banner.right));
      }
      expect(tester.takeException(), isNull);
    }

    testWidgets('試辦分區：有條件並列出可停分區，日曆圖示寫出期限', (tester) async {
      await open(tester, trialLot);
      expect(decisionText(tester), '大型重機 · 有條件・機車區與汽車區可停');
      expect(find.text('依政府公開資料，更新於 2026-10-12'), findsOneWidget);
      expect(find.text('機車區試辦至 2099-12-31'), findsOneWidget);
      expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
      expect(find.text('機車區・有條件'), findsOneWidget);
      expect(find.text('汽車區・可停'), findsOneWidget);
      // The conclusion stays the banner's only bold line.
      final bold = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const ValueKey('spot-decision')),
              matching: find.byType(Text),
            ),
          )
          .where((t) => (t.style?.fontWeight ?? FontWeight.w400).value >= 600);
      expect(bold.map((t) => t.data), ['有條件・機車區與汽車區可停']);
    });

    testWidgets('試辦到期：文字＋日曆圖示，不只靠琥珀色；該區待確認', (tester) async {
      await open(tester, endedLot);
      expect(decisionText(tester), '大型重機 · 可停');
      expect(find.text('機車區試辦已於 2026-10-05 到期，請看現場公告'), findsOneWidget);
      expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
      expect(find.text('機車區・待確認'), findsOneWidget);
    });

    testWidgets('已知分區都不開放：待確認，說明分區不完整，依據行保留', (tester) async {
      await open(tester, partialLot);
      expect(decisionText(tester), '大型重機 · 開放資訊待確認');
      expect(find.text('場站開放大型重機，但已知分區沒有標示可停區域，請依入口公告'), findsOneWidget);
      expect(find.text('依政府公開資料，更新於 2026-10-12'), findsOneWidget);
      expect(find.text('B1 機車區・不能停'), findsOneWidget);
      expect(find.text('B2・待確認：此分區的開放資訊未確認'), findsOneWidget);
    });

    testWidgets('縣市規則過期：待確認並寫出到期日', (tester) async {
      usePhone(tester);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await store.setVehicle(VehicleType.heavy);
      store.rules = [
        CityRule.fromJson({
          'city': '臺北市',
          'vehicle': 'heavy',
          'allowed_space_types': ['paidMotorcycle', 'heavyOnly', 'car'],
          'conditional_space_types': ['offStreet'],
          'fee_note': '請依現場收費公告',
          'exceptions': '收費機車格開放',
          'source_url': 'https://example.test',
          'version': 1,
          'effective_date': '2026-01-01',
          'expires_on': '2026-03-01',
        }),
      ];
      await openDetails(
        tester,
        store,
        ParkingSpot.fromJson({
          ...roadside.toJson(),
          'space_type': 'paidMotorcycle',
          'source': 'official',
        }),
      );
      expect(decisionText(tester), '大型重機 · 待確認');
      // The dated line says it; the explanation does not repeat it.
      expect(find.text('此地區的規則已過期，請以現場標誌標線為準'), findsNothing);
      expect(find.text('臺北市的規則已於 2026-03-01 到期，請看現場公告'), findsOneWidget);
      expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
    });

    testWidgets('場站未確認開放大型重機：分區不列成「可停」', (tester) async {
      await open(
        tester,
        ParkingSpot.fromJson({
          ...lot([
            {'name': '重機區', 'access': 'heavyOnly'},
          ]).toJson(),
          'heavy_allowed': null,
        }),
      );
      expect(decisionText(tester), '大型重機 · 開放資訊待確認');
      expect(find.byKey(const ValueKey('spot-zone-0')), findsNothing);
      expect(find.textContaining('重機區・可停'), findsNothing);
    });

    testWidgets('分區資料涵蓋全場而都不開放：資料不一致', (tester) async {
      await open(
        tester,
        ParkingSpot.fromJson({
          ...lot([
            {'name': 'B1 機車區', 'access': 'scooterOnly'},
          ]).toJson(),
          'zones_complete': true,
        }),
      );
      expect(decisionText(tester), '大型重機 · 開放資訊待確認');
      expect(find.text('場站與分區資料不一致，請依入口公告'), findsOneWidget);
      expect(find.text('B1 機車區・不能停'), findsOneWidget);
    });

    testWidgets('試辦尚未生效：寫出生效日，不寫成「試辦至」', (tester) async {
      final pending = trial('2099-12-31');
      ((pending['condition']! as Map)['basis'] as Map)['effective_date'] =
          '2099-01-01';
      await open(tester, lot([pending]));
      expect(find.text('機車區試辦 2099-01-01 起生效，請看現場公告'), findsOneWidget);
      expect(find.textContaining('試辦至'), findsNothing);
      expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
      expect(find.text('機車區・待確認'), findsOneWidget);
    });

    Future<AppStore> openStreet(
      WidgetTester tester,
      List<CityRule> rules,
      Map<String, Object?> extra,
    ) async {
      usePhone(tester);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      await store.setVehicle(VehicleType.heavy);
      store.rules = rules;
      await openDetails(
        tester,
        store,
        ParkingSpot.fromJson({
          ...roadside.toJson(),
          'space_type': 'paidMotorcycle',
          'source': 'official',
          ...extra,
        }),
      );
      return store;
    }

    Map<String, Object?> taipeiHeavy(List<String> allowed) => {
      'city': '臺北市',
      'vehicle': 'heavy',
      'allowed_space_types': allowed,
      'conditional_space_types': ['offStreet'],
      'fee_note': '請依現場收費公告',
      'exceptions': '測試',
      'source_url': 'https://example.test',
      'version': 1,
      'effective_date': '2026-01-01',
    };

    testWidgets('兩份規則結論相反：公告不一致', (tester) async {
      await openStreet(tester, [
        CityRule.fromJson(taipeiHeavy(['paidMotorcycle', 'heavyOnly', 'car'])),
        CityRule.fromJson(taipeiHeavy(['heavyOnly', 'car'])),
      ], const {});
      expect(decisionText(tester), '大型重機 · 待確認');
      expect(find.text('公告不一致，請以現場公告為準'), findsOneWidget);
    });

    testWidgets('路邊公告到期：期限列寫到期，說明不重複同一句', (tester) async {
      await openStreet(
        tester,
        [
          CityRule.fromJson(taipeiHeavy(['heavyOnly'])),
        ],
        {
          'condition': {
            'bay': 'motorcycle',
            'use': 'share',
            'share': 'scooter_heavy',
            'charge': 'toll',
            'basis': {
              'source_url': 'https://example.test/notice',
              'effective_date': '2026-04-06',
              'expires_on': '2026-10-05',
            },
          },
        },
      );
      expect(find.text('公告已於 2026-10-05 到期，請看現場公告'), findsOneWidget);
      expect(find.byIcon(Icons.event_busy_outlined), findsOneWidget);
    });

    testWidgets('橫幅結論與地圖標記（store.eligible）一致', (tester) async {
      usePhone(tester);
      final store = (await tester.runAsync(createStore))!;
      addTearDown(store.dispose);
      for (final vehicle in VehicleType.values) {
        await store.setVehicle(vehicle);
        for (final spot in [
          trialLot,
          endedLot,
          partialLot,
          facility(),
          roadside,
        ]) {
          final e = store.eligible(spot);
          final d = store.decide(spot).eligibility;
          expect(
            (d.status, d.reason, d.restriction),
            (e.status, e.reason, e.restriction),
            reason: '${spot.name} ${vehicle.name}',
          );
        }
      }
    });

    for (final (width, scale, brightness) in [
      (320.0, 1.6, Brightness.dark),
      (390.0, 1.6, Brightness.light),
      (390.0, 1.0, Brightness.dark),
      (700.0, 1.6, Brightness.light),
      (1280.0, 1.6, Brightness.dark),
    ]) {
      testWidgets('依據列與逐區資格不溢出（寬 $width、字級 $scale、$brightness）', (
        tester,
      ) async {
        for (final spot in [trialLot, endedLot, partialLot]) {
          await open(
            tester,
            spot,
            width: width,
            scale: scale,
            brightness: brightness,
          );
          expectInside(tester, width);
          // The sheet's actions keep their touch size.
          for (final button
              in find
                  .descendant(
                    of: find.byKey(const ValueKey('parking-spot-sheet')),
                    matching: find.byWidgetPredicate(
                      (w) => w is ButtonStyleButton,
                    ),
                  )
                  .evaluate()) {
            final size = (button.renderObject! as RenderBox).size;
            expect(size.height, greaterThanOrEqualTo(48));
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      });
    }
  });
}

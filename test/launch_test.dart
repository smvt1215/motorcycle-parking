import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/location_access.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/map/map_page.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

Future<AppStore> freshStore() async {
  SharedPreferences.setMockInitialValues({});
  return AppStore(LocalRepository(await SharedPreferences.getInstance()), null);
}

Future<void> pumpApp(WidgetTester tester, AppStore store) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
}

LatLng mapCenter(WidgetTester tester) => tester
    .widget<FlutterMap>(find.byType(FlutterMap))
    .mapController!
    .camera
    .center;

/// Calls [AppStore.start] inside `runAsync` so its timers and asset loads
/// run in the real zone, where the test can await them later. The future is
/// wrapped in a record so `async` does not flatten it.
Future<({Future<void> done})> startReal(
  WidgetTester tester,
  Future<void> Function() start,
) async {
  late Future<void> started;
  await tester.runAsync(() async {
    started = start();
  });
  return (done: started);
}

void main() {
  testWidgets('啟動畫面蓋住 App 直到定位完成，地圖移到目前位置', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final fix = Completer<bool>();
    final started = await startReal(
      tester,
      () => store.start(locator: () => fix.future, settleLimit: Duration.zero),
    );
    await pumpApp(tester, store);
    await tester.pump();
    expect(find.byKey(const ValueKey('launch-screen')), findsOneWidget);
    expect(find.text('正在取得目前位置…'), findsOneWidget);

    store
      ..lat = 24.15
      ..lng = 120.67
      ..located = true;
    fix.complete(true);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(store.starting, isFalse);
    expect(find.byKey(const ValueKey('launch-screen')), findsNothing);
    // Light theme: dark status bar icons return once the brand screen is gone.
    expect(
      tester
          .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
          )
          .value,
      SystemUiOverlayStyle.dark,
    );
    final center = mapCenter(tester);
    expect(center.latitude, closeTo(24.15, 1e-6));
    expect(center.longitude, closeTo(120.67, 1e-6));
  });

  testWidgets('定位太慢時不卡住啟動，晚到的定位不拉走使用者移過的地圖', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final fix = Completer<bool>();
    final started = await startReal(
      tester,
      () => store.start(
        locator: () => fix.future,
        locationWait: const Duration(milliseconds: 10),
        settleLimit: Duration.zero,
      ),
    );
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(store.starting, isFalse);
    expect(store.locatingAtLaunch, isTrue);
    expect(find.byKey(const ValueKey('launch-screen')), findsNothing);

    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(23, 120.2), 16);
    await tester.pumpAndSettle();
    store
      ..lat = 24.15
      ..lng = 120.67
      ..located = true;
    fix.complete(true);
    await tester.pumpAndSettle();
    expect(store.locatingAtLaunch, isFalse);
    expect(mapCenter(tester).latitude, closeTo(23, 1e-6));
  });

  test('定位等待與資料載入同時計時，不疊加', () async {
    SharedPreferences.setMockInitialValues({});
    final load = Completer<void>();
    final store = _SlowStore(
      LocalRepository(await SharedPreferences.getInstance()),
      load.future,
    );
    final started = store.start(
      locator: () => Completer<bool>().future,
      locationWait: const Duration(milliseconds: 50),
      settleLimit: Duration.zero,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    load.complete();
    await started.timeout(const Duration(milliseconds: 20));
    expect(store.starting, isFalse);
  });

  test('地圖接手的範圍查詢完成前，啟動畫面不收起', () async {
    SharedPreferences.setMockInitialValues({});
    final parking = _ControlledParking();
    final store = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      null,
      parkingRepository: parking,
    );
    final started = store.start(locator: () async => false);
    while (parking.requests.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // The map lays out and replaces the first load, which is now stale.
    store.queueViewport(
      const MapViewport(south: 25.02, west: 121.55, north: 25.05, east: 121.58),
    );
    parking.requests.first.complete(const ParkingResult([]));
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(store.starting, isTrue);
    expect(parking.requests, hasLength(2));
    parking.requests.last.complete(const ParkingResult([]));
    await started.timeout(const Duration(seconds: 2));
    expect(store.starting, isFalse);
  });

  testWidgets('第一次開啟在啟動畫面後顯示圖例，之後不再自動顯示', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    var started = await startReal(
      tester,
      () => store.start(locator: () async => false, settleLimit: Duration.zero),
    );
    await pumpApp(tester, store);
    await tester.pump();
    expect(find.text('地圖怎麼看'), findsNothing);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.text('地圖怎麼看'), findsOneWidget);
    expect(store.local.legendSeen, isTrue);
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
    expect(find.text('地圖怎麼看'), findsNothing);

    started = await startReal(
      tester,
      () => store.start(locator: () async => false, settleLimit: Duration.zero),
    );
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(store.introduceLegend, isFalse);
    expect(find.text('地圖怎麼看'), findsNothing);
  });

  testWidgets('定位未授權時，啟動後先提醒前往設定，再顯示第一次的圖例', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final started = await startReal(
      tester,
      () => store.start(
        locator: () async {
          store.locationIssue = LocationIssue.denied;
          return false;
        },
        settleLimit: Duration.zero,
      ),
    );
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.text('尚未允許使用位置'), findsOneWidget);
    expect(find.text('前往設定'), findsOneWidget);
    expect(find.text('地圖怎麼看'), findsNothing);
    await tester.tap(find.text('前往設定'));
    await tester.pumpAndSettle();
    expect(find.text('尚未允許使用位置'), findsNothing);
    expect(find.text('地圖怎麼看'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('啟動畫面收起後才知道定位失敗，看完圖例再提醒', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final fix = Completer<bool>();
    final started = await startReal(
      tester,
      () => store.start(
        locator: () => fix.future,
        locationWait: const Duration(milliseconds: 10),
        settleLimit: Duration.zero,
      ),
    );
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.text('地圖怎麼看'), findsOneWidget);
    store.locationIssue = LocationIssue.serviceOff;
    fix.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('定位服務未開啟'), findsNothing);
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
    expect(find.text('定位服務未開啟'), findsOneWidget);
    expect(find.text('開啟定位設定'), findsOneWidget);
    await tester.tap(find.text('稍後'));
    await tester.pumpAndSettle();
    expect(find.text('定位服務未開啟'), findsNothing);
  });

  testWidgets('從其他分頁啟動時，切到地圖才顯示定位提醒與圖例', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final started = await startReal(
      tester,
      () => store.start(
        locator: () async {
          store.locationIssue = LocationIssue.denied;
          return false;
        },
        settleLimit: Duration.zero,
      ),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var showControls = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [storeProvider.overrideWith((ref) => store)],
        child: MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return Scaffold(body: MapPage(showControls: showControls));
            },
          ),
        ),
      ),
    );
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    // Another tab covers the map: nothing pops up over it.
    expect(find.text('尚未允許使用位置'), findsNothing);
    rebuild(() => showControls = true);
    await tester.pumpAndSettle();
    expect(find.text('尚未允許使用位置'), findsOneWidget);
    await tester.tap(find.text('稍後'));
    await tester.pumpAndSettle();
    expect(find.text('地圖怎麼看'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉'));
    await tester.pumpAndSettle();
    // Greeted once: hiding and showing the map again does not repeat it.
    rebuild(() => showControls = false);
    await tester.pumpAndSettle();
    rebuild(() => showControls = true);
    await tester.pumpAndSettle();
    expect(find.text('尚未允許使用位置'), findsNothing);
    expect(find.text('地圖怎麼看'), findsNothing);
  });

  testWidgets('定位鈕等動作遇到未授權時跳出設定提醒，而非一般訊息', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runAction(
                context,
                () async => throw LocationAccessError(LocationIssue.denied),
              ),
              child: const Text('定位'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('定位'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('location-prompt')), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('定位失敗時維持預設中心並進入地圖', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final started = await startReal(
      tester,
      () => store.start(locator: () async => false, settleLimit: Duration.zero),
    );
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('launch-screen')), findsNothing);
    expect(store.located, isFalse);
    expect(mapCenter(tester).latitude, closeTo(25.0339, 1e-6));
  });
}

/// Holds [init] until the test releases it, standing in for slow data.
class _SlowStore extends AppStore {
  _SlowStore(LocalRepository local, this.load) : super(local, null);
  final Future<void> load;
  @override
  Future<void> init() => load;
}

/// Answers viewport loads only when the test completes them.
class _ControlledParking extends ParkingRepository {
  _ControlledParking() : super(null);
  final requests = <Completer<ParkingResult>>[];
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) {
    final result = Completer<ParkingResult>();
    requests.add(result);
    return result.future;
  }
}

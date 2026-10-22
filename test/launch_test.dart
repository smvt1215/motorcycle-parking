import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';

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
      () => store.start(locator: () => fix.future),
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
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    load.complete();
    await started.timeout(const Duration(milliseconds: 20));
    expect(store.starting, isFalse);
  });

  testWidgets('定位失敗時維持預設中心並進入地圖', (tester) async {
    final store = (await tester.runAsync(freshStore))!;
    final started = await startReal(
      tester,
      () => store.start(locator: () async => false),
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

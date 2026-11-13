import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/location_access.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/launch/launch_screen.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/location_rationale.dart';

/// Stands in for the platform: the permission the system reports, what the
/// rider answers in the system dialog, and how often it was asked.
class FakeLocationDevice extends LocationDevice {
  FakeLocationDevice({
    this.permission = LocationPermission.denied,
    this.answer = LocationPermission.whileInUse,
  });
  LocationPermission permission, answer;
  bool service = true;
  int requests = 0;

  @override
  Future<bool> serviceEnabled() async => service;
  @override
  Future<LocationPermission> checkPermission() async => permission;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = answer;
  }

  @override
  Future<Position?> lastKnownPosition() async => null;
  @override
  Future<Position> currentPosition() async => Position(
    latitude: 24.15,
    longitude: 120.67,
    timestamp: DateTime.now(),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );
}

const card = ValueKey('location-rationale');
const continueKey = ValueKey('location-rationale-continue');
const declineKey = ValueKey('location-rationale-decline');

Future<AppStore> storeWith(
  FakeLocationDevice device, [
  Map<String, Object> prefs = const {},
]) async {
  // The 即時車位 Beta sheet would cover the map buttons.
  SharedPreferences.setMockInitialValues({
    'availabilityBetaIntroSeen': true,
    ...prefs,
  });
  return AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    locationDevice: device,
  );
}

Future<void> pumpApp(
  WidgetTester tester,
  AppStore store, {
  Size size = const Size(390, 844),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
}

/// Runs [AppStore.start] in the real zone (see launch_test.dart).
Future<({Future<void> done})> startReal(
  WidgetTester tester,
  AppStore store,
) async {
  late Future<void> started;
  await tester.runAsync(() async {
    started = store.start(settleLimit: Duration.zero);
  });
  return (done: started);
}

/// Lets the real-zone launch reach the explanation, or get past it.
Future<void> settleReal(WidgetTester tester, bool Function() until) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 200 && !until(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
  await tester.pump();
}

Future<void> closeLegend(WidgetTester tester) async {
  expect(find.text('地圖怎麼看'), findsOneWidget);
  await tester.tap(find.byTooltip('關閉'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('第一次啟動：啟動畫面先顯示說明卡，按「繼續」前不要求權限，允許後照舊定位', (tester) async {
    final device = FakeLocationDevice();
    final store = (await tester.runAsync(() => storeWith(device)))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await settleReal(tester, () => store.explainingLocation);

    expect(find.byKey(const ValueKey('launch-screen')), findsOneWidget);
    expect(find.byKey(card), findsOneWidget);
    expect(find.text(LocationRationaleCard.title), findsOneWidget);
    expect(find.text('先不要'), findsOneWidget);
    expect(device.requests, 0);
    // The location wait does not run while the rider reads.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(store.starting, isTrue);
    expect(device.requests, 0);

    await tester.tap(find.byKey(continueKey));
    await tester.pump();
    expect(find.byKey(card), findsNothing);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(device.requests, 1);
    expect(store.local.locationAsked, isTrue);
    expect(store.located, isTrue);
    final center = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .camera
        .center;
    expect(center.latitude, closeTo(24.15, 1e-6));
    // The first legend still follows the location step.
    await closeLegend(tester);
  });

  testWidgets('iOS 的說明卡只有「繼續」，沒有先不要', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final device = FakeLocationDevice();
    final store = (await tester.runAsync(() => storeWith(device)))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await settleReal(tester, () => store.explainingLocation);
    expect(find.byKey(card), findsOneWidget);
    expect(find.text('繼續'), findsOneWidget);
    expect(find.text('先不要'), findsNothing);
    expect(find.byKey(declineKey), findsNothing);
    expect(device.requests, 0);
    await tester.tap(find.byKey(continueKey));
    await tester.pump();
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(device.requests, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('剛在系統視窗按「不允許」後不立刻跳對話框，之後按定位才跳', (tester) async {
    final device = FakeLocationDevice(answer: LocationPermission.deniedForever);
    final store = (await tester.runAsync(() => storeWith(device)))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await settleReal(tester, () => store.explainingLocation);
    await tester.tap(find.byKey(continueKey));
    await tester.pump();
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(device.requests, 1);
    expect(store.locationIssue, LocationIssue.denied);
    expect(find.text('尚未允許使用位置'), findsNothing);
    await closeLegend(tester);
    expect(find.text('尚未允許使用位置'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('locate-fab')));
    await tester.pumpAndSettle();
    expect(find.text('尚未允許使用位置'), findsOneWidget);
    expect(find.byKey(card), findsNothing);
  });

  testWidgets('Android 按「先不要」：不跳系統視窗、不提醒，之後按定位再說明一次', (tester) async {
    final device = FakeLocationDevice();
    final store = (await tester.runAsync(() => storeWith(device)))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await settleReal(tester, () => store.explainingLocation);
    await tester.tap(find.byKey(declineKey));
    await tester.pump();
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(device.requests, 0);
    expect(store.located, isFalse);
    expect(store.locationIssue, isNull);
    expect(find.text('尚未允許使用位置'), findsNothing);
    await closeLegend(tester);
    // No fix: the locate button shows the searching crosshair (P20a ④).
    final locateFab = find.byKey(const ValueKey('locate-fab'));
    expect(
      find.descendant(
        of: locateFab,
        matching: find.byIcon(Icons.location_searching),
      ),
      findsOneWidget,
    );

    // 我的位置: explained again before the system asks.
    await tester.tap(find.byKey(const ValueKey('locate-fab')));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);
    expect(device.requests, 0);
    // 先不要 again: nothing else happens.
    await tester.tap(find.byKey(declineKey));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsNothing);
    expect(find.text('尚未允許使用位置'), findsNothing);
    expect(device.requests, 0);

    await tester.tap(find.byKey(const ValueKey('locate-fab')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(continueKey));
    await tester.pumpAndSettle();
    expect(device.requests, 1);
    expect(store.located, isTrue);
    expect(store.local.locationAsked, isTrue);
    expect(
      find.descendant(of: locateFab, matching: find.byIcon(Icons.my_location)),
      findsOneWidget,
    );
  });

  testWidgets('按過「先不要」後再開 App：不再顯示說明卡，也不要求權限', (tester) async {
    final device = FakeLocationDevice();
    final store = (await tester.runAsync(
      () => storeWith(device, {
        'locationAsked': false,
        'locationDeferred': true,
        'legendSeen': true,
      }),
    ))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsNothing);
    expect(store.explainedAtLaunch, isFalse);
    expect(device.requests, 0);
    expect(find.text('尚未允許使用位置'), findsNothing);
  });

  for (final (name, permission, prefs, requests, prompted) in [
    ('已允許', LocationPermission.whileInUse, {'locationAsked': true}, 0, false),
    // iOS refused: no system dialog again, the settings prompt as before.
    (
      '已拒絕（iOS）',
      LocationPermission.deniedForever,
      {'locationAsked': true},
      0,
      true,
    ),
    // Android refused once, or iOS 允許一次 expired: the system asks again
    // right away, as before.
    ('已問過、系統可再問', LocationPermission.denied, {'locationAsked': true}, 1, true),
    // Updated from a version without the explanation, which asked at once.
    ('舊版已開過 App', LocationPermission.denied, {'legendSeen': true}, 1, true),
  ]) {
    testWidgets('$name的啟動不顯示說明卡，流程和以前一樣', (tester) async {
      final device = FakeLocationDevice(
        permission: permission,
        answer: LocationPermission.deniedForever,
      );
      final store = (await tester.runAsync(
        () => storeWith(device, {...prefs, 'legendSeen': true}),
      ))!;
      final started = await startReal(tester, store);
      await pumpApp(tester, store);
      await tester.runAsync(() => started.done);
      await tester.pumpAndSettle();
      expect(find.byKey(card), findsNothing);
      expect(store.explainedAtLaunch, isFalse);
      expect(device.requests, requests);
      expect(find.text('尚未允許使用位置'), prompted ? findsOneWidget : findsNothing);
    });
  }

  testWidgets('定位服務關閉時照舊提醒開啟，不顯示說明卡', (tester) async {
    final device = FakeLocationDevice()..service = false;
    final store = (await tester.runAsync(() => storeWith(device)))!;
    final started = await startReal(tester, store);
    await pumpApp(tester, store);
    await tester.runAsync(() => started.done);
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsNothing);
    expect(find.text('定位服務未開啟'), findsOneWidget);
    expect(device.requests, 0);
  });

  testWidgets('回報選點按「移到我的位置」遇到還沒說明過時，先說明再要求', (tester) async {
    var calls = 0;
    var accepted = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runAction(context, () async {
                calls++;
                if (!accepted) {
                  throw LocationRationaleNeeded(() => accepted = true);
                }
              }),
              child: const Text('定位'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('定位'));
    await tester.pumpAndSettle();
    expect(find.byKey(card), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.byKey(continueKey));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(calls, 2);
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final (name, size, scale, dark) in [
      ('手機', const Size(390, 844), 1.0, false),
      ('手機深色', const Size(390, 844), 1.0, true),
      ('小手機字級 1.3', const Size(360, 640), 1.3, false),
      ('手機字級 2.0', const Size(390, 844), 2.0, false),
      ('平板', const Size(820, 1180), 1.0, false),
      ('平板字級 2.0', const Size(820, 1180), 2.0, true),
      ('手機橫放字級 2.0', const Size(844, 390), 2.0, false),
    ]) {
      testWidgets('${platform.name} $name：說明卡不溢位、按鈕留在畫面內且夠大', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: dark ? Brightness.dark : Brightness.light,
              colorSchemeSeed: brand,
            ),
            home: MediaQuery(
              data: MediaQueryData(
                size: size,
                textScaler: TextScaler.linear(scale),
              ),
              child: LaunchCurtain(
                visible: true,
                locating: true,
                onExplained: (_) {},
                child: const SizedBox.shrink(),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final cardRect = tester.getRect(find.byKey(card));
        expect(cardRect.bottom, size.height);
        expect(
          cardRect.width,
          lessThanOrEqualTo(LocationRationaleCard.maxWidth),
        );
        expect(cardRect.center.dx, closeTo(size.width / 2, .01));
        final buttons = [
          continueKey,
          if (platform == TargetPlatform.android) declineKey,
        ];
        for (final key in buttons) {
          final rect = tester.getRect(find.byKey(key));
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(rect.top, greaterThanOrEqualTo(0));
        }
        if (platform == TargetPlatform.android) {
          // The same size, side by side or stacked.
          expect(
            tester.getSize(find.byKey(declineKey)).width,
            closeTo(tester.getSize(find.byKey(continueKey)).width, .01),
          );
        } else {
          expect(find.byKey(declineKey), findsNothing);
        }
        // The launch screen's own text is covered, so not read out.
        expect(find.bySemanticsLabel('正在取得目前位置…'), findsNothing);
        expect(
          find.bySemanticsLabel(LocationRationaleCard.title),
          findsOneWidget,
        );
        semantics.dispose();
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}

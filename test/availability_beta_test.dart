import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/availability_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/availability_beta_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/features/map/beta_tag.dart';
import 'package:motorcycle_parking/features/map/map_filter_row.dart';
import 'package:motorcycle_parking/features/map/map_legend_page.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/availability.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'availability_fixtures.dart';

/// 即時車位 Beta (#139, canvas v157 A13, A14, P3): the cities come from
/// client_config, and Beta shows only on the first-time sheet, the
/// 「有即時空位」 chip and the details' 有沒有位.

const _lat = 25.0339, _lng = 121.5623;

/// A heavy-bike lot in [city] at the map centre.
ParkingSpot _lot(
  String id,
  String city, {
  double dx = 0,
  bool? heavy = true,
  String source = 'official',
}) => ParkingSpot(
  id: id,
  name: '測試停車場 $id',
  lat: _lat,
  lng: _lng + dx * 2.15e-5,
  city: city,
  district: '測試區',
  spaceType: SpaceType.offStreet,
  facilityType: FacilityType.underground,
  source: source,
  status: TrustStatus.confirmed,
  scooterAllowed: true,
  heavyAllowed: heavy,
  scooterTotal: 80,
  updatedAt: DateTime(2026, 10, 20),
);

final _taipei = _lot('tp', '臺北市');
final _counts = [
  count('tp', AvailabilityVehicle.heavy, total: 24, available: 6),
];

Future<AppStore> _store(
  List<ParkingSpot> spots,
  List<AvailabilitySnapshot> counts, {
  Map<String, Object> prefs = const {},
  Future<List<String>> Function()? beta,
}) async {
  SharedPreferences.setMockInitialValues({'vehicle': 'heavy', ...prefs});
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: FixedParking(spots),
    availabilitySource: FakeAvailabilitySource(() => counts),
    availabilityBetaCities: beta,
    clock: () => availabilityNow,
  );
  await store.refreshAvailabilityBeta();
  await store.init();
  return store;
}

/// The app over [store], with the launch greeting over so the Beta sheet
/// may come up.
Future<void> _pumpApp(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  expect(find.byType(FlutterMap), findsOneWidget);
  store.launchLocation = Future.value(false);
  store.notifyListeners();
  await tester.pump();
  await tester.pumpAndSettle();
}

Finder get _intro => find.byKey(const ValueKey('availability-beta-intro'));
Finder get _chip => find.byKey(const ValueKey('availability-filter'));

Future<void> _tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _openDetails(WidgetTester tester, AppStore store) async {
  await tester.pumpWidget(
    MaterialApp(
      // The app's bridge for CNBottomSheet's Material localizations.
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSpot(context, store, store.spots.first),
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

String _seatText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byKey(
          const ValueKey('availability-summary'),
          skipOffstage: false,
        ),
        matching: find.byType(Text, skipOffstage: false),
        skipOffstage: false,
      ),
    )
    .map((t) => t.data ?? t.textSpan!.toPlainText())
    .join('｜');

void main() {
  group('Beta 縣市清單', () {
    test('還沒讀到時預設臺北市；讀到後存下，空陣列代表沒有 Beta', () async {
      var answer = <String>['臺中市'];
      final store = await _store(const [], const [], beta: () async => answer);
      expect(store.availabilityBetaCities, ['臺中市']);
      answer = [];
      await store.refreshAvailabilityBeta();
      expect(store.availabilityBetaCities, isEmpty);
      store.dispose();

      final demo = await _store(const [], const []);
      expect(demo.availabilityBetaCities, defaultAvailabilityBetaCities);
      demo.dispose();
    });

    test('舊後端缺欄位（TypeError）或離線時沿用上次的值', () async {
      final fresh = await _store(
        const [],
        const [],
        beta: () async => throw TypeError(),
      );
      expect(fresh.availabilityBetaCities, ['臺北市']);
      fresh.dispose();

      final kept = await _store(
        const [],
        const [],
        prefs: {
          'availabilityBetaCities': ['新北市'],
        },
        beta: () async => throw Exception('offline'),
      );
      expect(kept.availabilityBetaCities, ['新北市']);
      kept.dispose();
    });

    test('台、臺視為同一縣市；程式只有預設值寫出縣市名', () {
      expect(inAvailabilityBeta('台北市', ['臺北市']), isTrue);
      expect(inAvailabilityBeta('新北市', ['臺北市']), isFalse);
      expect(inAvailabilityBeta('', ['臺北市']), isFalse);
      expect(betaOnlyCities(['臺北市', '臺中市']), '即時空位目前只有臺北市、臺中市');
    });

    test('圖例來源依縣市對照機關，查不到時寫「縣市官方」', () {
      expect(betaCityProvider('臺北市'), '臺北市停管處');
      expect(betaCityProvider('台北市'), '臺北市停管處');
      expect(betaCityProvider('臺中市'), '臺中市官方');
      expect(
        legendBetaSource(['臺北市', '臺中市']),
        '停車場上方的數字是臺北市停管處、臺中市官方提供的剩餘車位，大約每 5 分鐘更新。',
      );
    });
  });

  const sizes = [Size(390, 844), Size(820, 1180), Size(1180, 820)];
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in sizes) {
      final name =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';

      void setUp(WidgetTester tester) {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      testWidgets('$name 第一次看到臺北的剩餘數滑出說明，按「知道了」後不再出現', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store([_taipei], _counts),
        ))!;
        await _pumpApp(tester, store);
        expect(_intro, findsOneWidget);
        expect(find.text(betaIntroTitle('臺北市')), findsOneWidget);
        expect(find.text(betaIntroSource('臺北市停管處')), findsOneWidget);
        expect(find.text(betaIntroCaution), findsOneWidget);
        expect(find.text(betaIntroEligibility), findsOneWidget);
        expect(find.textContaining('回報現場狀況'), findsNothing);
        expect(find.textContaining('試辦'), findsNothing);
        final done = find.byKey(const ValueKey('beta-intro-done'));
        expect(tester.getSize(done).height, greaterThanOrEqualTo(44));
        expect(
          tester
              .getSize(find.byKey(const ValueKey('beta-intro-legend')))
              .height,
          greaterThanOrEqualTo(isCupertino ? 44 : 48),
        );
        expect(tester.takeException(), isNull);
        await _tap(tester, done);
        expect(_intro, findsNothing);
        expect(store.availabilityBetaIntroSeen, isTrue);

        // A new launch with the same preferences: the sheet stays away.
        // (The provider scope disposes each store with it.)
        await tester.pumpWidget(const SizedBox.shrink());
        final again = (await tester.runAsync(
          () => _store(
            [_taipei],
            _counts,
            prefs: {'availabilityBetaIntroSeen': true},
          ),
        ))!;
        await _pumpApp(tester, again);
        expect(_intro, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 從說明看「地圖怎麼看」，P3 有即時車位 Beta 段', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store([_taipei], _counts),
        ))!;
        await _pumpApp(tester, store);
        await _tap(tester, find.byKey(const ValueKey('beta-intro-legend')));
        expect(find.byType(MapLegendPage), findsOneWidget);
        final section = find.byKey(
          const ValueKey('availability-beta-legend'),
          skipOffstage: false,
        );
        await tester.scrollUntilVisible(
          section,
          200,
          scrollable: find.byType(Scrollable).last,
        );
        expect(
          find.descendant(of: section, matching: find.byType(BetaTag)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: section,
            matching: find.text(legendBetaSource(['臺北市'])),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: section,
            matching: find.textContaining('臺北市停管處提供的剩餘車位'),
          ),
          findsOneWidget,
        );
        // Reading the legend counts as read, like 知道了.
        expect(store.availabilityBetaIntroSeen, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 篩選鈕帶 Beta；不在 Beta 縣市時空結果說只有臺北市並可清除', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store(
            [_lot('np', '新北市')],
            const [],
            prefs: {'availabilityBetaIntroSeen': true},
          ),
        ))!;
        await _pumpApp(tester, store);
        expect(
          find.descendant(of: _chip, matching: find.byType(BetaTag)),
          findsOneWidget,
        );
        await _tap(tester, _chip);
        final selectedTag = tester.widget<BetaTag>(
          find.descendant(of: _chip, matching: find.byType(BetaTag)),
        );
        expect(selectedTag.color, Colors.white);
        expect(find.text('即時空位目前只有臺北市'), findsOneWidget);
        final clear = find.descendant(
          of: find.byKey(const ValueKey('availability-empty')),
          matching: find.text('清除篩選'),
        );
        expect(clear, findsOneWidget);
        expect(tester.takeException(), isNull);
        await _tap(tester, clear);
        expect(find.byKey(const ValueKey('availability-empty')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name Beta 清單為空：說明、篩選標籤、詳情 Beta 行都不出現', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store([_taipei], _counts, beta: () async => const []),
        ))!;
        await _pumpApp(tester, store);
        expect(_intro, findsNothing);
        expect(find.byType(BetaTag), findsNothing);
        // The filter still works.
        expect(_chip, findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        final details = (await tester.runAsync(
          () => _store([_taipei], _counts, beta: () async => const []),
        ))!;
        await _openDetails(tester, details);
        expect(_seatText(tester), contains('6 剩餘 ／ 共 24 格（大型重機）'));
        expect(find.byType(BetaTag, skipOffstage: false), findsNothing);
        expect(
          find.byKey(
            const ValueKey('availability-beta-note'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        details.dispose();
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 詳情有沒有位：剩餘數、總格數與車種、更新時間與來源、Beta 說明', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store(
            [_taipei],
            _counts,
            prefs: {'availabilityBetaIntroSeen': true},
          ),
        ))!;
        await _openDetails(tester, store);
        expect(
          _seatText(tester),
          '有沒有位｜6 剩餘 ／ 共 24 格（大型重機）｜17:02 更新　臺北市停管處｜'
          'Beta｜即時空位目前只有臺北市，還在試點，抵達時請以現場為準。',
        );
        final count = tester.widget<Text>(
          find.byKey(const ValueKey('availability-count'), skipOffstage: false),
        );
        final number = (count.textSpan! as TextSpan).children!.first;
        expect(number.style!.fontSize, 30);
        expect(number.style!.fontWeight, FontWeight.w600);
        expect(
          find.bySemanticsLabel(
            '有沒有位，剩餘 6 格，共 24 格（大型重機），17:02 更新　臺北市停管處，'
            'Beta，即時空位目前只有臺北市，還在試點，抵達時請以現場為準。',
          ),
          findsOneWidget,
        );
        // The second plate reads the count.
        expect(find.text('剩 6 格'), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 其他縣市維持空位未知，不掛 Beta', (tester) async {
        setUp(tester);
        final store = (await tester.runAsync(
          () => _store([_lot('tc', '臺中市')], const []),
        ))!;
        await _openDetails(tester, store);
        expect(_seatText(tester), startsWith('有沒有位｜空位未知'));
        expect(find.byType(BetaTag, skipOffstage: false), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 滑掉說明不算看過；剩餘數都在群聚圈裡時不出現', (tester) async {
        setUp(tester);
        // Five Taipei lots a few pixels apart fold into one cluster: no
        // pill is drawn, so no sheet.
        final crowd = [
          for (var i = 0; i < 5; i++) _lot('c$i', '臺北市', dx: i * 4.0),
        ];
        final clustered = (await tester.runAsync(
          () => _store(crowd, [
            for (var i = 0; i < 5; i++)
              count('c$i', AvailabilityVehicle.heavy, total: 24, available: 6),
          ]),
        ))!;
        await _pumpApp(tester, clustered);
        expect(_intro, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());

        final store = (await tester.runAsync(
          () => _store([_taipei], _counts),
        ))!;
        await _pumpApp(tester, store);
        expect(_intro, findsOneWidget);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(_intro, findsNothing);
        expect(store.availabilityBetaIntroSeen, isFalse);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 待確認但不擁擠的點照樣畫出剩餘數，也會滑出說明', (tester) async {
        setUp(tester);
        final lot = _lot('uv', '臺北市', heavy: null, source: 'community');
        final store = (await tester.runAsync(
          () => _store(
            [lot],
            [count('uv', AvailabilityVehicle.heavy, total: 24, available: 6)],
          ),
        ))!;
        expect(store.eligible(lot).status, EligibilityStatus.unverified);
        await _pumpApp(tester, store);
        expect(_intro, findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 重機只有汽車格剩餘時，詳情仍帶 Beta 說明', (tester) async {
        setUp(tester);
        final lot = ParkingSpot(
          id: 'hc',
          name: '測試停車場 hc',
          lat: _lat,
          lng: _lng,
          city: '臺北市',
          district: '測試區',
          spaceType: SpaceType.offStreet,
          facilityType: FacilityType.underground,
          source: 'official',
          status: TrustStatus.confirmed,
          scooterAllowed: true,
          heavyAllowed: true,
          access: ParkingAccess.heavyCar,
          scooterTotal: 80,
          updatedAt: DateTime(2026, 10, 20),
        );
        final store = (await tester.runAsync(
          () => _store(
            [lot],
            [count('hc', AvailabilityVehicle.car, total: 50, available: 30)],
            prefs: {'availabilityBetaIntroSeen': true},
          ),
        ))!;
        await _openDetails(tester, store);
        expect(_seatText(tester), contains('汽車格剩餘 30'));
        expect(
          find.byKey(
            const ValueKey('availability-beta-note'),
            skipOffstage: false,
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('$name 深色模式選取篩選時 Beta 標籤跟 chip 字色', (tester) async {
        setUp(tester);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: Brightness.dark),
            home: Scaffold(
              body: MapFilterChip(
                label: '有即時空位',
                selected: true,
                beta: true,
                onTap: () {},
              ),
            ),
          ),
        );
        final colors = ThemeData(brightness: Brightness.dark).colorScheme;
        expect(
          tester.widget<BetaTag>(find.byType(BetaTag)).color,
          colors.onInverseSurface,
        );
      }, variant: TargetPlatformVariant.only(platform));
    }
  }
}

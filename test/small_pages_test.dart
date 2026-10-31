import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/features/auth/profile_editor.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/contribute/contribute_page.dart';
import 'package:motorcycle_parking/features/contribute/my_contributions.dart';
import 'package:motorcycle_parking/features/contribute/my_contributions_page.dart';
import 'package:motorcycle_parking/features/map/vehicle_sheet.dart';
import 'package:motorcycle_parking/features/rules/rules_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'my_contributions_test.dart' show createStore, row;

const sizes = [Size(390, 844), Size(820, 1180), Size(1180, 820)];
const platforms = [TargetPlatform.android, TargetPlatform.iOS];

final rules =
    (jsonDecode(File('assets/rules/parking_rules.json').readAsStringSync())
            as List<dynamic>)
        .map((j) => CityRule.fromJson(j as Map<String, dynamic>))
        .toList();

List<ParkingSpot> nearbySpots() => [
  for (var i = 0; i < 5; i++)
    ParkingSpot(
      id: 'official:spot-$i',
      name: '測試停車點 $i',
      lat: 25.0339 + i * .001,
      lng: 121.5623,
      city: '臺北市',
      source: 'official',
      spaceType: i == 0 ? SpaceType.offStreet : SpaceType.paidMotorcycle,
    ),
];

void setView(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(
  WidgetTester tester,
  AppStore store, {
  required String initial,
}) async {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/rules',
        builder: (_, _) => const Scaffold(body: RulesPage()),
      ),
      GoRoute(
        path: '/contribute',
        builder: (_, _) => const Scaffold(body: ContributePage()),
        routes: [
          GoRoute(path: 'mine', builder: (_, _) => const MyContributionsPage()),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  for (final platform in platforms) {
    for (final size in sizes) {
      final tag =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';

      testWidgets('P7 停車規則 7 類格位一類一列（$tag）', (tester) async {
        setView(tester, size);
        final store = (await createStore([]))
          ..rules = rules
          ..vehicle = VehicleType.heavy;
        await pumpApp(tester, store, initial: '/rules');
        expect(tester.takeException(), isNull);
        expect(
          tester.getSize(find.byKey(const ValueKey('rules-city'))).height,
          greaterThanOrEqualTo(44),
        );
        for (final name in [
          '一般機車格',
          '普大共用格',
          '重機專用格',
          '汽機車共用格',
          '汽車格',
          '身障格',
          '充電格',
        ]) {
          await tester.scrollUntilVisible(find.text(name), 100);
          expect(find.text(name), findsOneWidget);
        }
        expect(find.text('收費格可停，免費巷弄格不能停'), findsOneWidget);
        expect(find.text('規則依臺北市公告整理。核對日期 2026-10-06，版本 1。'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('查看官方來源'), 100);
        await tester.ensureVisible(find.text('查看官方來源'));
        await tester.pumpAndSettle();
        expect(find.text('查看官方來源').hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets('P8 貢獻：修正附近停車點與兩筆建議預覽（$tag）', (tester) async {
        setView(tester, size);
        List<Map<String, dynamic>> page() => [
          row('a'),
          row('b', status: 'accepted'),
          row('c', kind: 'new_spot', field: null, summary: null),
        ];
        // One page for the tab's preview, one for the pushed page.
        final store = (await createStore([page(), page()]))
          ..spots = nearbySpots();
        store.located = true;
        await pumpApp(tester, store, initial: '/contribute');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('修正附近停車點'), findsOneWidget);
        // The three nearest, each with its own edit button and distance.
        expect(find.text('修改'), findsNWidgets(3));
        expect(find.text('路外停車場　0 m'), findsOneWidget);
        expect(find.text('查看全部 5 個停車點'), findsOneWidget);
        expect(find.text('新增停車點').hitTestable(), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('查看全部紀錄'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byType(ContributionRow), findsNWidgets(2));
        expect(find.text('怎麼算錢：建議「計時 每小時 20 元」；說明：現場告示牌'), findsWidgets);
        await tester.ensureVisible(find.text('查看全部紀錄'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('查看全部紀錄'));
        await tester.pumpAndSettle();
        // P9 lists every row on its own page.
        expect(find.byType(MyContributionsPage), findsOneWidget);
        expect(find.text('我送出的建議'), findsWidgets);
        expect(find.text('新增的停車點、修改建議和不能停車的回報，以及審核結果。'), findsOneWidget);
        expect(find.text('待車友確認'), findsOneWidget);
        expect(find.text('在地圖上，等其他車友確認'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (platform == TargetPlatform.iOS) {
          expect(find.text('貢獻'), findsWidgets);
          await tester.tap(find.text('貢獻').last);
        } else {
          await tester.tap(find.byTooltip('返回'));
        }
        await tester.pumpAndSettle();
        expect(find.byType(MyContributionsPage), findsNothing);
        expect(find.text('修正附近停車點'), findsOneWidget);
      }, variant: TargetPlatformVariant.only(platform));
    }

    testWidgets('P11 登入順序與不需登入說明（${platform.name}）', (tester) async {
      final store = await createStore([], rider: null);
      await tester.pumpWidget(
        MaterialApp(
          // Match the app's bridge for CNBottomSheet's Material localizations.
          builder: (context, child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSignIn(context, store),
                child: const Text('開啟'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開啟'));
      await tester.pumpAndSettle();
      expect(find.text('瀏覽地圖與記錄停車位置不需登入。'), findsOneWidget);
      final google = find.text('使用 Google 登入');
      expect(google, findsOneWidget);
      if (platform == TargetPlatform.iOS) {
        final apple = find.text('使用 Apple 登入');
        expect(
          tester.getTopLeft(apple).dy,
          lessThan(tester.getTopLeft(google).dy),
        );
      } else {
        expect(find.text('使用 Apple 登入'), findsNothing);
      }
    }, variant: TargetPlatformVariant.only(platform));
  }

  for (final platform in platforms) {
    testWidgets('P12 編輯個人資料：導覽列儲存、相簿停用（${platform.name}）', (tester) async {
      setView(tester, const Size(390, 844));
      final store = await createStore([]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProfileEditor(store: store)),
        ),
      );
      if (platform == TargetPlatform.iOS) {
        expect(find.text('取消'), findsOneWidget);
      } else {
        expect(find.byTooltip('關閉'), findsOneWidget);
      }
      final save = find.byKey(const ValueKey('profile-save'));
      expect(find.descendant(of: save, matching: find.text('儲存')), findsOne);
      expect(tester.getSize(save).height, greaterThanOrEqualTo(44));
      expect(find.text('從相簿選擇'), findsOneWidget);
      expect(find.text('移除頭像'), findsNothing);
      expect(find.text('照片上傳開放後才能用（社群核實 P2）。現在使用預設頭像。'), findsOneWidget);
      await tester.tap(find.text('從相簿選擇'), warnIfMissed: false);
      await tester.pump();
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('P2 車種用語與單選語意', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VehicleChoice(
            vehicle: VehicleType.scooter,
            selected: true,
            onTap: _noop,
          ),
        ),
      ),
    );
    expect(find.text('綠牌・白牌，未滿 250cc'), findsOneWidget);
    expect(find.text('可停一般機車格與普大共用格；重機專用格不能停'), findsOneWidget);
    final data = tester
        .getSemantics(find.byType(VehicleChoice))
        .getSemanticsData();
    expect(data.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
    expect(data.flagsCollection.isChecked, isNotNull);
    handle.dispose();
  });
}

void _noop() {}

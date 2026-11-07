import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/favorite_handles.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/content_report_display.dart';
import 'package:motorcycle_parking/domain/hidden_riders_display.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/domain/spot_contributor.dart';
import 'package:motorcycle_parking/features/content_report/content_report.dart';
import 'package:motorcycle_parking/features/contribute/contribute_page.dart';
import 'package:motorcycle_parking/features/favorites/favorites_page.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 't280_harness.dart';

const handleA = '3fa8c1d27b9e40a6c55d0e1f2a3b4c5d';
const handleK = '0123456789abcdef0123456789abcdef';

ParkingSpot spot(
  String id,
  String name, {
  String? handle,
  String contributor = '',
  String role = 'rider',
  String source = 'community',
  bool own = false,
  double lat = 25.0339,
  double lng = 121.5623,
}) => ParkingSpot(
  id: id,
  name: name,
  lat: lat,
  lng: lng,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
  source: source,
  contributorName: contributor,
  contributorRole: role,
  contributorHandle: handle,
  isOwn: own,
);

final amin = spot('a', '阿明的機車格', handle: handleA, contributor: '阿明');
final ken = spot(
  'k',
  'Ken 的機車格',
  handle: handleK,
  contributor: 'Ken',
  lat: 25.0341,
);

/// A viewport that always answers with [spots].
class FixedParking extends ParkingRepository {
  FixedParking(this.spots) : super(null);
  List<ParkingSpot> spots;
  ParkingSpot? latest;
  @override
  Future<ParkingResult> inViewport(MapViewport bounds) async =>
      ParkingResult(spots);
  @override
  Future<ParkingSpot?> byId(String id) async => latest;
}

class FixedHandles implements FavoriteHandles {
  const FixedHandles(this.handles, {this.own = const {}});
  final Map<String, String> handles;
  final Set<String> own;
  @override
  Future<Map<String, FavoriteFacts>> handlesFor(List<String> ids) async => {
    for (final id in ids) id: (handle: handles[id], isOwn: own.contains(id)),
  };
}

Future<AppStore> storeOf(
  List<ParkingSpot> spots, {
  FavoriteHandles favoriteHandles = const NoFavoriteHandles(),
}) async {
  SharedPreferences.setMockInitialValues({});
  final store = AppStore(
    LocalRepository(await SharedPreferences.getInstance()),
    null,
    parkingRepository: FixedParking(spots),
    favoriteHandles: favoriteHandles,
  );
  await store.init();
  return store;
}

/// Answers a look-up only when told to.
class GatedHandles implements FavoriteHandles {
  final answer = Completer<Map<String, FavoriteFacts>>();
  @override
  Future<Map<String, FavoriteFacts>> handlesFor(List<String> ids) =>
      answer.future;
}

/// A store whose signed-in account the test switches, and whose reports
/// reach the backend (the sample build's never do).
class AccountStore extends AppStore {
  AccountStore(
    LocalRepository local,
    ParkingRepository parking,
    FavoriteHandles handles,
  ) : super(local, null, parkingRepository: parking, favoriteHandles: handles);
  String account = 'rider-a';
  @override
  String get favoritesKey => account;
  @override
  String? get riderId => account;
  @override
  Future<String> submit(Map<String, dynamic> body) async {
    reportsSent++;
    notifyListeners();
    return 'ok';
  }
}

void main() {
  group('P17a ⑤ 六種點位的選單', () {
    test('依點位決定項目', () async {
      SharedPreferences.setMockInitialValues({});
      final store = await storeOf(const []);
      final hidden = store.hiddenRiders;
      SpotMenu menu(ParkingSpot s) => spotMenu(s, hidden);

      // 1 車友新增，有公開名稱
      expect(menu(amin), (
        show: true,
        byRider: true,
        hide: true,
        unhide: false,
      ));
      // 2 拿過代號，現在沒有公開名稱
      expect(menu(spot('n', '無名', handle: handleK)), (
        show: true,
        byRider: true,
        hide: true,
        unhide: false,
      ));
      // 3 從來沒有公開過名稱：沒有代號，只能檢舉
      expect(menu(spot('x', '沒代號')), (
        show: true,
        byRider: true,
        hide: false,
        unhide: false,
      ));
      // 4 管理員新增或匯入
      expect(menu(spot('i', '匯入', source: 'import', role: 'import')), (
        show: true,
        byRider: false,
        hide: false,
        unhide: false,
      ));
      expect(menu(spot('m', '管理員', role: 'admin')), (
        show: true,
        byRider: false,
        hide: false,
        unhide: false,
      ));
      // 5 自己新增的點
      expect(menu(spot('o', '自己', handle: handleA, own: true)).show, isFalse);
      // 6 官方點，就算帶了代號也不顯示
      expect(
        menu(spot('official:1', '官方', handle: handleA, source: 'official'))
            .show,
        isFalse,
      );
      // Hidden: 解除隱藏 instead of 隱藏.
      await hidden.hide(handle: handleA, name: '阿明', spotName: '');
      expect(menu(amin), (
        show: true,
        byRider: true,
        hide: false,
        unhide: true,
      ));
    });

    test('欄位缺少或是 null：不顯示隱藏，也不當成自己的點', () {
      for (final json in [
        <String, dynamic>{},
        {'contributor_handle': null, 'is_own': null},
        {'contributor_handle': 42, 'is_own': 'true'},
      ]) {
        final s = ParkingSpot.fromJson({
          'id': 'j',
          'name': '舊資料',
          'lat': 25.0,
          'lng': 121.5,
          'city': '臺北市',
          'space_type': 'paidMotorcycle',
          'source': 'community',
          'contributor_name': '阿明',
          ...json,
        });
        expect(riderHandle(s), isNull);
        expect(isOwnSpot(s), isFalse);
      }
    });
  });

  group('過濾與自己的代號', () {
    test('隱藏後地圖資料拿掉他的點，改名後仍隱藏，解除後回來', () async {
      final store = await storeOf([amin, ken]);
      expect(store.spots.map((s) => s.id), ['a', 'k']);
      await store.hiddenRiders.hide(
        handle: handleA,
        name: '阿明',
        spotName: amin.name,
      );
      expect(store.spots.map((s) => s.id), ['k']);
      // Renamed: the handle still matches.
      (store.parking as FixedParking).spots = [
        spot('a2', '新名字的點', handle: handleA, contributor: '改名了'),
        ken,
      ];
      await store.refresh();
      expect(store.spots.map((s) => s.id), ['k']);
      await store.hiddenRiders.unhide(handleA);
      expect(store.spots.map((s) => s.id), ['a2', 'k']);
    });

    test('登入後看到自己的點：自己的代號從清單移除', () async {
      final store = await storeOf([amin]);
      await store.hiddenRiders.hide(
        handle: handleA,
        name: '阿明',
        spotName: amin.name,
      );
      expect(store.spots, isEmpty);
      (store.parking as FixedParking).spots = [
        spot('a', '阿明的機車格', handle: handleA, contributor: '阿明', own: true),
      ];
      await store.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(store.hiddenRiders.isHidden(handleA), isFalse);
      expect(store.spots.map((s) => s.id), ['a']);
    });

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 地圖搜尋不顯示被隱藏車友的點', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(() => storeOf([amin, ken])))!;
        await tester.runAsync(
          () => store.hiddenRiders.hide(
            handle: handleA,
            name: '阿明',
            spotName: amin.name,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: const ParkingApp(),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('parking-search'));
        await tester.tap(input);
        await tester.enterText(input, '機車格');
        await tester.pumpAndSettle();
        expect(find.text('Ken 的機車格'), findsWidgets);
        expect(find.text('阿明的機車格'), findsNothing);
      });
    }

    testWidgetsOn('附近清單不顯示被隱藏車友的點', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      final store = (await tester.runAsync(() => storeOf([amin, ken])))!;
      await tester.runAsync(
        () => store.hiddenRiders.hide(
          handle: handleA,
          name: '阿明',
          spotName: amin.name,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [storeProvider.overrideWith((ref) => store)],
          child: const MaterialApp(home: Scaffold(body: ContributePage())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ken 的機車格'), findsOneWidget);
      expect(find.text('阿明的機車格'), findsNothing);
    });
  });

  group('隱藏與復原（詳情 ⋯）', () {
    Future<void> openDetails(WidgetTester tester, AppStore store) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSpot(context, store, amin),
                child: const Text('details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('details'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('parking-spot-sheet')),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('spot-more')),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('parking-spot-sheet')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
    }

    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        testWidgetsOn('${platform.name} $name：隱藏、關閉詳情、復原', (tester) async {
          setUpView(tester, platform, size);
          final store = (await tester.runAsync(() => storeOf([amin, ken])))!;
          await openDetails(tester, store);
          await tester.tap(find.byKey(const ValueKey('spot-more')));
          await tester.pumpAndSettle();
          expect(find.text(hideRiderAction), findsOneWidget);
          expect(find.text(reportContentAction), findsOneWidget);
          await tester.tap(find.text(hideRiderAction));
          await tester.pumpAndSettle();
          expect(find.text(hideRiderConfirmBody('阿明')), findsOneWidget);
          await tester.tap(find.text(hideRiderConfirm));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(store.hiddenRiders.isHidden(handleA), isTrue);
          expect(store.hiddenRiders.riders.single.spotName, amin.name);
          expect(store.spots.map((s) => s.id), ['k']);
          // The details closed; the toast offers 復原.
          expect(
            find.byKey(const ValueKey('parking-spot-sheet')),
            findsNothing,
          );
          expect(find.text('已隱藏阿明'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('undo-toast-action')));
          await tester.pumpAndSettle();
          expect(store.hiddenRiders.isHidden(handleA), isFalse);
          expect(store.spots.map((s) => s.id), ['a', 'k']);
        });
      }
    }

    testWidgetsOn('取消確認：不隱藏', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      final store = (await tester.runAsync(() => storeOf([amin])))!;
      await openDetails(tester, store);
      await tester.tap(find.byKey(const ValueKey('spot-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(hideRiderAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(hideRiderCancel));
      await tester.pumpAndSettle();
      expect(store.hiddenRiders.isEmpty, isTrue);
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsOneWidget);
    });
  });

  group('P17d 收藏', () {
    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 被隱藏車友的收藏：標示、提示、解除隱藏', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final semantics = tester.ensureSemantics();
        // Far from the viewport, so only spots_by_ids knows its handle.
        final saved = spot('fav', '收藏的機車格', lat: 24.5, lng: 121.0);
        final store = (await tester.runAsync(() async {
          final s = await storeOf([
            ken,
          ], favoriteHandles: const FixedHandles({'fav': handleA}));
          await s.local.setFavorites(s.favoritesKey, [saved]);
          await s.loadFavorites();
          await s.hiddenRiders.hide(handle: handleA, name: '阿明', spotName: '');
          return s;
        }))!;
        expect(store.favoriteHandles, {'fav': handleA});
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: app(const Scaffold(body: FavoritesPage())),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(hiddenFavoriteNote('阿明')), findsOneWidget);
        expect(find.bySemanticsLabel('解除隱藏 阿明'), findsOneWidget);

        // Opening it shows the banner and 解除隱藏 in ⋯.
        await tester.tap(find.text('收藏的機車格'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('hidden-spot-banner')),
          findsOneWidget,
        );
        expect(find.text(hiddenSpotBanner('阿明')), findsOneWidget);
        await tester.tap(
          find.descendant(
            of: find.byKey(const ValueKey('hidden-spot-banner')),
            matching: find.byKey(const ValueKey('unhide-$handleA')),
          ),
        );
        await tester.pumpAndSettle();
        expect(store.hiddenRiders.isHidden(handleA), isFalse);
        expect(find.byKey(const ValueKey('hidden-spot-banner')), findsNothing);
        semantics.dispose();
      });
    }

    test('收藏時記下手上的代號，快照不存', () async {
      final store = await storeOf([amin]);
      await store.toggleFavorite(amin);
      expect(store.favoriteHandles['a'], handleA);
      expect(
        store.favorites.single.toJson(),
        isNot(contains('contributor_handle')),
      );
    });
  });

  group('Codex 第 1 輪', () {
    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 自己的收藏：查回 is_own，詳情沒有 ⋯，代號移出清單', (
        tester,
      ) async {
        setUpView(tester, platform, const Size(390, 844));
        final saved = spot('mine', '我新增的機車格', lat: 24.5, lng: 121.0);
        final store = (await tester.runAsync(() async {
          final s = await storeOf(
            const [],
            favoriteHandles: const FixedHandles(
              {'mine': handleA},
              own: {'mine'},
            ),
          );
          // Hidden as a guest before signing in.
          await s.hiddenRiders.hide(handle: handleA, name: '我', spotName: '');
          await s.local.setFavorites(s.favoritesKey, [saved]);
          await s.loadFavorites();
          await Future<void>.delayed(Duration.zero);
          return s;
        }))!;
        expect(store.ownSpot(saved), isTrue);
        expect(store.hiddenRiders.isHidden(handleA), isFalse);
        expect(
          spotMenu(saved, store.hiddenRiders, own: store.ownSpot(saved)).show,
          isFalse,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: app(const Scaffold(body: FavoritesPage())),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('我新增的機車格'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('parking-spot-sheet')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('spot-more')), findsNothing);
      });

      testWidgetsOn('${platform.name} ⋯ 與解除隱藏：螢幕閱讀器點兩下也有作用', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(() => storeOf([amin])))!;
        final semantics = tester.ensureSemantics();
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSpot(context, store, amin),
                  child: const Text('details'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('details'));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const ValueKey('parking-spot-sheet')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('spot-more')),
          200,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('parking-spot-sheet')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        tester.semantics.tap(find.semantics.byLabel('這筆回報：更多動作'));
        await tester.pumpAndSettle();
        expect(find.text(hideRiderAction), findsOneWidget);
        expect(find.text(reportContentAction), findsOneWidget);
        // Close the menu, hide from elsewhere, then unhide by activation.
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => store.hiddenRiders.hide(
            handle: handleA,
            name: '阿明',
            spotName: amin.name,
          ),
        );
        await tester.pumpAndSettle();
        tester.semantics.tap(find.semantics.byLabel('解除隱藏 阿明'));
        await tester.pumpAndSettle();
        expect(store.hiddenRiders.isHidden(handleA), isFalse);
        semantics.dispose();
      });
    }

    testWidgetsOn('修改建議 › 內容不當 → 隱藏：修改建議和詳情都關閉', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      final store = (await tester.runAsync(() => storeOf([amin, ken])))!;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSpot(context, store, amin),
                child: const Text('details'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('details'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改建議').last);
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('suggest-content-report'));
      // Pinned once: the title scrolls away with the list.
      final list = tester.element(
        find
            .ancestor(
              of: find.text('提出修改建議'),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.scrollUntilVisible(
        row,
        200,
        scrollable: find.byElementPredicate((e) => e == list),
      );
      await Scrollable.ensureVisible(tester.element(row), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(ContentReportSheet), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('content-report-spot_name')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('content-report-submit')));
      await tester.pumpAndSettle();
      expect(find.text(contentReportSentTitle), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('content-report-hide')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(hideRiderConfirm));
      await tester.pumpAndSettle();
      expect(store.hiddenRiders.isHidden(handleA), isTrue);
      expect(find.byType(ContentReportSheet), findsNothing);
      expect(find.text('提出修改建議'), findsNothing);
      expect(find.byKey(const ValueKey('parking-spot-sheet')), findsNothing);
      expect(find.text('已隱藏阿明'), findsOneWidget);
    });
  });

  group('Codex 第 2 輪', () {
    test('A 的收藏查詢未回應就換成 B：不覆寫 B 的資料，也不解除 B 的隱藏', () async {
      SharedPreferences.setMockInitialValues({});
      final handles = GatedHandles();
      final saved = spot('fav', '收藏的機車格');
      final store = AccountStore(
        LocalRepository(await SharedPreferences.getInstance()),
        FixedParking(const []),
        handles,
      );
      await store.local.setFavorites('rider-a', [saved]);
      final loading = store.loadFavorites();
      await pumpEventQueue();
      // Now B, who hid that very handle.
      store.account = 'rider-b';
      await store.hiddenRiders.hide(handle: handleA, name: '阿明', spotName: '');
      handles.answer.complete({'fav': (handle: handleA, isOwn: true)});
      await loading;
      await pumpEventQueue();
      expect(store.favoriteHandles, isEmpty);
      expect(store.favoriteOwn, isEmpty);
      expect(store.hiddenRiders.isHidden(handleA), isTrue);
    });

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 檢舉成功回到詳情：改讀最新點位', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final parking = FixedParking([amin]);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          return AccountStore(
            LocalRepository(await SharedPreferences.getInstance()),
            parking,
            const NoFavoriteHandles(),
          );
        }))!;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSpot(context, store, amin),
                  child: const Text('details'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('details'));
        await tester.pumpAndSettle();
        expect(find.text('阿明的機車格'), findsWidgets);
        // The backend now hides the reported name.
        parking.latest = spot('a', '名稱審核中', handle: handleA);
        final sheet = find.byKey(const ValueKey('parking-spot-sheet'));
        final context = tester.element(sheet);
        unawaited(showContentReport(context, store, amin));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('content-report-spot_name')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('content-report-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('content-report-done')));
        await tester.pumpAndSettle();
        expect(find.text('名稱審核中'), findsWidgets);
        expect(find.text('阿明的機車格'), findsNothing);
      });
    }
  });

  group('Codex 第 3 輪：換帳號', () {
    final mine = spot(
      'm',
      '我新增的機車格',
      handle: handleA,
      contributor: '阿明',
      own: true,
    );

    Future<AccountStore> accountStore(FixedParking parking) async {
      SharedPreferences.setMockInitialValues({});
      return AccountStore(
        LocalRepository(await SharedPreferences.getInstance()),
        parking,
        const NoFavoriteHandles(),
      );
    }

    test('舊快照的 isOwn 不屬於新帳號：查到最新資料前都不算自己的', () async {
      final parking = FixedParking([mine]);
      final store = await accountStore(parking);
      await store.refresh();
      expect(store.ownSpot(mine), isTrue);
      expect(store.canReportContent(mine), isFalse);

      store.account = 'rider-b';
      expect(store.ownSpot(mine), isFalse);
      expect(store.canReportContent(mine), isTrue);
      expect(
        spotMenu(mine, store.hiddenRiders, own: store.ownSpot(mine)).hide,
        isTrue,
      );
      await store.hiddenRiders.hide(handle: handleA, name: '阿明', spotName: '');
      expect(store.riderHidden(mine), isTrue);
      // The rows still loaded are A's: B's hiding applies to them too.
      expect(store.spots, isEmpty);
    });

    test('同一個帳號：視野移開後，開著的點仍算自己的', () async {
      final parking = FixedParking([mine]);
      final store = await accountStore(parking);
      await store.refresh();
      parking.spots = const [];
      await store.refresh();
      expect(store.ownSpot(mine), isTrue);
    });

    test('從別的帳號的讀取回來時才換帳號：結果不寫入', () async {
      final parking = FixedParking([mine])..latest = mine;
      final store = await accountStore(parking);
      final reading = store.latestSpot('m');
      store.account = 'rider-b';
      expect(await reading, isNull);
      expect(store.ownSpot(mine), isFalse);
    });

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} A 開著自己的點，換 B：⋯ 出現，B 的隱藏生效', (
        tester,
      ) async {
        setUpView(tester, platform, const Size(390, 844));
        final parking = FixedParking([mine]);
        final store = (await tester.runAsync(() async {
          final s = await accountStore(parking);
          await s.refresh();
          return s;
        }))!;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSpot(context, store, mine),
                  child: const Text('details'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('details'));
        await tester.pumpAndSettle();
        final sheet = find.byKey(const ValueKey('parking-spot-sheet'));
        await tester.drag(sheet, const Offset(0, -600));
        await tester.pumpAndSettle();
        final more = find.byKey(const ValueKey('spot-more'));
        expect(more, findsNothing);

        // Signed out and in as B; B reads the same spot, not as its own.
        parking
          ..spots = [spot('m', '我新增的機車格', handle: handleA, contributor: '阿明')]
          ..latest = spot('m', '我新增的機車格', handle: handleA, contributor: '阿明');
        store.account = 'rider-b';
        store.notifyListeners();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          more,
          200,
          scrollable: find
              .descendant(of: sheet, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text(hideRiderAction), findsOneWidget);
        expect(find.text(reportContentAction), findsOneWidget);
        await tester.tap(find.text(hideRiderAction));
        await tester.pumpAndSettle();
        await tester.tap(find.text(hideRiderConfirm));
        await tester.pumpAndSettle();
        expect(store.hiddenRiders.isHidden(handleA), isTrue);
        expect(store.riderHidden(mine), isTrue);
      });

      testWidgetsOn('${platform.name} 讀不回來：舊快照的 isOwn 仍當成 false', (
        tester,
      ) async {
        setUpView(tester, platform, const Size(390, 844));
        final parking = FixedParking([mine]);
        final store = (await tester.runAsync(() async {
          final s = await accountStore(parking);
          await s.refresh();
          return s;
        }))!;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSpot(context, store, mine),
                  child: const Text('details'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('details'));
        await tester.pumpAndSettle();
        final sheet = find.byKey(const ValueKey('parking-spot-sheet'));
        await tester.drag(sheet, const Offset(0, -600));
        await tester.pumpAndSettle();
        store.account = 'rider-b';
        store.notifyListeners();
        await tester.pumpAndSettle();
        final more = find.byKey(const ValueKey('spot-more'));
        await tester.scrollUntilVisible(
          more,
          200,
          scrollable: find
              .descendant(of: sheet, matching: find.byType(Scrollable))
              .first,
        );
        expect(more, findsOneWidget);
      });
    }
  });
}

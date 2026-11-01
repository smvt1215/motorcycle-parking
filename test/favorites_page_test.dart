import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/geo.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/domain/favorites_display.dart';
import 'package:motorcycle_parking/features/favorites/favorite_card.dart';
import 'package:motorcycle_parking/features/favorites/favorites_page.dart';
import 'package:motorcycle_parking/features/my_parking/parking_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/four_sign_plates.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_test.dart' show testStore;

/// Three favourites saved farthest first, with the device located, so
/// distance order differs from saved order.
Future<(AppStore, List<ParkingSpot>)> _store(WidgetTester tester) async {
  final store = (await tester.runAsync(testStore))!;
  store
    ..located = true
    ..lat = 25.0339
    ..lng = 121.5623;
  double away(ParkingSpot s) =>
      distanceMeters(store.lat, store.lng, s.lat, s.lng);
  final near = [...store.spots]..sort((a, b) => away(a).compareTo(away(b)));
  final picked = [near[0], near[3], near[6]];
  store.favorites = picked.reversed.toList();
  return (store, picked);
}

Future<GoRouter> _pump(WidgetTester tester, AppStore store, String path) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(Navigator).last));
  router.go(path);
  await tester.pumpAndSettle();
  return router;
}

String _path(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.path;

void _setUp(WidgetTester tester, TargetPlatform platform, Size size) {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('收藏未定位時照儲存順序、不顯示距離', () async {
    SharedPreferences.setMockInitialValues({});
    final store = await testStore();
    store.favorites = [store.spots[3], store.spots[1]];
    final entries = favoritesByDistance(store);
    expect(entries.map((e) => e.spot.id), [
      store.spots[3].id,
      store.spots[1].id,
    ]);
    expect(entries.every((e) => e.meters == null), isTrue);
    expect(favoritesCount(2, byDistance: false), '2 個停車點');
    expect(favoritesCount(3, byDistance: true), '3 個停車點，依距離排序');
    expect(rulesLinkSubtitle(VehicleType.heavy), '臺北市・大型重機');
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final size in const [
      Size(390, 844),
      Size(820, 1180),
      Size(1180, 820),
    ]) {
      final where =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';

      testWidgets('個人中心預覽最近 2 筆收藏的四面路牌，可到全部收藏（$where）', (tester) async {
        _setUp(tester, platform, size);
        final (store, picked) = await _store(tester);
        final router = await _pump(tester, store, '/parking');
        final page = find.byType(ParkingPage);
        expect(page, findsOneWidget);
        // The avatar beside the title opens the account sheet.
        expect(find.byTooltip(accountSettingsLabel), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('account-avatar'))).height,
          greaterThanOrEqualTo(44),
        );
        // The nearest two, in that order; the third waits on P6.
        final first = find.byKey(ValueKey('favorite-${picked[0].id}'));
        final second = find.byKey(ValueKey('favorite-${picked[1].id}'));
        expect(first, findsOneWidget);
        expect(second, findsOneWidget);
        expect(find.byKey(ValueKey('favorite-${picked[2].id}')), findsNothing);
        expect(
          tester.getTopLeft(first).dy,
          lessThan(tester.getTopLeft(second).dy),
        );
        expect(
          find.descendant(of: page, matching: find.byType(FourSignPlates)),
          findsNWidgets(2),
        );
        for (final p in picked.take(2)) {
          final plates = find.byKey(ValueKey('favorite-plates-${p.id}'));
          expect(
            find.descendant(
              of: plates,
              matching: find.byKey(const ValueKey('four-sign-verdict')),
            ),
            findsOneWidget,
          );
        }
        final rules = rulesLinkSubtitle(store.vehicle);
        await tester.scrollUntilVisible(
          find.text(rules),
          200,
          scrollable: find
              .descendant(of: page, matching: find.byType(Scrollable))
              .first,
        );
        expect(find.text(rules), findsOneWidget);
        final all = find.byKey(const ValueKey('all-favorites'));
        expect(find.text(showAllFavorites(3)), findsOneWidget);
        expect(tester.getSize(all).height, greaterThanOrEqualTo(44));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(all);
        await tester.pumpAndSettle();
        await tester.tap(all);
        await tester.pumpAndSettle();
        expect(_path(router), '/favorites');
        expect(find.byType(FavoritesPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('我的收藏依距離排序，每張卡四面路牌，可取消收藏（$where）', (tester) async {
        _setUp(tester, platform, size);
        final (store, picked) = await _store(tester);
        await _pump(tester, store, '/favorites');
        final page = find.byType(FavoritesPage);
        expect(find.text(favoritesCount(3, byDistance: true)), findsOneWidget);
        final cards = [
          for (final p in picked) find.byKey(ValueKey('favorite-${p.id}')),
        ];
        for (final c in cards) {
          await tester.ensureVisible(c);
          expect(c, findsOneWidget);
        }
        await tester.pumpAndSettle();
        double top(Finder f) => tester.getTopLeft(f).dy;
        final ordered = [for (final c in cards) top(c)];
        expect(ordered, [...ordered]..sort());
        expect(
          find.descendant(of: page, matching: find.byType(FourSignPlates)),
          findsNWidgets(3),
        );
        final bookmark = find.byTooltip(unfavoriteLabel(picked[0].name));
        await tester.ensureVisible(bookmark);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSize(
                find.ancestor(of: bookmark, matching: find.byType(IconButton)),
              )
              .height,
          greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
        );
        expect(tester.takeException(), isNull);
        await tester.tap(bookmark);
        await tester.pumpAndSettle();
        expect(store.favorites.map((s) => s.id), isNot(contains(picked[0].id)));
        expect(find.text(favoritesCount(2, byDistance: true)), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('我的收藏空狀態可去探索（$where）', (tester) async {
        _setUp(tester, platform, size);
        final store = (await tester.runAsync(testStore))!;
        final router = await _pump(tester, store, '/favorites');
        expect(find.byKey(const ValueKey('favorites-empty')), findsOneWidget);
        expect(find.text(favoritesEmptyTitle), findsOneWidget);
        expect(find.text(favoritesEmptyBody), findsOneWidget);
        final explore = find.byKey(const ValueKey('favorites-explore'));
        expect(tester.getSize(explore).height, greaterThanOrEqualTo(44));
        expect(tester.takeException(), isNull);
        await tester.tap(explore);
        await tester.pumpAndSettle();
        expect(_path(router), '/map');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}

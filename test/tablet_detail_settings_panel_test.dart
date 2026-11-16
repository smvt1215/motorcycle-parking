import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/hidden_riders_display.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/favorites/favorite_card.dart';
import 'package:motorcycle_parking/features/hidden_riders/hidden_riders_page.dart';
import 'package:motorcycle_parking/features/map/spot_preview.dart';
import 'package:motorcycle_parking/features/map/spot_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/map_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'spot_detail_fixtures.dart';

/// The tablet layout's third step (#190 PR-F2 layer 2): a spot's details
/// opened from 收藏 or 我的貢獻 (Q190L2-1), 帳號與設定 (P10) and 已隱藏的
/// 車友 (P17c, Q190L2-4) take the side panel's place on iPad and Android
/// tablets; what opens from them stacks in the same place under the one
/// scrim; the phone layout is as it was.
const _sidePanel = ValueKey('side-panel');
const _sheet = ValueKey('parking-spot-sheet');
const _scrim = Color(0x6116313a);

const _tablets = [Size(820, 1180), Size(1180, 820)];
const _iPad = Size(1024, 1366);
const _iPhone = Size(430, 932);

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

void _size(WidgetTester tester, Size size, {Size? device}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.display.size = device ?? size;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.display.reset);
}

Future<void> _rest(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

/// A first page with one button for [open], marked as the shell's page
/// unless [shell] is false (a page of its own).
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  Size? device,
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool shell = true,
  required Future<void> Function(BuildContext context) open,
}) async {
  _size(tester, size, device: device);
  final page = Scaffold(
    body: Builder(
      builder: (context) => Align(
        alignment: Alignment.topRight,
        child: TextButton(
          onPressed: () => open(context),
          child: const Text('開啟'),
        ),
      ),
    ),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        brightness: brightness,
        colorScheme: ColorScheme.fromSeed(
          seedColor: brand,
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: shell ? SidePanelHost(child: page) : page,
    ),
  );
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
  await _rest(tester);
}

/// The panel column under the search field at text size 1.
Rect _column(Size size) => Rect.fromLTRB(
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter,
  4 + 52 + sidePanelGap,
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter + sidePanelWidth,
  size.height,
);

Rect _panel(WidgetTester tester) =>
    tester.getRect(find.byKey(_sidePanel).hitTestable().last);

List<Color> _scrims(WidgetTester tester) => [
  for (final barrier in tester.widgetList<ModalBarrier>(
    find.byType(ModalBarrier),
  ))
    ?barrier.color,
];

void _expectInside(WidgetTester tester, Finder target, Rect panel) {
  final rect = tester.getRect(target);
  expect(rect.left, greaterThanOrEqualTo(panel.left), reason: '$target');
  expect(rect.right, lessThanOrEqualTo(panel.right), reason: '$target');
  expect(rect.top, greaterThanOrEqualTo(panel.top), reason: '$target');
  expect(rect.bottom, lessThanOrEqualTo(panel.bottom), reason: '$target');
}

/// Signed out: 登入 opens instead of the forms.
class _SignedOut extends AppStore {
  _SignedOut(LocalRepository local)
    : super(local, null, clock: () => detailDay);
  @override
  bool get canReport => false;
}

Future<_SignedOut> _signedOut(WidgetTester tester) async {
  final s = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    final s = _SignedOut(
      LocalRepository(await SharedPreferences.getInstance()),
    );
    await s.init();
    return s;
  }))!;
  addTearDown(s.dispose);
  return s;
}

Finder get _panelScroll => find.byKey(const ValueKey('spot-panel-scroll'));

void main() {
  group('從收藏／我的貢獻打開的詳情（Q190L2-1）', () {
    for (final size in _tablets) {
      for (final spot in [detailLot, detailStreet]) {
        testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()} '
            '${spot.isFacility ? '路外' : '路邊'}：在左側面板的位置，一層遮罩；'
            '把手、名稱與叉號在上，按鈕列在底，叉號關閉', (tester) async {
          final store = await detailStore(tester, VehicleType.scooter);
          await _pump(
            tester,
            size: size,
            open: (context) => showSpot(context, store, spot),
          );
          expect(tester.takeException(), isNull);
          final panel = _panel(tester);
          expect(panel, _column(size));
          expect(_scrims(tester), [_scrim]);
          // The panel's own details, not the phone's draggable card.
          expect(find.byType(DraggableScrollableSheet), findsNothing);
          final sheet = find.byKey(_sheet);
          expect(
            tester.widget<SpotSheet>(find.byType(SpotSheet)).panel,
            isTrue,
          );
          expect(tester.getRect(sheet), panel);
          // One grabber: the details' own, at the top of the panel.
          final grabber = find.byType(SidePanelGrabber);
          expect(grabber, findsOneWidget);
          expect(tester.getRect(grabber).top, lessThan(panel.top + 20));
          _expectInside(tester, find.text(spot.name).first, panel);
          // The actions hold the foot, one row that slides.
          final actions = find.byType(SpotPreviewActions);
          _expectInside(tester, actions, panel);
          expect(tester.getRect(actions).bottom, greaterThan(size.height - 90));
          await tester.tap(find.byTooltip('關閉詳情'));
          await tester.pumpAndSettle();
          expect(find.byKey(_sheet), findsNothing);
          expect(find.byKey(_sidePanel), findsNothing);
        }, variant: _platforms);
      }

      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '返回鍵與點遮罩都關閉', (tester) async {
        final store = await detailStore(tester, VehicleType.scooter);
        await _pump(
          tester,
          size: size,
          open: (context) => showSpot(context, store, detailLot),
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byKey(_sheet), findsNothing);
        await tester.tap(find.text('開啟'));
        await _rest(tester);
        expect(find.byKey(_sheet), findsOneWidget);
        await tester.tapAt(Offset(size.width - 20, size.height - 20));
        await tester.pumpAndSettle();
        expect(find.byKey(_sheet), findsNothing);
      }, variant: _platforms);
    }

    for (final (scale, brightness) in [
      (1.3, Brightness.light),
      (2.0, Brightness.dark),
    ]) {
      testWidgets('平板 1180×820 字級 $scale ${brightness.name}：'
          '不溢位，內容捲到底，按鈕列仍在面板內', (tester) async {
        const size = Size(1180, 820);
        final store = await detailStore(tester, VehicleType.scooter);
        await _pump(
          tester,
          size: size,
          scale: scale,
          brightness: brightness,
          open: (context) => showSpot(context, store, detailStreet),
        );
        expect(tester.takeException(), isNull);
        final panel = _panel(tester);
        expect(panel.width, sidePanelWidth);
        await tester.drag(_panelScroll, const Offset(0, -6000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _expectInside(tester, find.byType(SpotPreviewActions), panel);
      }, variant: _platforms);
    }

    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '從面板內的詳情開修改建議，疊在同一個位置、不加深遮罩，關閉後回到詳情', (tester) async {
        final store = await detailStore(tester, VehicleType.scooter);
        await _pump(
          tester,
          size: size,
          open: (context) => showSpot(context, store, detailLot),
        );
        final panel = _panel(tester);
        await tester.tap(find.byKey(const ValueKey('spot-suggest')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SuggestionListPage), findsOneWidget);
        expect(_panel(tester), panel);
        expect(_scrims(tester), [_scrim]);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(SuggestionListPage), findsNothing);
        expect(find.byKey(_sheet), findsOneWidget);
        expect(_panel(tester), panel);
      }, variant: _platforms);
    }

    testWidgets('平板：沒登入時從面板內的詳情開登入，疊在同一個位置', (tester) async {
      const size = Size(820, 1180);
      final store = await _signedOut(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => showSpot(context, store, detailLot),
      );
      final panel = _panel(tester);
      final context = tester.element(find.byKey(_sheet));
      showSignIn(context, store);
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(_panel(tester), panel);
      expect(_scrims(tester), [_scrim]);
    }, variant: _platforms);

    for (final (name, size, device) in const [
      ('手機 390×844', Size(390, 844), null),
      ('iPad 分割畫面一半 590×820', Size(590, 820), _iPad),
      ('手機接大視窗 1180×820', Size(1180, 820), _iPhone),
    ]) {
      testWidgets('$name：照舊是置中的底部卡片，不加遮罩', (tester) async {
        final store = await detailStore(tester, VehicleType.scooter);
        await _pump(
          tester,
          size: size,
          device: device,
          open: (context) => showSpot(context, store, detailLot),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(_sidePanel), findsNothing);
        expect(find.byType(DraggableScrollableSheet), findsOneWidget);
        expect(tester.widget<SpotSheet>(find.byType(SpotSheet)).panel, isFalse);
        expect(
          tester.getSize(find.byKey(_sheet)).width,
          lessThanOrEqualTo(640),
        );
        expect(_scrims(tester), isNot(contains(_scrim)));
      }, variant: _platforms);
    }

    testWidgets('平板：自成一頁的畫面上開，照舊是置中的底部卡片', (tester) async {
      final store = await detailStore(tester, VehicleType.scooter);
      await _pump(
        tester,
        size: const Size(1180, 820),
        shell: false,
        open: (context) => showSpot(context, store, detailLot),
      );
      expect(find.byKey(_sidePanel), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
    }, variant: _platforms);

    testWidgets('平板：開著詳情時視窗變窄改成手機的卡片，變回來又回到面板', (tester) async {
      const size = Size(1180, 820);
      final store = await detailStore(tester, VehicleType.scooter);
      await _pump(
        tester,
        size: size,
        device: _iPad,
        open: (context) => showSpot(context, store, detailLot),
      );
      expect(_panel(tester), _column(size));
      // Split View: half the screen.
      tester.view.physicalSize = const Size(590, 820);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(_sidePanel), findsNothing);
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(find.text(detailLot.name), findsWidgets);
      tester.view.physicalSize = size;
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(_panel(tester), _column(size));
      expect(find.byType(DraggableScrollableSheet), findsNothing);
    }, variant: _platforms);

    for (final size in _tablets) {
      testWidgets('整個 App 平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '個人中心的收藏打開詳情，蓋在個人中心面板的同一個位置', (tester) async {
        _size(tester, size);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({
            'legendSeen': true,
            'availabilityBetaIntroSeen': true,
          });
          final s = AppStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
            clock: () => detailDay,
          );
          await s.init();
          await s.toggleFavorite(s.spots.first);
          return s;
        }))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: const ParkingApp(themeMode: ThemeMode.light),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await tester.tap(find.text('個人中心').last);
        await tester.pumpAndSettle();
        final tab = tester.getRect(
          find
              .descendant(
                of: find.byType(MapPanel),
                matching: find.byKey(_sidePanel),
              )
              .hitTestable(),
        );
        expect(find.byType(FavoriteCard), findsOneWidget);
        await tester.tap(find.byType(FavoriteCard));
        await _rest(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getRect(find.byKey(_sheet)), tab);
        expect(_scrims(tester), [_scrim]);
        // The tab's panel and its tabs are under the scrim, not reachable.
        expect(find.text('個人中心').hitTestable(), findsNothing);
        await tester.tap(find.byTooltip('關閉詳情'));
        await tester.pumpAndSettle();
        expect(find.byKey(_sheet), findsNothing);
        expect(find.text('個人中心').hitTestable(), findsWidgets);
      }, variant: _platforms);
    }
  });

  group('帳號與設定（P10）與已隱藏的車友（P17c）（Q190L2-4）', () {
    Future<AppStore> store(WidgetTester tester) async {
      final s = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        final s = AppStore(
          LocalRepository(await SharedPreferences.getInstance()),
          null,
          clock: () => detailDay,
        );
        await s.hiddenRiders.hide(
          handle: 'r_amin',
          name: '阿明',
          spotName: '市府轉運站機車區',
        );
        return s;
      }))!;
      addTearDown(s.dispose);
      return s;
    }

    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '帳號與設定在左側面板的位置，一層遮罩，點遮罩關閉', (tester) async {
        final s = await store(tester);
        await _pump(
          tester,
          size: size,
          open: (context) => showSettings(context, s),
        );
        expect(tester.takeException(), isNull);
        expect(_panel(tester), _column(size));
        expect(_scrims(tester), [_scrim]);
        _expectInside(tester, find.text('帳號與設定'), _panel(tester));
        await tester.tapAt(Offset(size.width - 20, size.height - 20));
        await tester.pumpAndSettle();
        expect(find.text('帳號與設定'), findsNothing);
      }, variant: _platforms);

      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '已隱藏的車友疊在同一個位置、不加深遮罩，返回回到帳號與設定', (tester) async {
        final s = await store(tester);
        await _pump(
          tester,
          size: size,
          open: (context) => showSettings(context, s),
        );
        final panel = _panel(tester);
        await tester.tap(find.byKey(const ValueKey('settings-hidden-riders')));
        await _rest(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(HiddenRidersPage), findsOneWidget);
        expect(_panel(tester), panel);
        expect(_scrims(tester), [_scrim]);
        _expectInside(tester, find.text(hiddenRidersTitle).last, panel);
        _expectInside(tester, find.text('阿明'), panel);
        // The header's back button (P17c ⑤⑥) leads back to 帳號與設定.
        final back = isCupertino
            ? find.text('帳號與設定').hitTestable()
            : find.byType(BackButton);
        _expectInside(tester, back, panel);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(find.byType(HiddenRidersPage), findsNothing);
        expect(_panel(tester), panel);
        expect(
          find.byKey(const ValueKey('settings-hidden-riders')),
          findsOneWidget,
        );
      }, variant: _platforms);
    }

    testWidgets('平板：解除隱藏的「復原」提示在面板內、遮罩上方，點得到', (tester) async {
      const size = Size(1180, 820);
      final s = await store(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => showSettings(context, s),
      );
      final panel = _panel(tester);
      await tester.tap(find.byKey(const ValueKey('settings-hidden-riders')));
      await _rest(tester);
      await tester.tap(find.text('解除隱藏').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final toast = find.byKey(const ValueKey('unhidden-toast'));
      expect(toast, findsOneWidget);
      _expectInside(tester, toast, panel);
      expect(s.hiddenRiders.isHidden('r_amin'), isFalse);
      await tester.tap(find.text('復原').hitTestable());
      await tester.pumpAndSettle();
      expect(s.hiddenRiders.isHidden('r_amin'), isTrue);
    }, variant: _platforms);

    testWidgets('平板：沒登入時已隱藏的車友的「登入」疊在同一個位置', (tester) async {
      const size = Size(820, 1180);
      final s = await _signedOut(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => openHiddenRiders(context, s),
      );
      final panel = _panel(tester);
      expect(panel, _column(size));
      final context = tester.element(find.byType(HiddenRidersPage));
      showSignIn(context, s);
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(_panel(tester), panel);
      expect(_scrims(tester), [_scrim]);
    }, variant: _platforms);

    for (final (scale, brightness) in [
      (1.3, Brightness.light),
      (2.0, Brightness.dark),
    ]) {
      testWidgets('平板 1180×820 字級 $scale ${brightness.name}：'
          '帳號與設定與已隱藏的車友不溢位', (tester) async {
        final s = await store(tester);
        await _pump(
          tester,
          size: const Size(1180, 820),
          scale: scale,
          brightness: brightness,
          open: (context) => showSettings(context, s),
        );
        expect(tester.takeException(), isNull);
        expect(_panel(tester).width, sidePanelWidth);
        await tester.drag(find.byType(ListView).last, const Offset(0, -4000));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(ListView).last, const Offset(0, 4000));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-hidden-riders')));
        await _rest(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(HiddenRidersPage), findsOneWidget);
      }, variant: _platforms);
    }

    for (final (name, size, device) in const [
      ('手機 390×844', Size(390, 844), null),
      ('iPad 分割畫面一半 590×820', Size(590, 820), _iPad),
      ('手機接大視窗 1180×820', Size(1180, 820), _iPhone),
    ]) {
      testWidgets('$name：帳號與設定照舊是底部 sheet，已隱藏的車友照舊是整頁', (tester) async {
        final s = await store(tester);
        await _pump(
          tester,
          size: size,
          device: device,
          open: (context) => showSettings(context, s),
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(_sidePanel), findsNothing);
        expect(find.text('帳號與設定'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('settings-hidden-riders')));
        await tester.pumpAndSettle();
        expect(find.byType(HiddenRidersPage), findsOneWidget);
        expect(find.byKey(_sidePanel), findsNothing);
        expect(tester.getSize(find.byType(HiddenRidersPage)), size);
      }, variant: _platforms);
    }

    testWidgets('平板：開著帳號與設定時視窗變窄，改成橫跨底部的卡片，不溢位', (tester) async {
      const size = Size(1180, 820);
      final s = await store(tester);
      await _pump(
        tester,
        size: size,
        device: _iPad,
        open: (context) => showSettings(context, s),
      );
      expect(_panel(tester), _column(size));
      tester.view.physicalSize = const Size(590, 820);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(_panel(tester).width, 590);
      expect(find.text('帳號與設定'), findsOneWidget);
    }, variant: _platforms);
  });
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/account/suspended_sheet.dart';
import 'package:motorcycle_parking/features/auth/profile_editor.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/content_report/content_report.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'content_report_test.dart' show ReportStore, reportStore, riderSpot;
import 'spot_detail_fixtures.dart';

/// The tablet layout's smaller sheets (#190 PR-F2 layer 2): 登入 (P11),
/// 編輯個人資料 (P12), 帳號已暫停送出內容 (P18a), 檢舉內容不當 (P17b ⑨⑩)
/// and 記錄停車 (P5) take the side panel's place on iPad and Android
/// tablets when opened from the app's first page or from a form already
/// there, and stay the phone's bottom sheet everywhere else.
const _sidePanel = ValueKey('side-panel');
const _scrim = Color(0x6116313a);

const _tablets = [Size(820, 1180), Size(1180, 820)];
const _iPad = Size(1024, 1366);
const _iPhone = Size(430, 932);

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

/// The demo data, signed out.
class _SignedOutDemo extends AppStore {
  _SignedOutDemo(LocalRepository local)
    : super(local, null, clock: () => detailDay);
  @override
  bool get canReport => false;
}

enum _Sheet {
  signIn('登入'),
  profile('編輯個人資料'),
  suspended('帳號暫時不能送出內容'),
  contentReport('檢舉內容不當'),
  parking('記錄停車');

  const _Sheet(this.title);
  final String title;
}

Future<void> _show(BuildContext context, AppStore store, _Sheet sheet) =>
    switch (sheet) {
      _Sheet.signIn => showSignIn(context, store),
      _Sheet.profile => showProfileEditor(context, store),
      _Sheet.suspended => showSuspendedSheet(context, DateTime(2026, 12, 1)),
      _Sheet.contentReport => showContentReport(context, store, riderSpot),
      _Sheet.parking => showParkingForm(context, store),
    };

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

Future<ReportStore> _store(WidgetTester tester, {bool signedIn = true}) async {
  final store = (await tester.runAsync(reportStore))!..signedIn = signedIn;
  addTearDown(store.dispose);
  return store;
}

/// A first page with one button for [open].
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
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      // The shell marks its page; what opens from it may take the panel.
      home: shell ? SidePanelHost(child: page) : page,
    ),
  );
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
  await _rest(tester);
}

Rect _column(Size size) => Rect.fromLTRB(
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter,
  4 + 52 + sidePanelGap,
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter + sidePanelWidth,
  size.height,
);

Rect _panel(WidgetTester tester) => tester.getRect(find.byKey(_sidePanel).last);

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

void main() {
  for (final sheet in _Sheet.values) {
    group(sheet.title, () {
      for (final size in _tablets) {
        testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
            '在左側面板的位置，一層遮罩，點遮罩關閉', (tester) async {
          final store = await _store(tester, signedIn: sheet != _Sheet.signIn);
          await _pump(
            tester,
            size: size,
            open: (context) => _show(context, store, sheet),
          );
          expect(tester.takeException(), isNull);
          expect(_panel(tester), _column(size));
          expect(_scrims(tester), [_scrim]);
          final title = find.text(sheet.title);
          expect(title, findsWidgets);
          _expectInside(tester, title.first, _panel(tester));
          await tester.tapAt(Offset(size.width - 20, size.height - 20));
          await tester.pumpAndSettle();
          expect(find.byKey(_sidePanel), findsNothing);
        }, variant: _platforms);
      }

      testWidgets('平板 1180×820 放大字級深色：不溢位', (tester) async {
        final store = await _store(tester, signedIn: sheet != _Sheet.signIn);
        await _pump(
          tester,
          size: const Size(1180, 820),
          // 記錄停車's iOS segmented control (48 high) overflows by 4.5 at
          // 2.0 on a phone too, before this layout; it is checked at 1.3.
          scale: sheet == _Sheet.parking && isCupertino ? 1.3 : 2,
          brightness: Brightness.dark,
          open: (context) => _show(context, store, sheet),
        );
        expect(tester.takeException(), isNull);
        expect(_panel(tester).width, sidePanelWidth);
      }, variant: _platforms);

      for (final (name, size, device) in const [
        ('手機 390×844', Size(390, 844), null),
        ('iPad 分割畫面一半 590×820', Size(590, 820), _iPad),
        ('手機接大視窗 1180×820', Size(1180, 820), _iPhone),
      ]) {
        testWidgets('$name：照舊是底部 sheet', (tester) async {
          final store = await _store(tester, signedIn: sheet != _Sheet.signIn);
          await _pump(
            tester,
            size: size,
            device: device,
            open: (context) => _show(context, store, sheet),
          );
          expect(tester.takeException(), isNull);
          expect(find.byKey(_sidePanel), findsNothing);
          expect(find.text(sheet.title), findsWidgets);
        }, variant: _platforms);
      }
    });
  }

  group('面板內的版面', () {
    testWidgets('登入：標題、說明與登入按鈕一起在面板上方，寬度依面板', (tester) async {
      const size = Size(820, 1180);
      final store = await _store(tester, signedIn: false);
      await _pump(
        tester,
        size: size,
        open: (context) => showSignIn(context, store),
      );
      final panel = _panel(tester);
      // As short as on a phone: the title, the intro and the buttons
      // together at the top of the panel.
      final buttons = find.byType(SignInButtons);
      _expectInside(tester, buttons, panel);
      expect(tester.getSize(buttons).width, sidePanelWidth - 40);
      expect(tester.getRect(find.text('登入').first).top, lessThan(200));
      expect(tester.getRect(buttons).top, lessThan(400));
    }, variant: _platforms);

    testWidgets('檢舉內容不當：高度由面板決定（不是視窗高的 86%），送出鍵在面板底部', (tester) async {
      const size = Size(820, 1180);
      final store = await _store(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => showContentReport(context, store, riderSpot),
      );
      final panel = _panel(tester);
      final sheet = tester.getRect(find.byType(ContentReportSheet));
      expect(sheet.width, sidePanelWidth);
      expect(sheet.bottom, size.height);
      expect(sheet.top, greaterThan(panel.top));
      expect(sheet.height, isNot(size.height * .86));
      final submit = find.byKey(const ValueKey('content-report-submit'));
      _expectInside(tester, submit, panel);
      expect(tester.getRect(submit).bottom, greaterThan(size.height - 60));
    }, variant: _platforms);

    testWidgets('檢舉內容不當：鍵盤彈出時送出鍵在鍵盤上方，面板不動', (tester) async {
      const size = Size(1180, 820);
      const keyboard = 330.0;
      final store = await _store(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => showContentReport(context, store, riderSpot),
      );
      final panel = _panel(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_panel(tester), panel);
      expect(
        tester
            .getRect(find.byKey(const ValueKey('content-report-submit')))
            .bottom,
        lessThanOrEqualTo(size.height - keyboard),
      );
    }, variant: _platforms);

    for (final sheet in [_Sheet.parking, _Sheet.profile]) {
      testWidgets('${sheet.title}：鍵盤彈出時內容讓位，不溢位', (tester) async {
        const size = Size(1180, 820);
        final store = await _store(tester);
        await _pump(
          tester,
          size: size,
          open: (context) => _show(context, store, sheet),
        );
        final panel = _panel(tester);
        await tester.tap(find.byType(TextField).first);
        await tester.pump();
        tester.view.viewInsets = const FakeViewPadding(bottom: 330);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: sheet.name);
        expect(_panel(tester), panel, reason: sheet.name);
        expect(
          tester.getRect(find.byType(TextField).first).bottom,
          lessThanOrEqualTo(size.height - 330),
          reason: sheet.name,
        );
      }, variant: _platforms);
    }
  });

  group('從表單內開登入再回來', () {
    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '新增停車點按送出開登入，疊在同一個面板、不加深遮罩；登入後回到表單，內容還在', (tester) async {
        final store = await _store(tester, signedIn: false);
        await _pump(
          tester,
          size: size,
          open: (context) => showReport(context, store, 25.0339, 121.5623),
        );
        final panel = _panel(tester);
        expect(panel, _column(size));
        final name = find.widgetWithText(TextFormField, '名稱');
        await tester.ensureVisible(name);
        await tester.pumpAndSettle();
        await tester.enterText(name, '松壽地下停車場');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.tap(find.text('送出'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // 登入 over the form, in the same place.
        expect(find.byType(SignInSheet), findsOneWidget);
        expect(find.byKey(_sidePanel), findsNWidgets(2));
        expect(_panel(tester), panel);
        expect(_scrims(tester), [_scrim]);
        expect(tester.getSize(find.byType(SignInSheet)).width, sidePanelWidth);
        // Signing in closes it; the form is as it was left.
        store.signedIn = true;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        store.notifyListeners();
        await _rest(tester);
        expect(find.byType(SignInSheet), findsNothing);
        expect(find.byKey(_sidePanel), findsOneWidget);
        expect(_panel(tester), panel);
        expect(find.byType(ReportForm), findsOneWidget);
        expect(find.text('松壽地下停車場'), findsOneWidget);
      }, variant: _platforms);
    }

    testWidgets('不登入就關掉（返回）：回到表單，內容還在', (tester) async {
      const size = Size(1180, 820);
      final store = await _store(tester, signedIn: false);
      await _pump(
        tester,
        size: size,
        open: (context) => showReport(context, store, 25.0339, 121.5623),
      );
      final name = find.widgetWithText(TextFormField, '名稱');
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.enterText(name, '松壽地下停車場');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.text('送出'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SignInSheet), findsNothing);
      expect(find.byType(ReportForm), findsOneWidget);
      expect(find.text('松壽地下停車場'), findsOneWidget);
    }, variant: _platforms);

    testWidgets('手機：登入照舊是疊在表單上的底部 sheet', (tester) async {
      final store = await _store(tester, signedIn: false);
      await _pump(
        tester,
        size: const Size(390, 844),
        open: (context) => showReport(context, store, 25.0339, 121.5623),
      );
      await tester.tap(find.text('送出'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(find.byKey(_sidePanel), findsNothing);
    }, variant: _platforms);
  });

  group('整個 App', () {
    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '沒登入時從詳情按「登入後提出修改建議」，登入在詳情面板的同一個位置', (tester) async {
        _size(tester, size);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({
            'legendSeen': true,
            'availabilityBetaIntroSeen': true,
          });
          final s = _SignedOutDemo(
            LocalRepository(await SharedPreferences.getInstance()),
          );
          await s.init();
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
        await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
        await tester.pumpAndSettle();
        final detail = tester.getRect(
          find.byKey(const ValueKey('spot-side-panel')),
        );
        final signIn = find.text('登入後提出修改建議');
        await tester.scrollUntilVisible(
          signIn,
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('spot-side-panel')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(signIn);
        await tester.pumpAndSettle();
        await tester.tap(signIn);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SignInSheet), findsOneWidget);
        expect(_panel(tester), detail);
        expect(_scrims(tester), [_scrim]);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(SignInSheet), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('spot-side-panel'))),
          detail,
        );
      }, variant: _platforms);
    }
  });

  group('不在面板欄的畫面上', () {
    testWidgets('平板：自成一頁的畫面（申請刪除後的通知頁）開登入，照舊是底部 sheet', (tester) async {
      final store = await _store(tester, signedIn: false);
      await _pump(
        tester,
        size: const Size(1180, 820),
        shell: false,
        open: (context) => showSignIn(context, store),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(find.byKey(_sidePanel), findsNothing);
    }, variant: _platforms);

    testWidgets('平板：從另外推上來的整頁開登入，照舊是底部 sheet', (tester) async {
      const size = Size(1180, 820);
      final store = await _store(tester, signedIn: false);
      await _pump(
        tester,
        size: size,
        open: (context) => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (page) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSignIn(page, store),
                  child: const Text('整頁上的登入'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('整頁上的登入'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SignInSheet), findsOneWidget);
      expect(find.byKey(_sidePanel), findsNothing);
    }, variant: _platforms);

    testWidgets('平板：從橫跨視窗的底部 sheet 開編輯個人資料，照舊是底部 sheet', (tester) async {
      const size = Size(1180, 820);
      final store = await _store(tester);
      await _pump(
        tester,
        size: size,
        open: (context) => showAdaptiveSheet<void>(
          context,
          (sheet) => SizedBox(
            height: 400,
            child: Center(
              child: TextButton(
                onPressed: () => showProfileEditor(sheet, store),
                child: const Text('設定裡的編輯'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('設定裡的編輯'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ProfileEditor), findsOneWidget);
      expect(find.byKey(_sidePanel), findsNothing);
    }, variant: _platforms);

    testWidgets('平板：面板內的表單開停權說明，疊在同一個面板', (tester) async {
      const size = Size(1180, 820);
      await _pump(
        tester,
        size: size,
        open: (context) => showAdaptiveSheet<void>(
          context,
          (sheet) => Center(
            child: TextButton(
              onPressed: () => showSuspendedSheet(sheet, DateTime(2026, 12, 1)),
              child: const Text('面板內送出'),
            ),
          ),
          sidePanel: true,
        ),
      );
      final panel = _panel(tester);
      await tester.tap(find.text('面板內送出'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(SuspendedPanel), findsOneWidget);
      expect(find.byKey(_sidePanel), findsNWidgets(2));
      expect(_panel(tester), panel);
      expect(_scrims(tester), [_scrim]);
      await tester.tap(find.byKey(const ValueKey('suspended-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byType(SuspendedPanel), findsNothing);
      expect(find.text('面板內送出'), findsOneWidget);
    }, variant: _platforms);
  });
}

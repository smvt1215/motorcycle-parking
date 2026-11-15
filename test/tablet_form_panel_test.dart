import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/lookup_consent_display.dart';
import 'package:motorcycle_parking/features/map/map_legend.dart';
import 'package:motorcycle_parking/features/report/entry_pages.dart';
import 'package:motorcycle_parking/features/report/form_parts.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'location_rationale_test.dart' show FakeLocationDevice;
import 'spot_detail_fixtures.dart';

/// The tablet layout's forms (#190 PR-F2 layer 2, canvas P16b ④⑤, S6t):
/// 新增停車點 and 提出修改建議, with every page and sheet of theirs, take
/// the side panel's place on iPad and Android tablets, and stay the phone's
/// bottom sheet everywhere else.
const _detail = ValueKey('spot-side-panel');
const _sidePanel = ValueKey('side-panel');
const _scrim = Color(0x6116313a);

const _tablets = [
  Size(820, 1180),
  Size(768, 1024),
  Size(1180, 820),
  Size(1024, 768),
];

/// An iPad's display, for windows smaller than it.
const _iPad = Size(1024, 1366);
const _iPhone = Size(430, 932);

final _platforms = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

const _spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000190',
  name: '松壽地下停車場',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  district: '信義區',
  spaceType: SpaceType.freeMotorcycle,
);

/// Signed in, with lookups that answer without a network.
class _Store extends AppStore {
  _Store(LocalRepository local, {super.locationDevice}) : super(local, null);
  @override
  bool get approxAddressEnabled => true;
  @override
  bool get canReport => true;
  @override
  Future<ApproxAddress?> approxAddressAt(double lat, double lng) async =>
      const ApproxAddress('松壽路', '9');
  @override
  Future<Town?> townAt(double lat, double lng) async =>
      const Town('臺北市', '信義區');
}

enum _Form { report, suggestions }

/// The two dimensions of every case: the [device]'s display and the
/// window's [size]; without a device the window fills its display.
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

/// A page with one button that opens [form], as the map or 貢獻 does.
Future<_Store> _open(
  WidgetTester tester,
  _Form form, {
  required Size size,
  Size? device,
  String? consent = 'declined',
  double scale = 1,
  Brightness brightness = Brightness.light,
  FakeLocationDevice? location,
}) async {
  _size(tester, size, device: device);
  final store = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({'locationLookupConsent': ?consent});
    return _Store(
      LocalRepository(await SharedPreferences.getInstance()),
      locationDevice: location,
    )..spots = const [_spot];
  }))!;
  addTearDown(store.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: Alignment.topRight,
            child: TextButton(
              onPressed: () => form == _Form.report
                  ? showReport(context, store, 25.0339, 121.5623)
                  : showSpotSuggestions(context, store, _spot),
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
  await _rest(tester);
  return store;
}

Future<AppStore> _demoStore(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({
        'legendSeen': true,
        'availabilityBetaIntroSeen': true,
        'locationLookupConsent': 'declined',
      });
      final s = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        clock: () => detailDay,
      );
      await s.init();
      return s;
    }))!;

/// The whole app in range of its demo data.
Future<void> _pumpApp(
  WidgetTester tester,
  AppStore store, {
  required Size size,
  Size? device,
}) async {
  _size(tester, size, device: device);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [storeProvider.overrideWith((ref) => store)],
      child: const ParkingApp(themeMode: ThemeMode.light),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpAndSettle();
}

/// Where the panel column sits in a window of [size] (T1, T2): after
/// Android's rail, under the search field, down to the bottom.
Rect _column(Size size) => Rect.fromLTRB(
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter,
  4 + 52 + sidePanelGap,
  (isCupertino ? 0 : tabletRailWidth) + sidePanelGutter + sidePanelWidth,
  size.height,
);

Rect _panel(WidgetTester tester) => tester.getRect(find.byKey(_sidePanel).last);

/// The scrims of the open sheets, lowest first. Pages have none: the
/// first route's, and those of a form's own navigator.
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
  expect(rect.bottom, lessThanOrEqualTo(panel.bottom), reason: '$target');
}

void main() {
  group('新增停車點（N1，P16b ④⑤）', () {
    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '在左側面板的位置，整個畫面一層遮罩，送出區固定在底', (tester) async {
        await _open(tester, _Form.report, size: size);
        expect(tester.takeException(), isNull);
        final panel = _panel(tester);
        expect(panel, _column(size));
        expect(_scrims(tester), [_scrim]);
        // The form fills the panel instead of a sheet across the window.
        expect(tester.getSize(find.byType(FormFlow)).width, sidePanelWidth);
        expect(find.text('新增停車點'), findsOneWidget);
        // The send bar is pinned at the foot of the panel, on screen.
        final send = find.text('送出');
        _expectInside(tester, send, panel);
        expect(send.hitTestable(), findsOneWidget);
        expect(tester.getRect(send).bottom, greaterThan(size.height - 120));
        // The header's button closes the whole form.
        await tester.tap(find.byKey(const ValueKey('form-header-leading')));
        await tester.pumpAndSettle();
        expect(find.byType(ReportForm), findsNothing);
        expect(find.byKey(_sidePanel), findsNothing);
      }, variant: _platforms);
    }

    testWidgets('點遮罩或返回都會關閉', (tester) async {
      const size = Size(1180, 820);
      await _open(tester, _Form.report, size: size);
      await tester.tapAt(Offset(size.width - 20, size.height / 2));
      await tester.pumpAndSettle();
      expect(find.byType(ReportForm), findsNothing);
      await tester.tap(find.text('開啟'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportForm), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReportForm), findsNothing);
    }, variant: _platforms);

    testWidgets('鍵盤彈出：送出區讓到鍵盤上方，正在填的欄位看得到', (tester) async {
      const size = Size(820, 1180);
      const keyboard = 400.0;
      await _open(tester, _Form.report, size: size);
      final name = find.widgetWithText(TextFormField, '名稱');
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.tap(name);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The panel itself stays; what is in it gives way.
      expect(_panel(tester), _column(size));
      final send = tester.getRect(find.text('送出'));
      expect(send.bottom, lessThanOrEqualTo(size.height - keyboard));
      final field = tester.getRect(name);
      expect(field.bottom, lessThanOrEqualTo(size.height - keyboard));
      expect(field.top, greaterThanOrEqualTo(_column(size).top));
      await tester.enterText(name, '松壽地下停車場');
      // A tap outside the fields puts the keyboard away.
      await tester.tap(find.text('這是哪一種停車點？'));
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()),
      );
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text('松壽地下停車場'), findsOneWidget);
      expect(
        tester.getRect(find.text('送出')).bottom,
        greaterThan(size.height - 120),
      );
    }, variant: _platforms);

    testWidgets('還沒決定自動查詢（#470）：同意卡片在面板內，兩顆按鈕都按得到', (tester) async {
      const size = Size(820, 1180);
      final store = await _open(
        tester,
        _Form.report,
        size: size,
        consent: null,
      );
      expect(tester.takeException(), isNull);
      final panel = _panel(tester);
      final card = find.byKey(const ValueKey('lookup-consent-card'));
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      _expectInside(tester, card, panel);
      final agree = find.byKey(const ValueKey('lookup-consent-agree'));
      final decline = find.byKey(const ValueKey('lookup-consent-decline'));
      await tester.ensureVisible(agree);
      await tester.pumpAndSettle();
      _expectInside(tester, agree, panel);
      _expectInside(tester, decline, panel);
      expect(decline.hitTestable(), findsOneWidget);
      await tester.tap(agree);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(store.autoLookup, isTrue);
      expect(card, findsNothing);
      expect(_panel(tester), panel);
    }, variant: _platforms);

    for (final form in _Form.values) {
      testWidgets('${form.name}：沒開自動查詢時移動標記（#462 Q462-1 C），'
          '「標記移動了」的提醒在面板內完整顯示，縣市與區留著', (tester) async {
        const size = Size(820, 1180);
        await _open(tester, form, size: size);
        if (form == _Form.suggestions) {
          await tester.tap(find.text('位置'));
          await tester.pumpAndSettle();
          await _rest(tester);
        }
        final panel = _panel(tester);
        final fields = tester.widget<TownFields>(find.byType(TownFields).last);
        fields.onCity('新北市');
        fields.onDistrict('板橋區');
        await tester.pumpAndSettle();
        final dynamic state = tester.state(
          form == _Form.report
              ? find.byType(ReportForm)
              : find.byWidgetPredicate(
                  (w) => '${w.runtimeType}' == '_SuggestionForm',
                ),
        );
        state.move(25.0343, 121.5629);
        await _rest(tester);
        expect(tester.takeException(), isNull);
        final note = find.text(lookupMovedNote);
        await tester.ensureVisible(note);
        await tester.pumpAndSettle();
        expect(note.hitTestable(), findsOneWidget);
        _expectInside(tester, note, panel);
        expect(
          tester.widget<Text>(note).overflow,
          isNot(TextOverflow.ellipsis),
        );
        final town = tester.widget<TownFields>(find.byType(TownFields).last);
        expect(town.city, '新北市');
        expect(town.district, '板橋區');
        expect(_panel(tester), panel);
      }, variant: _platforms);
    }

    testWidgets('還沒問過定位時按「移到我的位置」（#469）：說明卡升起，繼續後回到面板內的表單', (tester) async {
      const size = Size(1180, 820);
      final device = FakeLocationDevice();
      await _open(tester, _Form.report, size: size, location: device);
      final panel = _panel(tester);
      double lat() =>
          (tester.state(find.byType(ReportForm)) as dynamic).lat as double;
      final before = lat();
      final locate = find.byKey(const ValueKey('location-locate')).last;
      await tester.ensureVisible(locate);
      await tester.pumpAndSettle();
      _expectInside(tester, locate, panel);
      await tester.tap(locate);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      final card = find.byKey(const ValueKey('location-rationale'));
      expect(card, findsOneWidget);
      expect(device.requests, 0);
      final go = find.byKey(const ValueKey('location-rationale-continue'));
      expect(go.hitTestable(), findsOneWidget);
      await tester.tap(go);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(card, findsNothing);
      expect(device.requests, 1);
      expect(lat(), isNot(before));
      expect(_panel(tester), panel);
      expect(find.byType(ReportForm), findsOneWidget);
    }, variant: _platforms);

    for (final (scale, brightness) in [
      (1.3, Brightness.dark),
      (2.0, Brightness.light),
    ]) {
      for (final size in const [Size(820, 1180), Size(1180, 820)]) {
        testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()} '
            '字級 $scale ${brightness.name}：不溢位，送出按得到', (tester) async {
          await _open(
            tester,
            _Form.report,
            size: size,
            scale: scale,
            brightness: brightness,
          );
          expect(tester.takeException(), isNull);
          final panel = _panel(tester);
          expect(panel.left, _column(size).left);
          expect(panel.width, sidePanelWidth);
          expect(panel.bottom, size.height);
          _expectInside(tester, find.text('送出'), panel);
          expect(find.text('送出').hitTestable(), findsOneWidget);
          // Every part of the form scrolls into the panel.
          final entrance = find.byKey(const ValueKey('report-entrance'));
          await tester.scrollUntilVisible(
            entrance,
            200,
            scrollable: find
                .descendant(
                  of: find.byType(ReportForm),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          _expectInside(tester, entrance, panel);
        }, variant: _platforms);
      }
    }

    testWidgets('表單內的頁面（停哪裡）留在同一個面板，返回回到表單', (tester) async {
      const size = Size(1180, 820);
      await _open(tester, _Form.report, size: size);
      final panel = _panel(tester);
      final kind = find.text('路外停車場');
      await tester.ensureVisible(kind);
      await tester.pumpAndSettle();
      await tester.tap(kind);
      await tester.pumpAndSettle();
      final where = find.byKey(const ValueKey('n1-where'));
      await tester.ensureVisible(where);
      await tester.pumpAndSettle();
      await tester.tap(where);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(EntryListPage), findsOneWidget);
      expect(_panel(tester), panel);
      expect(find.byKey(_sidePanel), findsOneWidget);
      expect(tester.getSize(find.byType(EntryListPage)).width, sidePanelWidth);
      // System back steps to the form first, not out of it.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(EntryListPage), findsNothing);
      expect(find.byType(ReportForm), findsOneWidget);
    }, variant: _platforms);
  });

  group('提出修改建議（S 系列，S6t）', () {
    for (final size in _tablets) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '清單在左側面板的位置；單項表單疊在同一個位置，不再加深遮罩', (tester) async {
        await _open(tester, _Form.suggestions, size: size);
        expect(tester.takeException(), isNull);
        final panel = _panel(tester);
        expect(panel, _column(size));
        expect(_scrims(tester), [_scrim]);
        expect(find.text('提出修改建議'), findsOneWidget);
        expect(
          tester.getSize(find.byType(SuggestionListPage)).width,
          sidePanelWidth,
        );
        // S2: a sheet of its own on a phone, here over the list's panel.
        await tester.tap(find.text('名稱'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('停車點名稱'), findsOneWidget);
        expect(find.byKey(_sidePanel), findsNWidgets(2));
        expect(_panel(tester), panel);
        // One scrim over the window, however many panels are stacked.
        expect(_scrims(tester), [_scrim]);
        _expectInside(tester, find.text('停車點名稱'), panel);
        // Back closes the form alone.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('停車點名稱'), findsNothing);
        expect(find.byType(SuggestionListPage), findsOneWidget);
        expect(find.byKey(_sidePanel), findsOneWidget);
        // The header closes the list.
        await tester.tap(find.byKey(const ValueKey('form-header-leading')));
        await tester.pumpAndSettle();
        expect(find.byType(SuggestionListPage), findsNothing);
      }, variant: _platforms);
    }

    testWidgets('位置（S2）：地圖與縣市欄位在面板內，鍵盤彈出時不溢位', (tester) async {
      const size = Size(820, 1180);
      await _open(tester, _Form.suggestions, size: size);
      final panel = _panel(tester);
      await tester.tap(find.text('位置'));
      await tester.pumpAndSettle();
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('停車點位置'), findsOneWidget);
      final map = find.byKey(const ValueKey('location-map-slot')).last;
      _expectInside(tester, map, panel);
      _expectInside(tester, find.byType(TownFields).last, panel);
      tester.view.viewInsets = const FakeViewPadding(bottom: 400);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_panel(tester), panel);
    }, variant: _platforms);

    testWidgets('送出一項後回到清單（S6），仍在面板內，完成固定在底', (tester) async {
      const size = Size(820, 1180);
      await _open(tester, _Form.suggestions, size: size);
      final panel = _panel(tester);
      await tester.tap(find.text('名稱'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).last, '松壽停車場');
      await tester.pumpAndSettle();
      final send = find.text('送出修改建議');
      await tester.scrollUntilVisible(
        send,
        200,
        scrollable: find
            .descendant(
              of: find.byType(Form).last,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await _rest(tester);
      expect(tester.takeException(), isNull);
      // Back on the list, in the same panel, with what went.
      expect(find.byKey(_sidePanel), findsOneWidget);
      expect(_panel(tester), panel);
      expect(find.byKey(const ValueKey('suggestions-sent')), findsOneWidget);
      final done = find.byKey(const ValueKey('suggestions-done'));
      _expectInside(tester, done, panel);
      expect(tester.getRect(done).bottom, greaterThan(size.height - 40));
    }, variant: _platforms);

    for (final size in const [Size(820, 1180), Size(1180, 820)]) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()} 字級 2.0：'
          '單項表單的送出鍵捲得到、按得到', (tester) async {
        await _open(tester, _Form.suggestions, size: size, scale: 2);
        final panel = _panel(tester);
        await tester.tap(find.text('名稱'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField).last, '松壽停車場');
        // A drag that starts on the focused field moves its cursor on iOS
        // instead of scrolling; the rider drags from anywhere else.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final send = find.text('送出修改建議');
        await tester.scrollUntilVisible(
          send,
          200,
          scrollable: find
              .descendant(
                of: find.byType(Form).last,
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(send);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        _expectInside(tester, send, panel);
        await tester.tap(send);
        await _rest(tester);
        expect(find.byKey(const ValueKey('suggestions-sent')), findsOneWidget);
      }, variant: _platforms);
    }

    testWidgets('字級 2.0：清單與單項表單不溢位', (tester) async {
      await _open(
        tester,
        _Form.suggestions,
        size: const Size(1180, 820),
        scale: 2,
        brightness: Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      final panel = _panel(tester);
      final gone = find.byKey(const ValueKey('suggest-gone'));
      await tester.scrollUntilVisible(
        gone,
        200,
        scrollable: find
            .descendant(
              of: find.byType(SuggestionListPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      _expectInside(tester, gone, panel);
      await tester.tap(gone);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_panel(tester), panel);
    }, variant: _platforms);
  });

  group('整個 App', () {
    for (final size in const [Size(820, 1180), Size(1180, 820)]) {
      testWidgets('平板 ${size.width.toInt()}×${size.height.toInt()}：'
          '從詳情開修改建議，面板與詳情在同一個位置；分區與費率頁也在裡面', (tester) async {
        final store = await _demoStore(tester);
        await _pumpApp(tester, store, size: size);
        await tester.tap(find.byType(SpotMarker).first, warnIfMissed: false);
        await tester.pumpAndSettle();
        final detail = tester.getRect(find.byKey(_detail));
        final suggest = find.text('修改建議');
        await tester.ensureVisible(suggest);
        await tester.pumpAndSettle();
        await tester.tap(suggest);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SuggestionListPage), findsOneWidget);
        expect(_panel(tester), detail);
        expect(_scrims(tester), [_scrim]);
        final list = find.descendant(
          of: find.byType(SuggestionListPage),
          matching: find.byType(Scrollable),
        );
        // Each row's pages (S1b or S3b, S5, F0 or F1) open inside the
        // panel and step back to the list.
        for (final row in const [
          'suggest-where',
          'suggest-limits',
          'suggest-fee',
        ]) {
          final target = find.byKey(ValueKey(row));
          await tester.scrollUntilVisible(target, 150, scrollable: list.first);
          await tester.pumpAndSettle();
          if (tester.widget<EntryRow>(target).onTap == null) continue;
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: row);
          expect(_panel(tester), detail, reason: row);
          expect(
            tester.getSize(find.byType(FormFlow)).width,
            sidePanelWidth,
            reason: row,
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          // A nested sheet (a spot without zones) closes with one more.
          expect(find.byType(SuggestionListPage), findsOneWidget, reason: row);
        }
        // Closing the list leaves the details as they were.
        await tester.tapAt(Offset(size.width - 20, size.height / 2));
        await tester.pumpAndSettle();
        expect(find.byType(SuggestionListPage), findsNothing);
        expect(tester.getRect(find.byKey(_detail)), detail);
      }, variant: _platforms);
    }

    testWidgets('平板：貢獻分頁的新增停車點開在左側面板', (tester) async {
      const size = Size(1180, 820);
      final store = await _demoStore(tester);
      await _pumpApp(tester, store, size: size);
      await tester.tap(find.text('貢獻').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增停車點').hitTestable().first);
      await tester.pumpAndSettle();
      await _rest(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(ReportForm), findsOneWidget);
      expect(_panel(tester), _column(size));
    }, variant: _platforms);
  });

  group('退回手機版面', () {
    for (final (name, size, device) in const [
      ('手機 390×844', Size(390, 844), null),
      ('手機橫放 844×390', Size(844, 390), null),
      ('iPad 分割畫面一半 590×820', Size(590, 820), _iPad),
      ('平板上的矮視窗 960×599', Size(960, 599), _iPad),
      ('手機接大視窗 1180×820', Size(1180, 820), _iPhone),
    ]) {
      for (final form in _Form.values) {
        testWidgets('$name ${form.name}：照舊是底部 sheet', (tester) async {
          await _open(tester, form, size: size, device: device);
          expect(tester.takeException(), isNull);
          expect(find.byKey(_sidePanel), findsNothing);
          final flow = tester.getRect(find.byType(FormFlow));
          expect(flow.bottom, size.height);
          // Across the window, or the sheet's own widest (640).
          expect(flow.width, anyOf(size.width, 640));
          expect(flow.center.dx, size.width / 2);
        }, variant: _platforms);
      }
    }

    testWidgets('Android 平板上 680–759 寬的視窗是手機版面，iPad 是平板版面', (tester) async {
      const size = Size(720, 900);
      await _open(tester, _Form.report, size: size, device: _iPad);
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(_sidePanel),
        isCupertino ? findsOneWidget : findsNothing,
      );
    }, variant: _platforms);

    testWidgets('表單開著時旋轉：留在面板，填的內容還在', (tester) async {
      await _open(tester, _Form.report, size: const Size(1180, 820));
      final name = find.widgetWithText(TextFormField, '名稱');
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.enterText(name, '松壽地下停車場');
      await tester.pump();
      const turned = Size(820, 1180);
      tester.view.physicalSize = turned;
      tester.view.display.size = turned;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_panel(tester), _column(turned));
      expect(find.text('松壽地下停車場'), findsOneWidget);
    }, variant: _platforms);

    testWidgets('表單開著時視窗變窄（分割畫面）：改成橫跨底部的 sheet，填的內容還在，再變寬回到面板', (tester) async {
      const wide = Size(1180, 820);
      await _open(tester, _Form.report, size: wide, device: wide);
      final name = find.widgetWithText(TextFormField, '名稱');
      await tester.ensureVisible(name);
      await tester.pumpAndSettle();
      await tester.enterText(name, '松壽地下停車場');
      await tester.pump();
      const half = Size(590, 820);
      tester.view.physicalSize = half;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final sheet = _panel(tester);
      expect(sheet.left, 0);
      expect(sheet.width, half.width);
      expect(sheet.bottom, half.height);
      expect(find.text('松壽地下停車場'), findsOneWidget);
      expect(find.text('送出').hitTestable(), findsOneWidget);
      tester.view.physicalSize = wide;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_panel(tester), _column(wide));
      expect(find.text('松壽地下停車場'), findsOneWidget);
    }, variant: _platforms);
  });
}

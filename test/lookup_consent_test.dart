import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/domain/lookup_consent_display.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const _spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000462',
  name: '松壽地下停車場',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  district: '信義區',
  spaceType: SpaceType.freeMotorcycle,
);

const _consentKey = 'locationLookupConsent';
const _found = '約 松壽路 45 號附近';
const _signedOutDoor = '登入 Google 或 Apple 帳號後，才會顯示約略門牌';

/// Records every lookup that would leave the device.
class _Store extends AppStore {
  _Store(LocalRepository local) : super(local, null);
  bool enabled = true, signedIn = true;

  /// The county lookups (國土測繪中心) and the door lookups (Google).
  final towns = <(double, double)>[];
  final doors = <(double, double)>[];
  Town? town = const Town('臺北市', '大安區');

  /// When set, county lookups wait here until a test answers them.
  List<Completer<Town?>>? held;

  @override
  bool get approxAddressEnabled => enabled;
  @override
  bool get canReport => signedIn;
  @override
  Future<ApproxAddress?> approxAddressAt(double lat, double lng) async {
    doors.add((lat, lng));
    return const ApproxAddress('松壽路', '45');
  }

  @override
  Future<Town?> townAt(double lat, double lng) async {
    towns.add((lat, lng));
    if (held case final waiting?) {
      final answer = Completer<Town?>();
      waiting.add(answer);
      return answer.future;
    }
    return town;
  }

  @override
  Future<LocationFix> currentFix() async =>
      const LocationFix(25.0343, 121.5623, 8);

  void changeAuth(bool value) {
    signedIn = value;
    notifyListeners();
  }
}

Future<_Store> _store([String? consent]) async {
  SharedPreferences.setMockInitialValues({_consentKey: ?consent});
  return _Store(LocalRepository(await SharedPreferences.getInstance()))
    ..spots = const [_spot];
}

Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext) open, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // The app's bridge for CNBottomSheet's Material localizations.
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('開啟'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
}

/// The two picker forms: 新增停車點 and 修改建議「停車點位置」.
enum _Form { report, suggestion }

Future<void> _open(
  WidgetTester tester,
  _Store store,
  _Form form, {
  Size size = const Size(390, 844),
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  if (form == _Form.report) {
    return _host(
      tester,
      (c) => showReport(c, store, 25.0339, 121.5623),
      size: size,
      scale: scale,
      brightness: brightness,
    );
  }
  await _host(
    tester,
    (c) => showSpotSuggestions(c, store, _spot),
    size: size,
    scale: scale,
    brightness: brightness,
  );
  await tester.ensureVisible(find.text('位置'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('位置'));
  await tester.pumpAndSettle();
}

/// Lets every timer a lookup could be waiting on run out.
Future<void> _rest(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

/// Scrolls the open form until [target] is built and in view.
Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find
          .descendant(
            of: find.byType(Form).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _reveal(tester, target);
  await tester.tap(target);
  await tester.pump();
}

/// Drags the marker up and lets every lookup finish.
Future<void> _drag(WidgetTester tester) async {
  final pin = find.byKey(const ValueKey('touch-marker')).last;
  await _reveal(tester, pin);
  final gesture = await tester.startGesture(tester.getCenter(pin));
  await gesture.moveBy(const Offset(0, -60));
  await tester.pump();
  await gesture.up();
  await _rest(tester);
}

Future<void> _locate(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('location-locate')).last);
  await _rest(tester);
}

/// The open form's state, to move the marker as its picker does.
dynamic _formState(WidgetTester tester, _Form form) => tester.state(
  form == _Form.report
      ? find.byType(ReportForm)
      : find.byWidgetPredicate((w) => '${w.runtimeType}' == '_SuggestionForm'),
);

Future<void> _close(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

final _card = find.byKey(const ValueKey('lookup-consent-card'));
final _agree = find.byKey(const ValueKey('lookup-consent-agree'));
final _decline = find.byKey(const ValueKey('lookup-consent-decline'));
final _policy = find.byKey(const ValueKey('lookup-consent-policy'));
final _off = find.byKey(const ValueKey('lookup-off'));
final _turnOn = find.byKey(const ValueKey('lookup-turn-on'));
final _turnOff = find.byKey(const ValueKey('lookup-turn-off'));
final _door = find.byKey(const ValueKey('approx-address'));

final _both = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});

String? _saved(_Store store) => store.local.prefs.getString(_consentKey);

void main() {
  tearDown(() => policyUrls = (privacy: '', terms: ''));

  group('偏好', () {
    test('預設是還沒選；選擇會保存在裝置上', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(LocalRepository(prefs).lookupConsent, LookupConsent.undecided);

      final store = AppStore(LocalRepository(prefs), null);
      addTearDown(store.dispose);
      expect(store.lookupConsent, LookupConsent.undecided);
      expect(store.autoLookup, isFalse);
      var notified = 0;
      store.addListener(() => notified++);
      await store.setLookupConsent(LookupConsent.granted);
      expect(store.autoLookup, isTrue);
      expect(notified, 1);
      expect(prefs.getString(_consentKey), 'granted');
      // The same answer again changes nothing.
      await store.setLookupConsent(LookupConsent.granted);
      expect(notified, 1);

      // The next launch, whoever is signed in, reads it back.
      final next = AppStore(LocalRepository(prefs), null);
      addTearDown(next.dispose);
      expect(next.lookupConsent, LookupConsent.granted);
      await next.setLookupConsent(LookupConsent.declined);
      expect(prefs.getString(_consentKey), 'declined');
      expect(LocalRepository(prefs).lookupConsent, LookupConsent.declined);
    });

    test('看不懂的值當成還沒選', () async {
      SharedPreferences.setMockInitialValues({_consentKey: 'yes'});
      final local = LocalRepository(await SharedPreferences.getInstance());
      expect(local.lookupConsent, LookupConsent.undecided);
    });
  });

  group('做出選擇前與拒絕後不送出任何查詢', () {
    for (final form in _Form.values) {
      for (final signedIn in [true, false]) {
        for (final consent in [null, 'declined']) {
          final who = signedIn ? '已登入' : '未登入';
          final state = consent == null ? '還沒選' : '已拒絕';
          testWidgets('${form.name} $who $state：開啟、拖曳、移到我的位置都不查', (
            tester,
          ) async {
            final store = (await tester.runAsync(() => _store(consent)))!;
            addTearDown(store.dispose);
            store.signedIn = signedIn;
            await _open(tester, store, form);
            await _rest(tester);
            expect(_card, consent == null ? findsOneWidget : findsNothing);
            expect(_off, consent == null ? findsNothing : findsOneWidget);

            await _drag(tester);
            await _locate(tester);
            await _drag(tester);
            // What picking an address search result, or 放大地圖, does.
            _formState(tester, form).move(25.0478, 121.5319);
            await _rest(tester);

            expect(store.towns, isEmpty);
            expect(store.doors, isEmpty);
            // Neither a door nor the sign-in hint, nor a lookup's progress.
            expect(_door, findsNothing);
            expect(find.text(_signedOutDoor), findsNothing);
            expect(find.text('正在查詢所在縣市與行政區…'), findsNothing);
            expect(find.textContaining('查不到縣市'), findsNothing);
            expect(find.text(lookupAutoHint), findsNothing);
            expect(_saved(store), consent);
            await _close(tester);
          }, variant: _both);
        }
      }
    }

    testWidgets('新增：還沒選時縣市與區是空的，可以自己選；縣市仍必填', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      // No known spot nearby to borrow a county from.
      store.spots = const [];
      await _open(tester, store, _Form.report);
      final state = tester.state(find.byType(ReportForm)) as dynamic;
      expect(state.city, isNull);
      expect(state.district, '');
      state.validateAll();
      await tester.pumpAndSettle();
      expect(find.text('請選擇停車點所在縣市'), findsOneWidget);
      expect(store.towns, isEmpty);
      await _close(tester);
    });

    testWidgets('修改建議：還沒選時從停車點原本的縣市與區開始', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.suggestion);
      expect(_card, findsOneWidget);
      expect(find.text('臺北市'), findsOneWidget);
      expect(find.text('信義區'), findsOneWidget);
      await _close(tester);
    });
  });

  group('同意', () {
    for (final signedIn in [true, false]) {
      final who = signedIn ? '已登入' : '未登入';
      testWidgets('新增 $who：卡片收起，立刻查一次，之後每次停住都查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.signedIn = signedIn;
        await _open(tester, store, _Form.report);
        await _rest(tester);
        expect(store.towns, isEmpty);

        await _tap(tester, _agree);
        // At once: no 0.6 s wait.
        await tester.pump(const Duration(milliseconds: 1));
        expect(store.towns, hasLength(1));
        expect(store.doors, hasLength(signedIn ? 1 : 0));
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        expect(_saved(store), 'granted');
        expect(find.text('大安區'), findsOneWidget);
        expect(find.text(lookupAutoHint), findsOneWidget);
        expect(_turnOff, findsOneWidget);
        expect(find.text(signedIn ? _found : _signedOutDoor), findsOneWidget);

        await _drag(tester);
        expect(store.towns, hasLength(2));
        expect(store.doors, hasLength(signedIn ? 2 : 0));
        await _close(tester);
      }, variant: _both);

      testWidgets('修改建議 $who：卡片收起；門牌立刻查，縣市在標記移動後才查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.signedIn = signedIn;
        await _open(tester, store, _Form.suggestion);
        await _tap(tester, _agree);
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        expect(_saved(store), 'granted');
        // Where the map shows the spot, its county is already known.
        expect(store.towns, isEmpty);
        expect(store.doors, hasLength(signedIn ? 1 : 0));
        expect(find.text('信義區'), findsOneWidget);

        await _drag(tester);
        expect(store.towns, hasLength(1));
        expect(store.doors, hasLength(signedIn ? 2 : 0));
        expect(find.text('大安區'), findsOneWidget);
        await _close(tester);
      }, variant: _both);
    }

    testWidgets('修改建議：先移動標記再同意，立刻查這個位置的縣市', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.suggestion);
      await _drag(tester);
      expect(store.towns, isEmpty);
      // The old position's county is not kept for the new one.
      expect(find.text('信義區'), findsNothing);

      await _tap(tester, _agree);
      // At once: no 0.6 s wait.
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.towns, hasLength(1));
      await tester.pumpAndSettle();
      expect(find.text('大安區'), findsOneWidget);
      final state = _formState(tester, _Form.suggestion);
      // The position asked is where the marker rests now, not the spot's.
      expect(store.towns.single, (state.lat, state.lng));
      expect(store.towns.single, isNot((_spot.lat, _spot.lng)));
      await _close(tester);
    });

    testWidgets('未登入時同意，登入後不再問，直接查門牌', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      store.signedIn = false;
      await _open(tester, store, _Form.report);
      await _tap(tester, _agree);
      await tester.pumpAndSettle();
      expect(store.doors, isEmpty);

      store.changeAuth(true);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(_card, findsNothing);
      expect(store.doors, hasLength(1));
      expect(find.text(_found), findsOneWidget);
      await _close(tester);
    });

    testWidgets('已同意的裝置開啟表單就查，不再問；兩種表單共用', (tester) async {
      final store = (await tester.runAsync(() => _store('granted')))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.report);
      expect(_card, findsNothing);
      expect(store.towns, hasLength(1));
      expect(store.doors, hasLength(1));
      await _close(tester);

      await _open(tester, store, _Form.suggestion);
      expect(_card, findsNothing);
      expect(store.doors, hasLength(2));
      expect(_turnOff, findsOneWidget);
      await _close(tester);
    });
  });

  group('拒絕與重新開啟', () {
    for (final form in _Form.values) {
      testWidgets('${form.name}：拒絕後自己選；開啟自動查詢先回到說明卡，再同意才查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        await _open(tester, store, form);
        await _tap(tester, _decline);
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        expect(_saved(store), 'declined');
        expect(find.text(lookupOffNote), findsOneWidget);
        expect(_door, findsNothing);

        await _tap(tester, _turnOn);
        await _rest(tester);
        // Back on the explanation: still declined, still nothing asked.
        expect(_card, findsOneWidget);
        expect(_off, findsNothing);
        expect(_saved(store), 'declined');
        await _drag(tester);
        expect(store.towns, isEmpty);
        expect(store.doors, isEmpty);

        // 不同意 again puts the form back as it was.
        await _tap(tester, _decline);
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        expect(_off, findsOneWidget);
        expect(store.towns, isEmpty);

        await _tap(tester, _turnOn);
        await tester.pumpAndSettle();
        await _tap(tester, _agree);
        await tester.pumpAndSettle();
        expect(_saved(store), 'granted');
        expect(store.towns, hasLength(1));
        expect(store.doors, hasLength(1));
        expect(_card, findsNothing);
        expect(_off, findsNothing);
        await _close(tester);
      }, variant: _both);
    }
  });

  group('關閉自動查詢', () {
    for (final form in _Form.values) {
      testWidgets('${form.name}：立刻生效、不再確認，已帶入的縣市與區保留，之後不再查', (tester) async {
        final store = (await tester.runAsync(() => _store('granted')))!;
        addTearDown(store.dispose);
        await _open(tester, store, form);
        await _drag(tester);
        expect(find.text('大安區'), findsOneWidget);
        final (towns, doors) = (store.towns.length, store.doors.length);

        await _tap(tester, _turnOff);
        await tester.pump();
        expect(_saved(store), 'declined');
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(lookupTurnedOff), findsOneWidget);
        // Spoken too: the form sheet covers the page's messages.
        expect(
          tester.takeAnnouncements(),
          contains(isAccessibilityAnnouncement(lookupTurnedOff)),
        );
        expect(_door, findsNothing);
        expect(find.text(lookupAutoHint), findsNothing);
        expect(_off, findsOneWidget);
        // What the lookup brought stays, and can still be changed.
        expect(find.text('臺北市'), findsOneWidget);
        expect(find.text('大安區'), findsOneWidget);

        await _drag(tester);
        await _locate(tester);
        expect(store.towns, hasLength(towns));
        expect(store.doors, hasLength(doors));
        await _close(tester);
      }, variant: _both);
    }

    testWidgets('關閉時還在路上的查詢，回來也不帶入', (tester) async {
      final store = (await tester.runAsync(() => _store('granted')))!;
      addTearDown(store.dispose);
      store.spots = const [];
      final held = store.held = [];
      await _open(tester, store, _Form.report);
      expect(held, hasLength(1));
      expect(find.text('正在查詢所在縣市與行政區…'), findsOneWidget);

      await _tap(tester, _turnOff);
      await tester.pump();
      expect(find.text('正在查詢所在縣市與行政區…'), findsNothing);
      held.single.complete(const Town('臺北市', '大安區'));
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(ReportForm)) as dynamic;
      expect(state.city, isNull);
      expect(state.district, '');
      await _close(tester);
    });
  });

  group('說明卡的內容', () {
    testWidgets('已登入：查縣市、行政區與約略門牌', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.report);
      expect(find.text('要自動查這個位置的縣市和門牌嗎？'), findsOneWidget);
      expect(find.text(lookupCardLead), findsOneWidget);
      expect(
        find.text('縣市與行政區　直接送到內政部國土測繪中心。對方會看到你手機的網路位址。', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text(
          '約略門牌　經我們的伺服器送到 Google。Google 不會收到你的帳號和網路位址。',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.text('按「移到我的位置」時，傳出去的就是你當下的位置。', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text(
          '不同意也能回報：自己選縣市與行政區，不顯示約略門牌。'
          '之後可以到「帳號與設定 › 隱私」更改。',
        ),
        findsOneWidget,
      );
      expect(find.text('不同意，自己選'), findsOneWidget);
      expect(find.text('同意，自動查詢'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('未登入：只查縣市與行政區，寫明登入後會多查約略門牌', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      store.signedIn = false;
      await _open(tester, store, _Form.suggestion);
      expect(find.text('要自動查這個位置的縣市和行政區嗎？'), findsOneWidget);
      expect(
        find.text(
          '約略門牌　你還沒登入，現在不會查。登入後才會查：'
          '經我們的伺服器送到 Google，Google 不會收到你的帳號和網路位址。',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(
        find.text('不同意也能回報：自己選縣市與行政區。之後可以到「帳號與設定 › 隱私」更改。'),
        findsOneWidget,
      );
      // Signing in while the card is up turns it into the signed-in one.
      store.changeAuth(true);
      await tester.pump();
      expect(find.text('要自動查這個位置的縣市和門牌嗎？'), findsOneWidget);
      expect(store.towns, isEmpty);
      expect(store.doors, isEmpty);
      await _close(tester);
    });

    for (final form in _Form.values) {
      testWidgets('${form.name}：沒有 Google 地圖的版本不提門牌，同意後也不查門牌', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.enabled = false;
        await _open(tester, store, form);
        expect(find.text('要自動查這個位置的縣市和行政區嗎？'), findsOneWidget);
        expect(find.byKey(const ValueKey('lookup-consent-door')), findsNothing);
        expect(find.textContaining('約略門牌', findRichText: true), findsNothing);
        await _tap(tester, _agree);
        await tester.pumpAndSettle();
        await _drag(tester);
        expect(store.towns, isNotEmpty);
        expect(store.doors, isEmpty);
        expect(_door, findsNothing);
        await _close(tester);
      });
    }

    testWidgets('沒有政策網址的開發版不顯示連結；有網址時顯示', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.report);
      expect(_policy, findsNothing);
      await _close(tester);

      policyUrls = (privacy: 'https://example.test/privacy', terms: '');
      await _open(tester, store, _Form.report);
      await _reveal(tester, _policy);
      expect(find.text('看〈隱私權政策〉的完整說明'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('朗讀順序：標題、說明、三列、拒絕後怎麼用、兩個按鈕、連結', (tester) async {
      final handle = tester.ensureSemantics();
      policyUrls = (privacy: 'https://example.test/privacy', terms: '');
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _open(tester, store, _Form.report, size: const Size(390, 1600));
      await _reveal(tester, _policy);
      final title = find.text(lookupCardTitle(door: true));
      final order = [
        title,
        find.text(lookupCardLead),
        find.textContaining(lookupTownDetail, findRichText: true),
        find.textContaining(lookupDoorDetail, findRichText: true),
        find.textContaining(lookupMyLocationDetail, findRichText: true),
        find.text(lookupDeclineNote(door: true)),
        _decline,
        _policy,
      ];
      final tops = [for (final f in order) tester.getTopLeft(f).dy];
      expect(tops, [...tops]..sort());
      // Side by side, 不同意 first.
      expect(
        tester.getTopLeft(_decline).dx,
        lessThan(tester.getTopLeft(_agree).dx),
      );
      expect(tester.getSemantics(title), isSemantics(isHeader: true));
      expect(find.bySemanticsLabel(lookupCardLabel), findsOneWidget);
      expect(find.bySemanticsLabel(lookupChoiceLabel), findsOneWidget);
      expect(
        tester.getSemantics(_decline),
        isSemantics(label: lookupDecline, isButton: true),
      );
      expect(
        tester.getSemantics(_agree),
        isSemantics(label: lookupAgree, isButton: true),
      );
      handle.dispose();
      await _close(tester);
    });
  });

  group('版面', () {
    const sizes = [Size(320, 640), Size(390, 844), Size(820, 1180)];
    for (final form in _Form.values) {
      for (final size in sizes) {
        for (final scale in [1.0, 1.3, 2.0]) {
          for (final brightness in Brightness.values) {
            final label =
                '${form.name} ${size.width.toInt()}×${size.height.toInt()} '
                '字級 $scale ${brightness.name}';
            testWidgets('$label：三種狀態都不溢位，按鈕同大且夠大', (tester) async {
              policyUrls = (privacy: 'https://example.test/privacy', terms: '');
              final target = isCupertino ? 44.0 : 48.0;
              final store = (await tester.runAsync(_store))!;
              addTearDown(store.dispose);
              // The longer card: signed out.
              store.signedIn = false;
              await _open(
                tester,
                store,
                form,
                size: size,
                scale: scale,
                brightness: brightness,
              );
              expect(tester.takeException(), isNull);
              await _reveal(tester, _decline);
              await _reveal(tester, _agree);
              final (no, yes) = (
                tester.getSize(_decline),
                tester.getSize(_agree),
              );
              expect(no, yes);
              expect(no.height, greaterThanOrEqualTo(isCupertino ? 50 : 48));
              final (noStyle, yesStyle) = (
                tester.widget<OutlinedButton>(_decline).style,
                tester.widget<OutlinedButton>(_agree).style,
              );
              expect(noStyle.toString(), yesStyle.toString());
              // Stacked, 不同意 above, when they do not fit side by side.
              final (a, b) = (
                tester.getTopLeft(_decline),
                tester.getTopLeft(_agree),
              );
              expect(a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx), isTrue);
              if (size.width == 390) {
                expect(a.dy == b.dy, scale == 1.0, reason: '字級放大改上下排');
              }
              for (final text in tester.widgetList<RichText>(
                find.descendant(of: _card, matching: find.byType(RichText)),
              )) {
                expect(
                  text.text.style?.fontSize ?? 14,
                  greaterThanOrEqualTo(11),
                );
              }
              await _reveal(tester, _policy);
              expect(
                tester.getSize(_policy).height,
                greaterThanOrEqualTo(target),
              );
              expect(tester.takeException(), isNull);

              await _tap(tester, _decline);
              await tester.pumpAndSettle();
              await _reveal(tester, _turnOn);
              expect(tester.takeException(), isNull);
              final on = tester.getSize(_turnOn);
              expect(on.height, greaterThanOrEqualTo(target));
              expect(on.width, greaterThanOrEqualTo(target));
              final box = tester.getRect(_off);
              expect(box.contains(tester.getRect(_turnOn).center), isTrue);

              await _tap(tester, _turnOn);
              await tester.pumpAndSettle();
              await _tap(tester, _agree);
              await tester.pumpAndSettle();
              await _reveal(tester, _turnOff);
              expect(tester.takeException(), isNull);
              final off = tester.getSize(_turnOff);
              expect(off.height, greaterThanOrEqualTo(target));
              expect(off.width, greaterThanOrEqualTo(target));
              final view = tester.view.physicalSize.width;
              expect(tester.getRect(_turnOff).right, lessThanOrEqualTo(view));
              expect(tester.getRect(_turnOff).left, greaterThanOrEqualTo(0));
              await _close(tester);
            }, variant: _both);
          }
        }
      }
    }
  });

  group('帳號與設定 › 隱私', () {
    Future<void> openSettings(
      WidgetTester tester,
      _Store store, {
      Size size = const Size(390, 844),
      double scale = 1,
      Brightness brightness = Brightness.light,
    }) async {
      await _host(
        tester,
        (c) => showSettings(c, store),
        size: size,
        scale: scale,
        brightness: brightness,
      );
      await tester.scrollUntilVisible(
        find.text(settingsLookupOffDetail),
        120,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
    }

    final row = find.byKey(const ValueKey('settings-lookup'));
    bool on(WidgetTester tester) => tester.widget<SwitchListTile>(row).value;

    for (final signedIn in [true, false]) {
      testWidgets('${signedIn ? '已登入' : '未登入'}：預設關，下方固定顯示完整說明；打開就算同意', (
        tester,
      ) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.signedIn = signedIn;
        await openSettings(tester, store);
        expect(find.text('選點時自動查縣市與門牌'), findsOneWidget);
        expect(on(tester), isFalse);
        expect(find.text(settingsLookupDetail), findsOneWidget);
        expect(find.text(settingsLookupOffDetail), findsOneWidget);
        // Under 已隱藏的車友, in 隱私.
        expect(
          tester.getTopLeft(row).dy,
          greaterThan(
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('settings-hidden-riders')),
                )
                .dy,
          ),
        );

        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(on(tester), isTrue);
        expect(store.lookupConsent, LookupConsent.granted);
        expect(_saved(store), 'granted');
        expect(find.text(settingsLookupDetail), findsOneWidget);
        expect(find.text(settingsLookupOffDetail), findsOneWidget);

        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(on(tester), isFalse);
        expect(_saved(store), 'declined');
        await _close(tester);
      }, variant: _both);
    }

    testWidgets('開關跟著表單裡的選擇', (tester) async {
      final store = (await tester.runAsync(() => _store('declined')))!;
      addTearDown(store.dispose);
      await openSettings(tester, store);
      expect(on(tester), isFalse);
      await store.setLookupConsent(LookupConsent.granted);
      await tester.pump();
      expect(on(tester), isTrue);
      await _close(tester);
    });

    testWidgets('在設定打開後，表單不再出現說明卡，開啟就查', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await openSettings(tester, store);
      await tester.tap(row);
      await tester.pumpAndSettle();
      await _close(tester);

      await _open(tester, store, _Form.report);
      expect(_card, findsNothing);
      expect(store.towns, hasLength(1));
      expect(store.doors, hasLength(1));
      await _close(tester);
    });

    for (final form in _Form.values) {
      testWidgets('${form.name}：開著的表單跟著設定立刻停止或開始查詢', (tester) async {
        final store = (await tester.runAsync(() => _store('granted')))!;
        addTearDown(store.dispose);
        await _open(tester, store, form);
        await _drag(tester);
        final (towns, doors) = (store.towns.length, store.doors.length);

        // What the switch in 帳號與設定 does.
        await store.setLookupConsent(LookupConsent.declined);
        await tester.pumpAndSettle();
        expect(_door, findsNothing);
        expect(_off, findsOneWidget);
        await _drag(tester);
        expect(store.towns, hasLength(towns));
        expect(store.doors, hasLength(doors));

        await store.setLookupConsent(LookupConsent.granted);
        await tester.pumpAndSettle();
        expect(_card, findsNothing);
        expect(_off, findsNothing);
        expect(store.towns, hasLength(towns + 1));
        expect(store.doors, hasLength(doors + 1));
        await _close(tester);
      });
    }

    for (final size in const [
      Size(320, 640),
      Size(390, 844),
      Size(820, 1180),
    ]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        for (final brightness in Brightness.values) {
          testWidgets('${size.width.toInt()}×${size.height.toInt()} 字級 $scale '
              '${brightness.name}：不溢位，開關夠大', (tester) async {
            final store = (await tester.runAsync(_store))!;
            addTearDown(store.dispose);
            await openSettings(
              tester,
              store,
              size: size,
              scale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(row);
            await tester.pumpAndSettle();
            expect(
              tester.getSize(row).height,
              greaterThanOrEqualTo(isCupertino ? 44 : 48),
            );
            for (final text in [
              settingsLookupDetail,
              settingsLookupOffDetail,
            ]) {
              expect(
                tester.widget<Text>(find.text(text)).style?.fontSize,
                greaterThanOrEqualTo(11),
              );
            }
            expect(tester.takeException(), isNull);
            await _close(tester);
          }, variant: _both);
        }
      }
    }
  });
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/approx_address.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const _spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000123',
  name: '松壽地下停車場',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  district: '信義區',
  spaceType: SpaceType.freeMotorcycle,
);

const _door = ApproxAddress('松壽路', '45');
const _found = '約 松壽路 45 號附近';

class _DoorStore extends AppStore {
  _DoorStore(LocalRepository local) : super(local, null);
  bool enabled = true, signedIn = true;
  final asked = <(double, double)>[];
  final submissions = <Map<String, dynamic>>[];

  /// What the lookup answers, or throws when an [Exception].
  Object? answer = _door;
  Town? town = const Town('臺北市', '大安區');

  @override
  bool get approxAddressEnabled => enabled;
  @override
  bool get canReport => signedIn;
  @override
  Future<ApproxAddress?> approxAddressAt(double lat, double lng) async {
    asked.add((lat, lng));
    if (answer case final Exception e) throw e;
    return answer as ApproxAddress?;
  }

  @override
  Future<Town?> townAt(double lat, double lng) async => town;

  @override
  Future<String> submit(Map<String, dynamic> body) async {
    submissions.add(body);
    return '已送交審核';
  }

  void changeAuth(bool value) {
    signedIn = value;
    notifyListeners();
  }
}

Future<_DoorStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return _DoorStore(LocalRepository(await SharedPreferences.getInstance()))
    ..spots = const [_spot];
}

Future<void> _host(
  WidgetTester tester,
  Size size,
  void Function(BuildContext) open,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      // The app's bridge for CNBottomSheet's Material localizations.
      // ignore: deprecated_member_use
      builder: (_, child) => MaterialUiCompatibilityBridge(child: child!),
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

Future<void> _openNew(WidgetTester tester, _DoorStore store, Size size) =>
    _host(tester, size, (c) => showReport(c, store, 25.0339, 121.5623));

Future<void> _openSuggest(
  WidgetTester tester,
  _DoorStore store,
  Size size,
) async {
  await _host(tester, size, (c) => showSpotSuggestions(c, store, _spot));
  await tester.ensureVisible(find.text('位置'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('位置'));
  await tester.pumpAndSettle();
}

/// Drags the marker up by [dy] pixels and lets every lookup finish.
Future<void> _drag(WidgetTester tester, double dy) async {
  final pin = find.byKey(const ValueKey('touch-marker')).last;
  final gesture = await tester.startGesture(tester.getCenter(pin));
  await gesture.moveBy(Offset(0, -dy));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

/// Lifts the marker by its foot and drops it about 20 pixels (5 m) from
/// where it was: the tip rides above the finger, so a plain drag lands
/// further off.
Future<void> _dragSlightly(WidgetTester tester) async {
  final pin = find.byKey(const ValueKey('touch-marker')).last;
  final foot =
      tester.getBottomLeft(pin) + Offset(tester.getSize(pin).width / 2, -2);
  final gesture = await tester.startGesture(foot);
  await gesture.moveBy(const Offset(0, 40));
  await tester.pump();
  await gesture.moveBy(const Offset(0, -34));
  await tester.pump();
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

/// Scrolls the suggestion form until [target] is built and in view.
Future<void> _reveal(
  WidgetTester tester,
  Finder target, {
  double by = 200,
}) async {
  await tester.scrollUntilVisible(
    target,
    by,
    scrollable: find
        .descendant(
          of: find.byType(Form).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox.shrink());

final _both = TargetPlatformVariant({
  TargetPlatform.iOS,
  TargetPlatform.android,
});
const _sizes = [Size(390, 844), Size(820, 1180)];

const _states = <(String, Object?, String, String?)>[
  ('查到門牌', _door, _found, '已查詢到附近門牌，查詢結果僅供畫面參考，不會提交。'),
  ('只查到路名', ApproxAddress('松壽路'), '約在 松壽路 上', '門牌號碼無法查詢，查詢結果僅供畫面參考，不會提交。'),
  ('查不到', null, '這個位置查不到門牌', '拖曳標記對準停車格就好，不影響送出。'),
  ('連線失敗', AddressSearchException('network'), '暫時查不到門牌', '移動標記會再查一次，不影響送出。'),
  (
    '服務失敗',
    AddressSearchException('unavailable'),
    '暫時查不到門牌',
    '移動標記會再查一次，不影響送出。',
  ),
  (
    '個人額度用完',
    AddressSearchException('daily_limit'),
    '今天的地址查詢次數已用完，明天會恢復',
    '不顯示門牌，不影響送出。',
  ),
  (
    '全站額度用完',
    AddressSearchException('service_limit'),
    '地址查詢今天的總次數已用完，明天會恢復',
    '不顯示門牌，不影響送出。',
  ),
  (
    '超出範圍',
    AddressSearchException('invalid_query'),
    '這個位置查不到門牌',
    '拖曳標記對準停車格就好，不影響送出。',
  ),
];

void main() {
  group('表單上的門牌列', () {
    for (final size in _sizes) {
      final label = '${size.width.toInt()}×${size.height.toInt()}';
      for (final (name, answer, title, note) in _states) {
        testWidgets('N1 $label：$name', (tester) async {
          final store = (await tester.runAsync(_store))!;
          addTearDown(store.dispose);
          store.answer = answer;
          await _openNew(tester, store, size);
          expect(find.text(title), findsOneWidget);
          if (note != null) expect(find.text(note), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _close(tester);
        }, variant: _both);

        testWidgets('修改建議 $label：$name', (tester) async {
          final store = (await tester.runAsync(_store))!;
          addTearDown(store.dispose);
          store.answer = answer;
          await _openSuggest(tester, store, size);
          expect(find.text(title), findsOneWidget);
          if (note != null) expect(find.text(note), findsOneWidget);
          expect(tester.takeException(), isNull);
          await _close(tester);
        }, variant: _both);
      }

      testWidgets('N1 $label：未登入不查，登入後才查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.signedIn = false;
        await _openNew(tester, store, size);
        expect(find.text('登入 Google 或 Apple 帳號後，才會顯示約略門牌'), findsOneWidget);
        expect(store.asked, isEmpty);
        store.changeAuth(true);
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text(_found), findsOneWidget);
        expect(store.asked, hasLength(1));
        await _close(tester);
      }, variant: _both);

      testWidgets('N1 $label：OSM 底圖版整列不顯示也不查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.enabled = false;
        await _openNew(tester, store, size);
        expect(find.byKey(const ValueKey('approx-address')), findsNothing);
        expect(find.byType(TownFields), findsOneWidget);
        await _drag(tester, 120);
        expect(store.asked, isEmpty);
        await _close(tester);
      }, variant: _both);

      testWidgets('修改建議 $label：OSM 底圖版整列不顯示也不查', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        store.enabled = false;
        await _openSuggest(tester, store, size);
        expect(find.byKey(const ValueKey('approx-address')), findsNothing);
        expect(find.byType(TownFields), findsOneWidget);
        await _drag(tester, 120);
        expect(store.asked, isEmpty);
        await _close(tester);
      }, variant: _both);

      testWidgets('修改建議 $label：順序是地圖、門牌、縣市區', (tester) async {
        final store = (await tester.runAsync(_store))!;
        addTearDown(store.dispose);
        await _openSuggest(tester, store, size);
        final row = tester.getTopLeft(
          find.byKey(const ValueKey('approx-address')),
        );
        final town = tester.getTopLeft(find.byType(TownFields));
        expect(row.dy, lessThan(town.dy));
        expect(find.text('依地圖位置自動帶入，可以改。'), findsOneWidget);
        await _close(tester);
      }, variant: _both);
    }

    testWidgets('N1 的門牌只顯示，不進回報內容', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _openNew(tester, store, const Size(390, 844));
      expect(find.text(_found), findsOneWidget);
      final state = tester.state(find.byType(ReportForm)) as dynamic;
      expect(jsonEncode(state.body()), isNot(contains('松壽路')));
      await _close(tester);
    });

    testWidgets('拖曳中不查；停下後查一次；移動不到 10 公尺不重查', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _openNew(tester, store, const Size(390, 844));
      expect(store.asked, hasLength(1));

      final pin = find.byKey(const ValueKey('touch-marker')).last;
      final gesture = await tester.startGesture(tester.getCenter(pin));
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(find.text('放開標記後查約略門牌'), findsOneWidget);
      expect(store.asked, hasLength(1));
      await gesture.up();
      await tester.pump();
      expect(find.text('正在查約略門牌…'), findsOneWidget);
      expect(store.asked, hasLength(1));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(store.asked, hasLength(2));
      expect(find.text(_found), findsOneWidget);

      await _dragSlightly(tester);
      expect(store.asked, hasLength(2));
      expect(find.text(_found), findsOneWidget);
      await _close(tester);
    });

    testWidgets('修改建議：反查帶入、可手動改；門牌不列入內容也不送出', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      await _openSuggest(tester, store, const Size(390, 844));
      expect(find.text('信義區'), findsOneWidget);
      await _drag(tester, 120);
      expect(find.text('大安區'), findsOneWidget);
      final change = find.byKey(const ValueKey('suggestion-change'));
      await _reveal(tester, change);
      expect(find.textContaining('行政區從「信義區」改成「大安區」'), findsOneWidget);
      expect(
        find.descendant(of: change, matching: find.textContaining('松壽路')),
        findsNothing,
      );

      // A pick by hand goes with the suggestion.
      await _reveal(tester, find.text('大安區'), by: -200);
      await tester.tap(find.text('大安區'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('中山區').last);
      await tester.pumpAndSettle();
      await _reveal(tester, change);
      expect(find.textContaining('行政區從「信義區」改成「中山區」'), findsOneWidget);

      await _reveal(tester, find.text('送出修改建議'));
      await tester.tap(find.text('送出修改建議'));
      await tester.pumpAndSettle();
      final body = store.submissions.single;
      final proposed = body['proposed'] as Map<String, Object?>;
      expect(proposed['city'], '臺北市');
      expect(proposed['district'], '中山區');
      expect(jsonEncode(body), isNot(contains('松壽路')));
      await _close(tester);
    });

    testWidgets('修改建議：查不到縣市時兩欄未選並提示，手動選的縣市會送出', (tester) async {
      final store = (await tester.runAsync(_store))!;
      addTearDown(store.dispose);
      store.town = null;
      await _openSuggest(tester, store, const Size(390, 844));
      await _drag(tester, 120);
      expect(find.text('查不到縣市與行政區，請在上方確認縣市。'), findsOneWidget);
      expect(find.text('未選'), findsOneWidget);
      expect(find.text('先選縣市'), findsOneWidget);

      await tester.tap(find.text('未選'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新北市').last);
      await tester.pumpAndSettle();
      expect(find.text('查不到縣市與行政區，請在上方確認縣市。'), findsNothing);

      await _reveal(tester, find.text('送出修改建議'));
      await tester.tap(find.text('送出修改建議'));
      await tester.pumpAndSettle();
      final proposed =
          store.submissions.single['proposed'] as Map<String, Object?>;
      expect(proposed['city'], '新北市');
      expect(proposed['district'], '');
      await _close(tester);
    });
  });

  group('ApproxAddressController', () {
    (ApproxAddressController, List<(double, double)>) make(
      WidgetTester tester, {
      Object? answer = _door,
      bool signedIn = true,
    }) {
      final asked = <(double, double)>[];
      final auth = ChangeNotifier();
      addTearDown(auth.dispose);
      final c = ApproxAddressController(
        lookup: (a, b) async {
          asked.add((a, b));
          if (answer case final Exception e) throw e;
          return answer as ApproxAddress?;
        },
        auth: auth,
        signedIn: () => signedIn,
        lat: 25.03,
        lng: 121.56,
      );
      addTearDown(c.dispose);
      return (c, asked);
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
    }

    testWidgets('移動約 10 公尺以上才重查，距離從上次查到的點算', (tester) async {
      final (c, asked) = make(tester);
      await settle(tester);
      expect(asked, hasLength(1));
      // About 5 m, twice: the second is 10 m from the answer.
      c.moved(25.03004, 121.56);
      await settle(tester);
      expect(asked, hasLength(1));
      expect(c.status, ApproxStatus.found);
      c.moved(25.0301, 121.56);
      await settle(tester);
      expect(asked, hasLength(2));
    });

    testWidgets('連線失敗後移動一點點也會再查', (tester) async {
      final (c, asked) = make(
        tester,
        answer: const AddressSearchException('network'),
      );
      await settle(tester);
      expect(c.status, ApproxStatus.failed);
      c.moved(25.03001, 121.56);
      await settle(tester);
      expect(asked, hasLength(2));
    });

    testWidgets('額度用完後不再查', (tester) async {
      final (c, asked) = make(
        tester,
        answer: const AddressSearchException('daily_limit'),
      );
      await settle(tester);
      expect(c.status, ApproxStatus.dailyLimit);
      c.dragging(true);
      expect(c.status, ApproxStatus.dailyLimit);
      c.dragging(false);
      c.moved(25.04, 121.56);
      await settle(tester);
      expect(asked, hasLength(1));
      expect(c.status, ApproxStatus.dailyLimit);
    });

    testWidgets('拖曳開始後，先前查詢的答案不算數', (tester) async {
      final (c, asked) = make(tester);
      await settle(tester);
      c.moved(25.04, 121.56);
      await tester.pump(const Duration(milliseconds: 100));
      c.dragging(true);
      await settle(tester);
      expect(c.status, ApproxStatus.dragging);
      expect(asked, hasLength(1));
    });
  });

  test('門牌回應的解析', () {
    expect(parseApproxAddress({'road': '松壽路', 'number': '45'}), _door);
    expect(
      parseApproxAddress({'road': '松壽路', 'number': null}),
      const ApproxAddress('松壽路'),
    );
    expect(parseApproxAddress({'road': null, 'number': null}), isNull);
    expect(
      () => parseApproxAddress('oops'),
      throwsA(isA<AddressSearchException>()),
    );
  });

  test('沒有 Google 地圖金鑰的版本不查門牌', () async {
    SharedPreferences.setMockInitialValues({});
    final store = AppStore(
      LocalRepository(await SharedPreferences.getInstance()),
      SupabaseClient('https://example.supabase.co', 'anon'),
    );
    addTearDown(store.dispose);
    expect(store.demo, isFalse);
    expect(store.approxAddressEnabled, isFalse);
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show SupabaseClient;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/favorite_handles.dart';
import 'package:motorcycle_parking/api/v1/api_v1.g.dart' show ApiV1Exception;
import 'package:motorcycle_parking/data/hidden_riders.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/hidden_riders_display.dart';
import 'package:motorcycle_parking/features/hidden_riders/hidden_riders_page.dart';
import 'package:motorcycle_parking/features/hidden_riders/hide_rider.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'data_updates_test.dart' show FakeUpdates;
import 't280_harness.dart';

/// Three hidden riders: 阿明 newest, Ken, then one without a public name.
Map<String, Object> threeHidden() => {
  HiddenRiders.storageKey: jsonEncode([
    {
      'handle': handleK,
      'name': 'Ken',
      'spot_name': '松壽路口機車格',
      'hidden_at': DateTime(2026, 10, 30, 9).toIso8601String(),
    },
    {
      'handle': handleU,
      'name': '',
      'spot_name': '永吉路巷口機車格',
      'hidden_at': DateTime(2026, 10, 12, 9).toIso8601String(),
    },
    {
      'handle': handleA,
      'name': '阿明',
      'spot_name': '市府轉運站機車區',
      'hidden_at': DateTime(2026, 11, 1, 9).toIso8601String(),
    },
  ]),
};

/// The account's list, in memory, with a switch to fail like offline.
class FakeAccountList implements HiddenRidersStore {
  FakeAccountList([List<HiddenRider> rows = const []]) : rows = [...rows];
  List<HiddenRider> rows;
  bool offline = false;
  final calls = <String>[];

  void _check(String call) {
    calls.add(call);
    if (offline) throw Exception('offline');
  }

  @override
  Future<List<HiddenRider>> list() async {
    _check('list');
    return [...rows];
  }

  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async {
    _check('merge');
    return rows = unionRiders(rows, items);
  }

  @override
  Future<void> remove(String handle) async {
    _check('remove');
    rows = [
      for (final r in rows)
        if (r.handle != handle) r,
    ];
  }
}

/// Signed out in a build that has a backend: P17c shows the guest card.
class GuestStore extends AppStore {
  GuestStore(LocalRepository local) : super(local, null);
  @override
  bool get demo => false;
}

HiddenRider rider(String handle, String name, DateTime at) =>
    HiddenRider(handle: handle, name: name, spotName: '某處', hiddenAt: at);

/// A client whose PostgREST calls [answer] handles: (rpc name, body).
SupabaseClient apiClient(
  http.Response Function(String name, Object? body) answer,
) => SupabaseClient(
  'https://example.supabase.co',
  'test-key',
  httpClient: MockClient((request) async {
    final name = request.url.pathSegments.last;
    final r = answer(
      name,
      request.body.isEmpty ? null : jsonDecode(request.body),
    );
    // PostgREST parsing reads the request back from the response.
    return http.Response(
      r.body,
      r.statusCode,
      headers: r.headers,
      request: request,
    );
  }),
);

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  group('HiddenRiders 本機清單', () {
    test('存代號、名稱、點位名稱與日期，最新的在前，重新讀取仍在', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var now = DateTime(2026, 11, 1, 9);
      final hidden = HiddenRiders(prefs, clock: () => now);
      await hidden.hide(handle: handleK, name: ' Ken ', spotName: '松壽路口');
      now = DateTime(2026, 11, 2, 9);
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府轉運站');
      expect(hidden.riders.map((r) => r.handle), [handleA, handleK]);
      expect(hidden.riders.last.name, 'Ken');
      // Hiding again keeps the first row.
      await hidden.hide(handle: handleA, name: '改名', spotName: '別處');
      expect(hidden.byHandle(handleA)!.name, '阿明');

      final again = HiddenRiders(prefs);
      expect(again.riders, hidden.riders);
      expect(again.isHidden(handleA), isTrue);
      expect(again.isHidden(null), isFalse);
      expect(again.isHidden(''), isFalse);
    });

    test('只用代號比對：改名後仍維持隱藏', () async {
      SharedPreferences.setMockInitialValues({});
      final hidden = HiddenRiders(await SharedPreferences.getInstance());
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      // Whatever the rider is now called, the handle still matches.
      expect(hidden.isHidden(handleA), isTrue);
      expect(hidden.isHidden(handleK), isFalse);
    });

    test('解除隱藏回傳那一列，復原放回原日期', () async {
      SharedPreferences.setMockInitialValues(threeHidden());
      final hidden = HiddenRiders(await SharedPreferences.getInstance());
      final removed = await hidden.unhide(handleA);
      expect(removed!.name, '阿明');
      expect(hidden.isHidden(handleA), isFalse);
      expect(await hidden.unhide(handleA), isNull);
      await hidden.restore(removed);
      expect(hidden.riders.first, removed);
    });

    test('自己的代號會被移除', () async {
      SharedPreferences.setMockInitialValues(threeHidden());
      final hidden = HiddenRiders(await SharedPreferences.getInstance());
      var notified = 0;
      hidden.addListener(() => notified++);
      await hidden.forget([handleK]);
      expect(hidden.riders.map((r) => r.handle), [handleA, handleU]);
      await hidden.forget(['not-there']);
      expect(notified, 1);
    });

    test('損壞的儲存不會讓整份清單消失或當機', () async {
      SharedPreferences.setMockInitialValues({
        HiddenRiders.storageKey: jsonEncode([
          {'handle': handleA, 'name': '阿明'},
          {'name': '沒有代號'},
          42,
        ]),
      });
      final hidden = HiddenRiders(await SharedPreferences.getInstance());
      expect(hidden.riders.map((r) => r.handle), [handleA]);
      SharedPreferences.setMockInitialValues({
        HiddenRiders.storageKey: '{not json',
      });
      expect(
        HiddenRiders(await SharedPreferences.getInstance()).isEmpty,
        isTrue,
      );
    });
  });

  test('文案：沒有名稱用「這位車友」，手機與平板用詞不同', () {
    final unnamed = HiddenRider(
      handle: handleU,
      name: '',
      spotName: '永吉路巷口機車格',
      hiddenAt: DateTime(2026, 10, 12),
    );
    final named = HiddenRider(
      handle: handleA,
      name: '阿明',
      spotName: '市府轉運站機車區',
      hiddenAt: DateTime(2026, 11, 1),
    );
    expect(hiddenRiderTitle(unnamed), '未公開名稱的車友');
    expect(hiddenRiderSubtitle(unnamed), '在「永吉路巷口機車格」隱藏・10 月 12 日');
    expect(hiddenRiderSubtitle(named), '隱藏時的名稱・在「市府轉運站機車區」隱藏・11 月 1 日');
    expect(unhideLabel('阿明'), '解除隱藏 阿明');
    expect(unhideLabel(''), '解除隱藏 這位車友');
    expect(hiddenToast(''), '已隱藏這位車友');
    expect(moreActionsLabel(byRider: true), '這筆回報：更多動作');
    expect(moreActionsLabel(byRider: false), '這筆資料：更多動作');
    expect(
      hideRiderConfirmBody('阿明'),
      '阿明新增的停車點和名稱都不會再顯示，你登入的每台裝置都會同步。'
      '可以在「帳號與設定」的「已隱藏的車友」解除。',
    );
    expect(hideRiderConfirmBody(''), startsWith('這位車友新增'));
  });

  group('P17c 已隱藏的車友', () {
    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        testWidgetsOn('${platform.name} $name：三列、朗讀標籤、解除與復原', (tester) async {
          setUpView(tester, platform, size);
          final store = (await tester.runAsync(
            () => storeWith(threeHidden()),
          ))!;
          final semantics = tester.ensureSemantics();
          await tester.pumpWidget(app(HiddenRidersPage(store: store)));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(hiddenRidersIntro), findsOneWidget);
          // The sample build has no account: the synced foot shows.
          expect(find.text(hiddenRidersFootnote), findsOneWidget);
          // Newest first; the unnamed row says so.
          final aY = tester.getTopLeft(find.text('阿明')).dy;
          final kY = tester.getTopLeft(find.text('Ken')).dy;
          final uY = tester.getTopLeft(find.text(unnamedRider)).dy;
          expect(aY < kY && kY < uY, isTrue);
          expect(find.bySemanticsLabel('解除隱藏 阿明'), findsOneWidget);
          expect(find.bySemanticsLabel('解除隱藏 這位車友'), findsOneWidget);
          final button = tester.getSize(
            find.byKey(const ValueKey('unhide-$handleA')),
          );
          expect(
            button.height,
            greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
          );

          await tester.tap(find.byKey(const ValueKey('unhide-$handleA')));
          await tester.pumpAndSettle();
          expect(store.hiddenRiders.isHidden(handleA), isFalse);
          expect(find.text('阿明'), findsNothing);
          expect(find.text('已解除隱藏阿明'), findsOneWidget);
          await tester.tap(find.byKey(const ValueKey('undo-toast-action')));
          await tester.pumpAndSettle();
          expect(store.hiddenRiders.isHidden(handleA), isTrue);
          expect(find.text('阿明'), findsOneWidget);
          semantics.dispose();
        });
      }
      testWidgetsOn('${platform.name} 空狀態', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(() => storeWith({})))!;
        await tester.pumpWidget(app(HiddenRidersPage(store: store)));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('hidden-riders-empty')),
          findsOneWidget,
        );
        expect(find.text(hiddenRidersEmptyTitle), findsOneWidget);
        expect(find.text(hiddenRidersEmptyBody), findsOneWidget);
      });
    }

    testWidgetsOn('大字 2.0：不溢出、按鈕移到名稱下方', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      final store = (await tester.runAsync(() => storeWith(threeHidden())))!;
      await tester.pumpWidget(app(HiddenRidersPage(store: store), scale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final name = tester.getBottomLeft(find.text('阿明'));
      final button = tester.getTopLeft(
        find.byKey(const ValueKey('unhide-$handleA')),
      );
      expect(button.dy, greaterThan(name.dy));
    });
  });

  group('復原提示', () {
    Future<void> pumpToast(
      WidgetTester tester, {
      required String text,
      bool accessible = false,
      double scale = 1,
    }) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showUndoToast(
                  ScaffoldMessenger.of(context),
                  MediaQuery.of(context),
                  text: text,
                  icon: Icons.visibility_off_outlined,
                  onUndo: () {},
                ),
                child: const Text('show'),
              ),
            ),
          ),
          accessible: accessible,
          scale: scale,
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
    }

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 約 8 秒後消失', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        await pumpToast(tester, text: '已隱藏阿明');
        expect(find.text('已隱藏阿明'), findsOneWidget);
        await tester.pump(const Duration(seconds: 7));
        expect(find.text('已隱藏阿明'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(find.text('已隱藏阿明'), findsNothing);
      });

      testWidgetsOn('${platform.name} 螢幕閱讀器開著時不自動消失', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        await pumpToast(tester, text: '已隱藏阿明', accessible: true);
        await tester.pump(const Duration(seconds: 30));
        await tester.pumpAndSettle();
        expect(find.text('已隱藏阿明'), findsOneWidget);
      });
    }

    testWidgetsOn('長名稱與大字：名稱最多兩行，「復原」換到下一行', (tester) async {
      setUpView(tester, TargetPlatform.iOS, const Size(390, 844));
      await pumpToast(tester, text: '已隱藏重機騎士阿明的週末松山信義區巡禮小隊長兼攝影', scale: 2);
      expect(tester.takeException(), isNull);
      final text = find.byKey(const ValueKey('undo-toast-text'));
      expect(tester.widget<Text>(text).maxLines, 2);
      final undo = find.byKey(const ValueKey('undo-toast-action'));
      expect(
        tester.getTopLeft(undo).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(text).dy - 1),
      );
    });

    testWidgetsOn('短名稱：「復原」與名稱同一行', (tester) async {
      setUpView(tester, TargetPlatform.android, const Size(390, 844));
      await pumpToast(tester, text: '已隱藏阿明');
      final text = find.byKey(const ValueKey('undo-toast-text'));
      final undo = find.byKey(const ValueKey('undo-toast-action'));
      expect(
        tester.getCenter(undo).dy,
        moreOrLessEquals(tester.getCenter(text).dy, epsilon: 2),
      );
    });
  });

  group('確認對話框', () {
    for (final platform in platforms) {
      for (final (name, size) in layouts) {
        testWidgetsOn('${platform.name} $name：文字與按鈕', (tester) async {
          setUpView(tester, platform, size);
          bool? answer;
          await tester.pumpWidget(
            app(
              Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async =>
                        answer = await confirmHideRider(context, '阿明'),
                    child: const Text('ask'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('ask'));
          await tester.pumpAndSettle();
          expect(find.text(hideRiderConfirmTitle), findsOneWidget);
          expect(find.text(hideRiderConfirmBody('阿明')), findsOneWidget);
          await tester.tap(find.text(hideRiderConfirm));
          await tester.pumpAndSettle();
          expect(answer, isTrue);
        });
      }
    }
  });

  group('P10 帳號與設定', () {
    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 未登入也顯示「已隱藏的車友」與「聯絡我們」', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(() => storeWith(threeHidden())))!;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSettings(context, store),
                  child: const Text('settings'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('settings'));
        await tester.pumpAndSettle();
        expect(store.riderId, isNull);
        expect(find.text(settingsPrivacyGroup), findsOneWidget);
        expect(find.text(settingsHiddenRiders), findsOneWidget);
        expect(find.text('登入後會同步到你的帳號'), findsOneWidget);
        expect(find.text('3 位'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-contact')),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text(settingsContact), findsOneWidget);
        expect(find.text(settingsContactDetail), findsOneWidget);

        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('settings-hidden-riders')),
          -100,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.byKey(const ValueKey('settings-hidden-riders')));
        await tester.pumpAndSettle();
        expect(find.byType(HiddenRidersPage), findsOneWidget);
      });
    }
  });

  group('跟著帳號同步（v174）', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('登入時取聯集，同一個人保留較早的日期', () async {
      final account = FakeAccountList([
        rider(handleA, '阿明', DateTime.utc(2026, 10, 1)),
        rider(handleK, 'Ken', DateTime.utc(2026, 10, 5)),
      ]);
      var now = DateTime.utc(2026, 11, 1);
      final hidden = HiddenRiders(prefs, remote: account, clock: () => now);
      // As a guest: 阿明 again (later) and someone new.
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      now = DateTime.utc(2026, 11, 2);
      await hidden.hide(handle: handleU, name: '', spotName: '永吉路');
      expect(account.calls, isEmpty);

      await hidden.signedIn('rider-1');
      expect(hidden.riders.map((r) => r.handle), [handleU, handleK, handleA]);
      expect(hidden.byHandle(handleA)!.hiddenAt, DateTime.utc(2026, 10, 1));
      expect(account.rows.map((r) => r.handle).toSet(), {
        handleA,
        handleK,
        handleU,
      });
      // The device keeps a copy for the next launch.
      expect(HiddenRiders(prefs).length, 3);
    });

    test('登出清掉這台裝置的副本，帳號清單還在', () async {
      final account = FakeAccountList([
        rider(handleA, '阿明', DateTime.utc(2026, 10, 1)),
      ]);
      final hidden = HiddenRiders(prefs, remote: account);
      await hidden.signedIn('rider-1');
      expect(hidden.isHidden(handleA), isTrue);
      await hidden.signedOut();
      expect(hidden.isEmpty, isTrue);
      expect(HiddenRiders(prefs).isEmpty, isTrue);
      expect(account.rows, hasLength(1));
    });

    test('未登入時新增的隱藏存在本機，再登入時併入帳號', () async {
      final account = FakeAccountList([
        rider(handleA, '阿明', DateTime.utc(2026, 10, 1)),
      ]);
      final hidden = HiddenRiders(prefs, remote: account);
      await hidden.signedIn('rider-1');
      await hidden.signedOut();
      await hidden.hide(handle: handleK, name: 'Ken', spotName: '松壽');
      expect(account.rows.map((r) => r.handle), [handleA]);
      // Kept on the device while signed out.
      expect(HiddenRiders(prefs).isHidden(handleK), isTrue);
      await hidden.signedIn('rider-1');
      expect(hidden.riders.map((r) => r.handle).toSet(), {handleA, handleK});
      expect(account.rows.map((r) => r.handle).toSet(), {handleA, handleK});
    });

    test('登入後新增、解除都同步到帳號', () async {
      final account = FakeAccountList();
      final hidden = HiddenRiders(prefs, remote: account);
      await hidden.signedIn('rider-1');
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await hidden.sync();
      expect(account.rows.map((r) => r.handle), [handleA]);
      await hidden.unhide(handleA);
      await hidden.sync();
      expect(account.rows, isEmpty);
    });

    test('同步失敗：保留本機清單、不擋操作，下次再送', () async {
      final account = FakeAccountList()..offline = true;
      final hidden = HiddenRiders(prefs, remote: account);
      await hidden.signedIn('rider-1');
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await hidden.sync();
      expect(hidden.isHidden(handleA), isTrue);
      expect(account.rows, isEmpty);
      account.offline = false;
      await hidden.sync();
      expect(account.rows.map((r) => r.handle), [handleA]);
      expect(hidden.isHidden(handleA), isTrue);
    });

    test('沒有帳號清單（API 未上線）時登入登出都不動本機清單', () async {
      final hidden = HiddenRiders(prefs);
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await hidden.signedIn('rider-1');
      await hidden.signedOut();
      expect(hidden.isHidden(handleA), isTrue);
    });

    test('上限 500 筆', () async {
      var t = 0;
      final hidden = HiddenRiders(
        prefs,
        clock: () => DateTime.utc(2026).add(Duration(seconds: t++)),
      );
      for (var i = 0; i < hiddenRidersLimit; i++) {
        await hidden.hide(
          handle: i.toRadixString(16).padLeft(32, '0'),
          name: '',
          spotName: '',
        );
      }
      expect(
        () => hidden.hide(handle: handleA, name: '阿明', spotName: ''),
        throwsA(isA<HiddenRidersFull>()),
      );
    });

    test('API 欄位：name_at_hide、spot_name_at_hide、hidden_at', () {
      final row = HiddenRider.fromApi({
        'handle': handleA,
        'name_at_hide': '阿明',
        'spot_name_at_hide': '市府',
        'hidden_at': '2026-11-01T01:00:00Z',
      })!;
      expect(row.name, '阿明');
      expect(row.spotName, '市府');
      expect(row.toApi(), {
        'handle': handleA,
        'name_at_hide': '阿明',
        'spot_name_at_hide': '市府',
        'hidden_at': '2026-11-01T01:00:00.000Z',
      });
    });
  });

  for (final platform in platforms) {
    testWidgetsOn('${platform.name} P17c ④ 沒登入：提醒卡與登入按鈕', (tester) async {
      setUpView(tester, platform, const Size(390, 844));
      final store = (await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues(threeHidden());
        return GuestStore(
          LocalRepository(await SharedPreferences.getInstance()),
        );
      }))!;
      await tester.pumpWidget(app(HiddenRidersPage(store: store)));
      await tester.pumpAndSettle();
      expect(find.text(hiddenRidersGuestNote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('hidden-riders-sign-in')),
        findsOneWidget,
      );
      expect(find.text(hiddenRidersFootnote), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  group('後端形狀（#315）', () {
    test('三支 RPC 回 {items, limit}，欄位對得上', () async {
      final calls = <String, Object?>{};
      final store = RemoteHiddenRidersStore(
        apiClient((name, body) {
          calls[name] = body;
          return jsonResponse({
            'items': [
              {
                'handle': handleA,
                'name_at_hide': '阿明',
                'spot_name_at_hide': '市府',
                'hidden_at': '2026-11-01T01:00:00Z',
              },
            ],
            'limit': 500,
          });
        }),
      );
      expect((await store.list()).single.name, '阿明');
      final merged = await store.merge([
        rider(handleK, 'Ken', DateTime.utc(2026, 11, 2)),
      ]);
      expect(merged.single.handle, handleA);
      expect(calls['hidden_riders_merge'], {
        'items': [
          {
            'handle': handleK,
            'name_at_hide': 'Ken',
            'spot_name_at_hide': '某處',
            'hidden_at': '2026-11-02T00:00:00.000Z',
          },
        ],
      });
      await store.remove(handleA);
      expect(calls['hidden_riders_remove'], {'handle': handleA});
    });

    test('hidden_riders.too_many 變成上限錯誤，其他錯誤帶穩定代碼', () async {
      final full = RemoteHiddenRidersStore(
        apiClient(
          (_, _) => jsonResponse({
            'code': 'PT400',
            'message': 'hidden_riders.too_many',
            'details': {'limit': 500},
          }, 400),
        ),
      );
      expect(() => full.merge([]), throwsA(isA<HiddenRidersFull>()));
      final signedOut = RemoteHiddenRidersStore(
        apiClient(
          (_, _) => jsonResponse({
            'code': 'PT401',
            'message': 'auth.sign_in_required',
          }, 401),
        ),
      );
      expect(
        () => signedOut.list(),
        throwsA(
          isA<ApiV1Exception>().having(
            (e) => e.message,
            'message',
            'auth.sign_in_required',
          ),
        ),
      );
    });

    test('帳號拒收超過 500 位：本機清單保留，標示上限，下次再送', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final account = _FullAccount();
      final hidden = HiddenRiders(prefs, remote: account);
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await hidden.signedIn('rider-1');
      expect(hidden.accountFull, isTrue);
      expect(hidden.isHidden(handleA), isTrue);
      account.full = false;
      await hidden.sync();
      expect(hidden.accountFull, isFalse);
      expect(account.rows.single.handle, handleA);
    });

    test('名稱最多 40 字、點位名稱最多 100 字，存的時候就截斷', () async {
      SharedPreferences.setMockInitialValues({});
      final hidden = HiddenRiders(await SharedPreferences.getInstance());
      final row = await hidden.hide(
        handle: handleA,
        name: '阿' * 41,
        spotName: '😀' * 101,
      );
      expect(row.name.runes.length, 40);
      expect(row.spotName.runes.length, 100);
    });

    test('spots_by_ids：每批最多 200 筆，讀出 contributor_handle', () async {
      final batches = <int>[];
      final source = RemoteFavoriteHandles(
        apiClient((name, body) {
          expect(name, 'spots_by_ids');
          final ids = ((body! as Map)['ids'] as List).cast<String>();
          batches.add(ids.length);
          return jsonResponse({
            'spots': [
              for (final id in ids)
                {
                  'id': id,
                  'source': 'community',
                  'name': '點 $id',
                  'lat': 25.03,
                  'lng': 121.56,
                  'contributor_handle': id == 'b' ? null : handleA,
                  'is_own': false,
                },
            ],
          });
        }),
      );
      final ids = ['a', 'b', for (var i = 0; i < 448; i++) 'id$i'];
      final handles = await source.handlesFor(ids);
      expect(batches, [200, 200, 50]);
      expect(handles['a'], (handle: handleA, isOwn: false));
      expect(handles['b'], (handle: null, isOwn: false));
      expect(handles, hasLength(450));
    });
  });

  group('同步的時序（Codex 第 1 輪）', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('重新啟動：同一帳號的快取不整份 merge，以帳號清單為準', () async {
      final account = FakeAccountList([
        rider(handleA, '阿明', DateTime.utc(2026, 10, 1)),
      ]);
      final first = HiddenRiders(prefs, remote: account);
      await first.signedIn('rider-1');
      expect(first.isHidden(handleA), isTrue);
      // Unhidden on another device meanwhile.
      account.rows = [];
      account.calls.clear();
      final relaunched = HiddenRiders(prefs, remote: account);
      expect(relaunched.isHidden(handleA), isTrue); // the cache, at once
      await relaunched.signedIn('rider-1');
      expect(account.calls, ['list']);
      expect(relaunched.isHidden(handleA), isFalse);
      expect(account.rows, isEmpty);
    });

    test('重新啟動：只送還沒同步的異動', () async {
      final account = FakeAccountList()..offline = true;
      final first = HiddenRiders(prefs, remote: account);
      await first.signedIn('rider-1');
      await first.hide(handle: handleK, name: 'Ken', spotName: '松壽');
      await first.sync();
      expect(account.rows, isEmpty);
      account
        ..offline = false
        ..calls.clear();
      final relaunched = HiddenRiders(prefs, remote: account);
      await relaunched.signedIn('rider-1');
      expect(account.calls, ['merge']);
      expect(account.rows.map((r) => r.handle), [handleK]);
    });

    test('同步進行中又有異動：這一輪結束後接著送完', () async {
      final account = GatedAccount();
      final hidden = HiddenRiders(prefs, remote: account);
      final signing = hidden.signedIn('rider-1');
      await account.waiting(); // the first list
      account.release();
      await signing;
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await account.waiting(); // merge of 阿明 in flight
      // 復原 before the merge answers.
      await hidden.unhide(handleA);
      account.release();
      await account.waiting(); // the next round: remove
      account.release();
      await account.waiting(); // then list
      account.release();
      await pumpEventQueue();
      expect(account.calls, ['list', 'merge', 'remove', 'list']);
      expect(account.rows, isEmpty);
      expect(hidden.isHidden(handleA), isFalse);
      expect(prefs.getStringList('hiddenRidersPendingRemoves'), isEmpty);
      expect(prefs.getStringList('hiddenRidersPendingAdds'), isEmpty);
    });

    test('A 的同步未回應就登出改登入 B：A 的回應不會寫進 B 的清單', () async {
      final accountA = [rider(handleA, '阿明', DateTime.utc(2026, 10, 1))];
      final account = GatedAccount();
      final hidden = HiddenRiders(prefs, remote: account);
      final signingA = hidden.signedIn('rider-a');
      await account.waiting(); // A's list in flight
      await hidden.signedOut();
      final signingB = hidden.signedIn('rider-b');
      // A's answer arrives now, while B is signed in.
      account.release(accountA);
      await signingA;
      await account.waiting(); // B's own list
      account.release(const []);
      await signingB;
      expect(hidden.isHidden(handleA), isFalse);
      expect(HiddenRiders(prefs).isHidden(handleA), isFalse);
    });

    test('merge 進行中隱藏新車友，回應在存檔期間抵達：那筆留著並補送', () async {
      final account = GatedAccount();
      final hidden = HiddenRiders(prefs, remote: account);
      final signing = hidden.signedIn('rider-1');
      await account.waiting(); // the first list
      account.release();
      await signing;
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await account.waiting(); // merge of 阿明 in flight
      // Hide 新車友 and let the merge answer before its save finishes.
      final hiding = hidden.hide(handle: handleK, name: 'Ken', spotName: '松壽');
      account.release();
      await hiding;
      expect(hidden.isHidden(handleK), isTrue);
      await account.waiting(); // the next round sends Ken
      account.release();
      await pumpEventQueue();
      expect(hidden.isHidden(handleK), isTrue);
      expect(hidden.isHidden(handleA), isTrue);
      expect(account.rows.map((r) => r.handle).toSet(), {handleA, handleK});
      expect(prefs.getStringList('hiddenRidersPendingAdds'), isEmpty);
    });

    test('merge 進行中解除隱藏，回應在存檔期間抵達：那筆不會回來', () async {
      final account = GatedAccount();
      final hidden = HiddenRiders(prefs, remote: account);
      final signing = hidden.signedIn('rider-1');
      await account.waiting();
      account.release();
      await signing;
      await hidden.hide(handle: handleA, name: '阿明', spotName: '市府');
      await account.waiting(); // merge of 阿明 in flight
      final unhiding = hidden.unhide(handleA);
      account.release();
      await unhiding;
      expect(hidden.isHidden(handleA), isFalse);
      await account.waiting(); // remove
      account.release();
      await account.waiting(); // list
      account.release();
      await pumpEventQueue();
      expect(hidden.isHidden(handleA), isFalse);
      expect(account.rows, isEmpty);
    });

    test('換帳號登入：上一個帳號留下的快取不會併進來', () async {
      final account = FakeAccountList([
        rider(handleA, '阿明', DateTime.utc(2026, 10, 1)),
      ]);
      final first = HiddenRiders(prefs, remote: account);
      await first.signedIn('rider-a');
      // The app quit before the sign-out reached the list.
      account.rows = [];
      final next = HiddenRiders(prefs, remote: account);
      await next.signedIn('rider-b');
      expect(next.isEmpty, isTrue);
      expect(account.rows, isEmpty);
    });
  });

  group('本機 500 位上限', () {
    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 確認後顯示上限提示，回傳未隱藏', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final store = (await tester.runAsync(() async {
          final s = await storeWith({});
          var t = 0;
          for (var i = 0; i < hiddenRidersLimit; i++) {
            await s.hiddenRiders.restore(
              HiddenRider(
                handle: i.toRadixString(16).padLeft(32, '0'),
                name: '',
                spotName: '',
                hiddenAt: DateTime.utc(2026).add(Duration(seconds: t++)),
              ),
            );
          }
          return s;
        }))!;
        bool? result;
        var closed = false;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => result = await hideRider(
                    context,
                    store,
                    handle: handleA,
                    name: '阿明',
                    spotName: '市府',
                    onHidden: () => closed = true,
                  ),
                  child: const Text('hide'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('hide'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(hideRiderConfirm));
        await tester.pumpAndSettle();
        expect(result, isFalse);
        expect(closed, isFalse);
        expect(find.text(hiddenRidersFull), findsOneWidget);
        expect(store.hiddenRiders.isHidden(handleA), isFalse);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgetsOn('P17c 解除隱藏：螢幕閱讀器點兩下也有作用', (tester) async {
    setUpView(tester, TargetPlatform.android, const Size(390, 844));
    final store = (await tester.runAsync(() => storeWith(threeHidden())))!;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app(HiddenRidersPage(store: store)));
    await tester.pumpAndSettle();
    tester.semantics.tap(find.semantics.byLabel('解除隱藏 阿明'));
    await tester.pumpAndSettle();
    expect(store.hiddenRiders.isHidden(handleA), isFalse);
    semantics.dispose();
  });

  group('同步失敗後自動補送（Codex 第 5 輪）', () {
    /// Signed in and offline, with [handleA] waiting to go up.
    Future<(AppStore, FakeAccountList, FakeUpdates)> waiting() async {
      SharedPreferences.setMockInitialValues({});
      final account = FakeAccountList();
      final updates = FakeUpdates();
      final store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        dataUpdates: updates,
        hiddenRidersAccount: account,
      )..listenForUpdates();
      await store.hiddenRiders.signedIn('rider-1');
      account.offline = true;
      await store.hiddenRiders.hide(
        handle: handleA,
        name: '阿明',
        spotName: '市府',
      );
      await pumpEventQueue();
      expect(account.rows, isEmpty);
      account
        ..offline = false
        ..calls.clear();
      return (store, account, updates);
    }

    test('App 回到前景：補送', () async {
      final (store, account, _) = await waiting();
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(account.rows.map((r) => r.handle), [handleA]);
      expect(account.calls, ['merge']);
    });

    test('恢復連線（Realtime 重新加入）：補送', () async {
      final (_, account, updates) = await waiting();
      updates.join();
      await pumpEventQueue();
      expect(account.rows.map((r) => r.handle), [handleA]);
    });

    test('離線時解除隱藏：回到前景補送刪除', () async {
      final (store, account, _) = await waiting();
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      account.offline = true;
      await store.hiddenRiders.unhide(handleA);
      await pumpEventQueue();
      expect(account.rows, hasLength(1));
      account.offline = false;
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(account.rows, isEmpty);
    });

    test('沒有待送的異動：回到前景、恢復連線都不發請求', () async {
      final (store, account, updates) = await waiting();
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      account.calls.clear();
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      updates.join();
      await pumpEventQueue();
      expect(account.calls, isEmpty);
    });

    test('同一帳號的登入事件：只送待送的，不重新初始化清單', () async {
      final (store, account, _) = await waiting();
      final before = store.hiddenRiders.riders;
      await store.hiddenRiders.signedIn('rider-1');
      expect(account.calls, ['merge']);
      expect(store.hiddenRiders.riders, before);
      // Nothing left: the same event sends nothing, and reads nothing.
      account.calls.clear();
      await store.hiddenRiders.signedIn('rider-1');
      expect(account.calls, isEmpty);
    });

    test('未登入：回到前景不發請求', () async {
      SharedPreferences.setMockInitialValues({});
      final account = FakeAccountList();
      final store = AppStore(
        LocalRepository(await SharedPreferences.getInstance()),
        null,
        hiddenRidersAccount: account,
      );
      await store.hiddenRiders.hide(handle: handleA, name: '', spotName: '');
      store.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(account.calls, isEmpty);
    });

    for (final platform in platforms) {
      testWidgetsOn('${platform.name} 打開已隱藏的車友：補送', (tester) async {
        setUpView(tester, platform, const Size(390, 844));
        final (store, account, _) = (await tester.runAsync(waiting))!;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openHiddenRiders(context, store),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(HiddenRidersPage), findsOneWidget);
        expect(account.rows.map((r) => r.handle), [handleA]);
      });
    }
  });
}

/// An account list that refuses merges as `hidden_riders.too_many`.
class _FullAccount extends FakeAccountList {
  bool full = true;
  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async {
    if (full) throw HiddenRidersFull();
    return super.merge(items);
  }
}

/// An account list whose every call waits for [release].
class GatedAccount extends FakeAccountList {
  final _gates = <Completer<List<HiddenRider>?>>[];
  final _arrived = StreamController<void>.broadcast();
  int _made = 0, _seen = 0;

  /// Resolves once a call is waiting that [waiting] has not seen yet.
  Future<void> waiting() async {
    while (_made <= _seen) {
      await _arrived.stream.first;
    }
    _seen++;
  }

  /// Answers the oldest waiting call, with [rows] as the account's list.
  void release([List<HiddenRider>? rows]) => _gates.removeAt(0).complete(rows);

  Future<List<HiddenRider>?> _gate() {
    final gate = Completer<List<HiddenRider>?>();
    _gates.add(gate);
    _made++;
    _arrived.add(null);
    return gate.future;
  }

  @override
  Future<List<HiddenRider>> list() async {
    final rows = await _gate();
    if (rows != null) return rows;
    return super.list();
  }

  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async {
    final rows = await _gate();
    if (rows != null) return rows;
    return super.merge(items);
  }

  @override
  Future<void> remove(String handle) async {
    await _gate();
    return super.remove(handle);
  }
}

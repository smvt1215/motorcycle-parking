// 已連結的登入方式 (#382, P19a/P19b/P19t): the domain rows and notes, the
// settings group on phone and tablet, iOS and Android, at large text, and the
// deletion notes that name the linked sign-ins.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/data/account_deletion.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/account_deletion_display.dart';
import 'package:motorcycle_parking/domain/account_display.dart';
import 'package:motorcycle_parking/features/settings/account_deletion_page.dart';
import 'package:motorcycle_parking/features/settings/linked_sign_ins.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'account_deletion_fakes.dart';

const _userId = '10000000-0000-4000-8000-000000000382';
const _relay = 'abc123@privaterelay.appleid.com';

Map<String, dynamic> _identity(String provider, String email) => {
  'id': '$provider-sub',
  'user_id': _userId,
  'identity_id': '$provider-identity',
  'provider': provider,
  'identity_data': {
    'email': email,
    // Never shown (#382 findings).
    'full_name': 'Google 姓名',
    'avatar_url': 'https://example.test/a.png',
  },
  'created_at': '2026-10-01T00:00:00Z',
  'last_sign_in_at': '2026-10-01T00:00:00Z',
  'updated_at': '2026-11-10T00:00:00Z',
};

final _google = _identity('google', 'azhe.rider@gmail.com');
final _apple = _identity('apple', 'azhe@icloud.com');
final _appleRelay = _identity('apple', _relay);

class _Store extends AppStore {
  _Store(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
}

/// A signed-in rider whose `/user` answers [identities]; [later], when set,
/// is what the server says after the first answer (linked elsewhere).
class _Fixture {
  _Fixture({
    required this.identities,
    this.later,
    this.email = 'azhe.rider@gmail.com',
  }) {
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
      httpClient: MockClient(_handle),
    );
  }
  final List<Map<String, dynamic>> identities;
  final List<Map<String, dynamic>>? later;
  final String email;
  late final SupabaseClient client;
  late final _Store store;
  var userCalls = 0;

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/auth/v1/user') {
      userCalls++;
      return http.Response(
        jsonEncode({
          'id': _userId,
          'email': email,
          'created_at': '2026-10-01T00:00:00Z',
          'app_metadata': {'provider': 'google'},
          'user_metadata': {'display_name': '阿哲'},
          'is_anonymous': false,
          'identities': userCalls > 1 ? later ?? identities : identities,
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (request.url.path.endsWith('/logout')) return http.Response('', 204);
    // Other calls (hidden riders) fail fast: a decoded REST answer started
    // in the fake zone keeps client.dispose() waiting.
    throw http.ClientException('unexpected ${request.url.path}');
  }

  Future<void> open() async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(
      LocalRepository(await SharedPreferences.getInstance()),
      client,
    );
    await client.auth.getSessionFromUrl(
      Uri.parse(
        'tw.motopark://login-callback/'
        '#access_token=test-access&refresh_token=test-refresh'
        '&expires_in=3600&token_type=bearer',
      ),
    );
  }

  Future<void> close() async {
    store.dispose();
    await client.dispose();
  }
}

({String provider, String? email}) _row(String provider, String? email) =>
    (provider: provider, email: email);

void main() {
  group('domain', () {
    test('只連 Google：一列，完整電子郵件', () {
      final rows = linkedSignIns([_row('google', 'a@gmail.com')]);
      expect(rows.map((r) => r.provider), [SignInProvider.google]);
      expect(rows.single.detail, 'a@gmail.com');
      expect(rows.single.hiddenEmail, isFalse);
      expect(linksGoogleAndApple(rows), isFalse);
      expect(linkedSignInsRelayLine(rows), linkedSignInsRelayNote);
    });

    test('兩種都連：Google 在上、Apple 在下，各自的電子郵件', () {
      final rows = linkedSignIns([
        _row('apple', 'a@icloud.com'),
        _row('google', 'a@gmail.com'),
      ]);
      expect(rows.map((r) => r.provider.label), ['Google', 'Apple']);
      expect(rows.map((r) => r.detail), ['a@gmail.com', 'a@icloud.com']);
      expect(linksGoogleAndApple(rows), isTrue);
      expect(linkedSignInsRelayLine(rows), linkedSignInsRelayNote);
    });

    test('只連 Apple 轉寄地址：隱藏的電子郵件與針對性說明', () {
      final rows = linkedSignIns([_row('apple', _relay)]);
      expect(rows.single.hiddenEmail, isTrue);
      expect(rows.single.detail, appleHiddenEmail);
      expect(linkedSignInsRelayLine(rows), linkedSignInsRelaySelf);
    });

    test('Google 加上後來變成轉寄地址的 Apple：用一般說明', () {
      final rows = linkedSignIns([
        _row('google', 'a@gmail.com'),
        _row('apple', 'X@PrivateRelay.AppleID.com'),
      ]);
      expect(rows.last.detail, appleHiddenEmail);
      expect(linkedSignInsRelayLine(rows), linkedSignInsRelayNote);
    });

    test('空清單、其他提供者、重複與空白電子郵件', () {
      expect(linkedSignIns(const []), isEmpty);
      expect(linkedSignIns([_row('email', 'a@b.c')]), isEmpty);
      final rows = linkedSignIns([
        _row('google', '  '),
        _row('google', 'second@gmail.com'),
        _row('apple', null),
      ]);
      expect(rows, hasLength(2));
      expect(rows.map((r) => r.detail), [null, null]);
      expect(rows.last.hiddenEmail, isFalse);
    });

    test('轉寄地址判斷不分大小寫，帳號卡片也顯示隱藏的電子郵件', () {
      expect(isAppleRelayEmail(_relay), isTrue);
      expect(isAppleRelayEmail('A@PRIVATERELAY.APPLEID.COM'), isTrue);
      expect(isAppleRelayEmail('a@icloud.com'), isFalse);
      expect(accountEmailLine(_relay), appleHiddenEmail);
      expect(accountEmailLine('a@gmail.com'), 'a@gmail.com');
      expect(accountEmailLine(null), isNull);
      expect(reauthAccountLine(email: _relay, apple: true), 'Apple ID・隱藏的電子郵件');
      expect(
        reauthAccountLine(email: 'azhe@icloud.com', apple: true),
        'a••••@icloud.com・Apple',
      );
    });

    test('刪除說明（P19b）', () {
      expect(deletionDeleted.first, '帳號與所有已連結的登入方式（Google、Apple）');
      expect(
        deletionDeletedNote(googleAndApple: true),
        '$deletionBothLinkedNote\n$deletionRelayAccountNote',
      );
      expect(
        deletionDeletedNote(googleAndApple: false),
        deletionRelayAccountNote,
      );
      expect(
        deletionReauthNoteFor(apple: false, google: true),
        deletionReauthNote,
      );
      expect(
        deletionReauthNoteFor(apple: true, google: false),
        '這個帳號連結了 Apple，送出前會請你再用 Apple 登入一次，以便撤銷「使用 Apple 登入」的授權。',
      );
      expect(
        deletionReauthNoteFor(apple: true, google: true),
        '這個帳號連結了 Apple，送出前會請你再用 Apple 登入一次，以便撤銷「使用 Apple 登入」的授權。'
        '平常用 Google 登入也一樣。',
      );
      expect(reauthBodyFor(apple: false), reauthBody);
      expect(
        reauthBodyFor(apple: true),
        '這個帳號連結了 Apple。為了確認是你本人，並撤銷「使用 Apple 登入」的授權，請再用 Apple 登入一次。',
      );
      expect(
        deletionConfirmBody,
        '帳號和所有已連結的登入方式會在 7 天後一起刪除。這段期間登入時可以選擇取消；之後就無法復原。',
      );
    });
  });

  group('帳號與設定（P19a／P19t）', () {
    Future<_Fixture?> openSettings(
      WidgetTester tester, {
      required Size size,
      List<Map<String, dynamic>> identities = const [],
      List<Map<String, dynamic>>? later,
      String email = 'azhe.rider@gmail.com',
      bool signedIn = true,
      bool demo = false,
      double scale = 1,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      _Fixture? fixture;
      late AppStore store;
      if (demo) {
        SharedPreferences.setMockInitialValues({});
        store = (await tester.runAsync(
          () async => _Store(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
          ),
        ))!;
        addTearDown(store.dispose);
      } else {
        // Built outside the fake zone, or client.dispose() never returns.
        final value = fixture = (await tester.runAsync(() async {
          final value = _Fixture(
            identities: identities,
            later: later,
            email: email,
          );
          if (signedIn) {
            await value.open();
          } else {
            SharedPreferences.setMockInitialValues({});
            value.store = _Store(
              LocalRepository(await SharedPreferences.getInstance()),
              value.client,
            );
          }
          return value;
        }))!;
        store = value.store;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(value.close);
        });
      }
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            // ignore: deprecated_member_use
            child: MaterialUiCompatibilityBridge(child: child!),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSettings(context, store),
                child: const Text('開啟'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開啟'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      return fixture;
    }

    final group = find.byKey(const ValueKey('settings-linked-sign-ins'));
    final googleRow = find.byKey(const ValueKey('linked-google'));
    final appleRow = find.byKey(const ValueKey('linked-apple'));

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      for (final size in const [
        Size(390, 844),
        Size(820, 1180),
        Size(1180, 820),
      ]) {
        for (final scale in const [1.0, 2.0]) {
          final where =
              '${platform.name} ${size.width.toInt()}×${size.height.toInt()} '
              '字級 $scale';
          testWidgets(
            '② 兩種都連：Google 在上、Apple 在下，唯讀，不溢位（$where）',
            variant: TargetPlatformVariant.only(platform),
            (tester) async {
              await openSettings(
                tester,
                size: size,
                scale: scale,
                identities: [_apple, _google],
              );
              expect(group, findsOneWidget);
              expect(find.text(linkedSignInsTitle), findsOneWidget);
              expect(
                tester.getTopLeft(googleRow).dy,
                lessThan(tester.getTopLeft(appleRow).dy),
              );
              for (final row in [googleRow, appleRow]) {
                final tile = tester.widget<ListTile>(row);
                expect(tile.onTap, isNull);
                expect(tile.trailing, isNull);
              }
              // Full addresses (user decision, 2026-11-11); the card keeps
              // the account email, so Google's shows twice.
              expect(find.text('azhe.rider@gmail.com'), findsNWidgets(2));
              expect(find.text('azhe@icloud.com'), findsOneWidget);
              expect(find.text(linkedSignInsAutoLink), findsOneWidget);
              expect(find.text(linkedSignInsRelayNote), findsOneWidget);
              expect(find.textContaining('Google 姓名'), findsNothing);
              // Below the account card, before 隱私.
              expect(
                tester.getTopLeft(group).dy,
                greaterThan(
                  tester
                      .getTopLeft(find.byKey(const ValueKey('account-title')))
                      .dy,
                ),
              );
              await tester.ensureVisible(find.text(linkedSignInsRelayNote));
              await tester.pumpAndSettle();
              final privacy = find.text('隱私');
              await tester.ensureVisible(privacy);
              await tester.pumpAndSettle();
              expect(
                tester.getBottomLeft(find.text(linkedSignInsRelayNote)).dy,
                lessThan(tester.getTopLeft(privacy).dy),
              );
              expect(tester.takeException(), isNull);
            },
          );
        }
      }

      testWidgets(
        '① 只連 Google（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          await openSettings(
            tester,
            size: const Size(390, 844),
            identities: [_google],
          );
          expect(googleRow, findsOneWidget);
          expect(appleRow, findsNothing);
          expect(find.text('未連結'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '③ 只連 Apple 轉寄地址：帳號卡片與該列都寫隱藏的電子郵件（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          await openSettings(
            tester,
            size: const Size(390, 844),
            identities: [_appleRelay],
            email: _relay,
          );
          expect(googleRow, findsNothing);
          expect(
            find.descendant(
              of: appleRow,
              matching: find.text(appleHiddenEmail),
            ),
            findsOneWidget,
          );
          expect(find.text(appleHiddenEmail), findsNWidgets(2));
          expect(find.textContaining('privaterelay'), findsNothing);
          expect(find.text(linkedSignInsRelaySelf), findsOneWidget);
          expect(find.text(linkedSignInsRelayNote), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('讀不到 identities：整組不顯示', (tester) async {
      await openSettings(tester, size: const Size(390, 844));
      expect(group, findsNothing);
      expect(find.text(linkedSignInsTitle), findsNothing);
    });

    testWidgets('未登入：不顯示', (tester) async {
      await openSettings(
        tester,
        size: const Size(390, 844),
        signedIn: false,
        identities: [_google],
      );
      expect(group, findsNothing);
      expect(find.text('尚未登入'), findsOneWidget);
    });

    testWidgets('範例模式：不顯示', (tester) async {
      await openSettings(tester, size: const Size(390, 844), demo: true);
      expect(group, findsNothing);
      expect(find.text('範例模式'), findsOneWidget);
    });

    testWidgets('開啟時向伺服器更新：別的裝置連結的 Apple 也會出現', (tester) async {
      final fixture = await openSettings(
        tester,
        size: const Size(390, 844),
        identities: [_google],
        later: [_google, _apple],
      );
      expect(fixture!.userCalls, greaterThanOrEqualTo(2));
      expect(googleRow, findsOneWidget);
      expect(appleRow, findsOneWidget);
      expect(find.text('azhe@icloud.com'), findsOneWidget);
    });

    testWidgets('更新失敗或回傳空清單：保留原本的清單', (tester) async {
      await openSettings(
        tester,
        size: const Size(390, 844),
        identities: [_google],
        later: const [],
      );
      expect(googleRow, findsOneWidget);
    });
  });

  group('刪除帳號（P19b ②③④）', () {
    Future<_Fixture> openDeletion(
      WidgetTester tester, {
      required List<Map<String, dynamic>> identities,
      required AccountIdentity me,
      Size size = const Size(390, 844),
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Built outside the fake zone, or client.dispose() never returns.
      final fixture = (await tester.runAsync(() async {
        final value = _Fixture(identities: identities);
        await value.open();
        return value;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      final gateway = FakeDeletionGateway(current: me);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              // ignore: deprecated_member_use
              MaterialUiCompatibilityBridge(child: child!),
          home: AccountDeletionPage(
            store: fixture.store,
            deletion: AccountDeletionController(gateway),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return fixture;
    }

    Future<void> scrollTo(WidgetTester tester, Finder target) async {
      await tester.scrollUntilVisible(
        target,
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('deletion-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      testWidgets(
        '兩種都連（平常用 Google 登入）：說明、按鈕說明、對話框與 Apple 再登入（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          // Signed in with Google; Apple linked makes the gateway's `apple`
          // true, as SupabaseDeletionGateway.current does.
          final me = AccountIdentity(
            id: 'rider',
            email: 'azhe.rider@gmail.com',
            name: '阿哲',
            apple: true,
            signedInAt: DateTime.now().toUtc(),
            appleToken: 'apple-rt',
            appleTokenHint: 'refresh_token',
          );
          await openDeletion(tester, identities: [_google, _apple], me: me);
          expect(find.text(deletionDeleted.first), findsOneWidget);
          await scrollTo(
            tester,
            find.text(deletionDeletedNote(googleAndApple: true)),
          );
          final note = find.byKey(const ValueKey('deletion-reauth-note'));
          await scrollTo(tester, note);
          expect(
            tester.widget<Text>(note).data,
            deletionReauthNoteFor(apple: true, google: true),
          );
          final submit = find.byKey(const ValueKey('deletion-submit'));
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(find.text(deletionConfirmBody), findsOneWidget);
          await tester.tap(find.text(deletionConfirmAction).last);
          await tester.pumpAndSettle();
          expect(
            tester.widget<Text>(find.byKey(const ValueKey('reauth-body'))).data,
            reauthBodyFor(apple: true),
          );
          // The Apple sign-in's own address, masked as before.
          expect(find.text('a••••@icloud.com・Apple'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('只連 Google：沒有兩種都連的句子，按鈕說明照舊', (tester) async {
      await openDeletion(
        tester,
        identities: [_google],
        me: google(signedInAt: DateTime.now().toUtc()),
      );
      await scrollTo(
        tester,
        find.text(deletionDeletedNote(googleAndApple: false)),
      );
      expect(find.textContaining(deletionBothLinkedNote), findsNothing);
      final note = find.byKey(const ValueKey('deletion-reauth-note'));
      await scrollTo(tester, note);
      expect(tester.widget<Text>(note).data, deletionReauthNote);
    });

    testWidgets('只連 Apple：按鈕說明沒有 Google 那句', (tester) async {
      await openDeletion(
        tester,
        identities: [_appleRelay],
        me: apple(signedInAt: DateTime.now().toUtc()),
      );
      final note = find.byKey(const ValueKey('deletion-reauth-note'));
      await scrollTo(tester, note);
      expect(
        tester.widget<Text>(note).data,
        deletionReauthNoteFor(apple: true, google: false),
      );
    });
  });

  test('linkedSignInsOf: 未登入或匿名時是空清單', () {
    expect(linkedSignInsOf(null), isEmpty);
  });
}

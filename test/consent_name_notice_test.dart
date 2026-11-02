import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/core/policy_links.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/consent_display.dart';
import 'package:motorcycle_parking/domain/contributor_name.dart';
import 'package:motorcycle_parking/features/auth/profile_avatar.dart';
import 'package:motorcycle_parking/features/auth/report_name_notice.dart';
import 'package:motorcycle_parking/features/auth/sign_in.dart';
import 'package:motorcycle_parking/features/map/spot_details.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const _spot = ParkingSpot(
  id: 'near',
  name: '附近',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  spaceType: SpaceType.paidMotorcycle,
);

class _Store extends AppStore {
  _Store(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
  @override
  Future<Town?> townAt(double lat, double lng) async =>
      const Town('臺北市', '信義區');
}

/// A Supabase account whose name P12 can change; [signedIn] false leaves
/// the client without a session.
class _Account {
  _Account({this.metadata = const {'full_name': '阿哲'}});
  Map<String, dynamic> metadata;
  late final SupabaseClient client = SupabaseClient(
    'https://example.supabase.co',
    'test-key',
    authOptions: const AuthClientOptions(
      authFlowType: AuthFlowType.implicit,
      autoRefreshToken: false,
    ),
    httpClient: MockClient(_handle),
  );
  late final _Store store;

  Future<http.Response> _handle(http.Request request) async {
    Object body = [];
    if (request.url.path == '/auth/v1/user') {
      if (request.method == 'PUT') {
        final data = (jsonDecode(request.body) as Map)['data'] as Map;
        metadata = {...metadata, ...data.cast<String, dynamic>()};
      }
      body = {
        'id': '10000000-0000-4000-8000-000000000001',
        'email': 'rider@example.com',
        'created_at': '2026-10-01T00:00:00Z',
        'app_metadata': {'provider': 'google'},
        'user_metadata': metadata,
        'is_anonymous': false,
      };
    }
    return http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<_Store> open({bool signedIn = true}) async {
    SharedPreferences.setMockInitialValues({});
    store = _Store(
      LocalRepository(await SharedPreferences.getInstance()),
      client,
    )..spots = const [_spot];
    if (signedIn) {
      await client.auth.getSessionFromUrl(
        Uri.parse(
          'tw.motopark://login-callback/#access_token=test-access'
          '&refresh_token=test-refresh&expires_in=3600&token_type=bearer',
        ),
      );
    }
    await Future<void>.delayed(Duration.zero);
    return store;
  }
}

const _sizes = [Size(390, 844), Size(820, 1180), Size(1180, 820)];
const _platforms = [TargetPlatform.iOS, TargetPlatform.android];

void _view(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<_Account> _mount(
  WidgetTester tester, {
  required Widget Function(BuildContext, AppStore) child,
  bool signedIn = true,
  Map<String, dynamic>? metadata,
  double scale = 1,
}) async {
  final account = metadata == null ? _Account() : _Account(metadata: metadata);
  await tester.runAsync(() => account.open(signedIn: signedIn));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(account.client.dispose);
  });
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        // Match the app's bridge for CNBottomSheet's Material localizations.
        // ignore: deprecated_member_use
        child: MaterialUiCompatibilityBridge(child: child!),
      ),
      home: Scaffold(
        body: Builder(builder: (context) => child(context, account.store)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return account;
}

Widget _opener(String label, VoidCallback onPressed) => Align(
  alignment: Alignment.topCenter,
  child: TextButton(onPressed: onPressed, child: Text(label)),
);

void _noOverflow(WidgetTester tester) {
  final error = tester.takeException();
  expect(error, isNull, reason: '$error');
}

void main() {
  group('email 與名稱規則', () {
    test('只看 email 格式', () {
      expect(isEmailLike('a@b.tw'), isTrue);
      expect(isEmailLike(' rider@example.com '), isTrue);
      expect(isEmailLike('阿哲@台北'), isFalse);
      expect(isEmailLike('@阿哲'), isFalse);
      expect(isEmailLike('a@b'), isFalse);
      expect(isEmailLike('a b@c.tw'), isFalse);
      expect(isEmailLike(''), isFalse);
    });

    test('公開名稱：空白與 email 不公開，含 @ 的名稱照常公開', () {
      expect(publicContributorName(null), isNull);
      expect(publicContributorName('   '), isNull);
      expect(publicContributorName('a@b.tw'), isNull);
      expect(publicContributorName(' 阿哲@台北 '), '阿哲@台北');
    });

    test('詳情頁的回報者沿用同一條 email 規則', () {
      ParkingSpot by(String name) => ParkingSpot(
        id: 's',
        name: 'n',
        lat: 25,
        lng: 121,
        city: '臺北市',
        spaceType: SpaceType.paidMotorcycle,
        contributorName: name,
      );
      expect(contributorSummary(by('rider@example.com')), '由車友回報');
      expect(contributorSummary(by('阿哲@台北')), '由車友 阿哲@台北 回報');
      expect(contributorSummary(by('  ')), '由車友回報');
    });

    test('頭像字：字母或數字才顯示，英文轉大寫', () {
      expect(avatarInitial('阿哲'), '阿');
      expect(avatarInitial('rider'), 'R');
      expect(avatarInitial('9 號'), '9');
      expect(avatarInitial('  zoe'), 'Z');
      expect(avatarInitial('🏍️ 車友'), isNull);
      expect(avatarInitial('👨‍👩‍👧 家'), isNull);
      expect(avatarInitial('★阿哲'), isNull);
      expect(avatarInitial('「阿哲」'), isNull);
      expect(avatarInitial('   '), isNull);
      expect(avatarInitial(null), isNull);
      // A combining mark stays with its letter.
      expect(avatarInitial('émile'), 'É');
    });

    test('名稱超過 20 字只截名稱', () {
      expect(truncateName('阿哲'), '阿哲');
      expect(truncateName('一二三四五六七八九十一二三四五六七八九十'), hasLength(20));
      expect(truncateName('一二三四五六七八九十一二三四五六七八九十多'), '一二三四五六七八九十一二三四五六七八九十…');
    });
  });

  group('ProfileAvatar', () {
    Future<void> avatar(WidgetTester tester, {String? name, String? url}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: ProfileAvatar(name: name, url: url),
            ),
          ),
        );

    for (final (name, shown) in [
      ('阿哲', '阿'),
      ('rider', 'R'),
      ('9 號', '9'),
      ('  zoe', 'Z'),
    ]) {
      testWidgets('「$name」顯示 $shown', (tester) async {
        await avatar(tester, name: name);
        expect(find.text(shown), findsOneWidget);
        expect(find.byIcon(Icons.person_outline), findsNothing);
      });
    }

    for (final name in ['🏍️ 車友', '★阿哲', '「阿哲」', '', '   ']) {
      testWidgets('「$name」顯示通用人像', (tester) async {
        await avatar(tester, name: name);
        expect(find.byIcon(Icons.person_outline), findsOneWidget);
        expect(find.byType(Text), findsNothing);
      });
    }

    testWidgets('有照片時先顯示照片', (tester) async {
      await avatar(tester, name: '阿哲', url: 'https://example.test/a.png');
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.image, isA<NetworkImage>());
      expect(find.text('阿'), findsNothing);
    });
  });

  group('登入同意條款（P16a）', () {
    setUp(
      () => policyUrls = (
        privacy: 'https://example.test/privacy',
        terms: 'https://example.test/terms',
      ),
    );
    tearDown(() => policyUrls = (privacy: '', terms: ''));

    Future<void> openSignIn(WidgetTester tester, {double scale = 1}) async {
      await _mount(
        tester,
        signedIn: false,
        scale: scale,
        child: (context, store) =>
            _opener('開啟登入', () => showSignIn(context, store)),
      );
      await tester.tap(find.text('開啟登入'));
      await tester.pumpAndSettle();
    }

    for (final platform in _platforms) {
      final target = platform == TargetPlatform.iOS ? 44.0 : 48.0;
      for (final size in _sizes) {
        final where =
            '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';
        testWidgets('同意文字與兩個連結，觸控範圍足夠（$where）', (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          _view(tester, size);
          await openSignIn(tester);
          _noOverflow(tester);
          expect(find.text(signInNotNeededText), findsOneWidget);
          expect(find.text(consentLead), findsOneWidget);
          for (final key in ['consent-terms', 'consent-privacy']) {
            final box = tester.getSize(find.byKey(ValueKey(key)));
            expect(box.width, greaterThanOrEqualTo(target), reason: key);
            expect(box.height, greaterThanOrEqualTo(target), reason: key);
          }
          // The intro sits under the title, above the buttons.
          final first = SignInButtons.providers.first.name;
          expect(
            tester.getTopLeft(find.text(signInNotNeededText)).dy,
            lessThan(
              tester.getTopLeft(find.byKey(ValueKey('sign-in-$first'))).dy,
            ),
          );
          expect(
            tester.getTopLeft(find.byKey(const ValueKey('consent-terms'))).dy,
            greaterThan(
              tester.getBottomLeft(find.byKey(ValueKey('sign-in-$first'))).dy,
            ),
          );
          debugDefaultTargetPlatformOverride = null;
        });
      }

      testWidgets('字放大 200%：按鈕與同意文字一起留在畫面內（${platform.name}）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        _view(tester, const Size(390, 844));
        await openSignIn(tester, scale: 2);
        _noOverflow(tester);
        final screen = tester.view.physicalSize.height;
        for (final key in [
          'sign-in-${SignInButtons.providers.first.name}',
          'consent-privacy',
        ]) {
          final finder = find.byKey(ValueKey(key));
          expect(finder, findsOneWidget);
          expect(tester.getBottomLeft(finder).dy, lessThanOrEqualTo(screen));
          expect(tester.getTopLeft(finder).dy, greaterThanOrEqualTo(0));
        }
        final terms = tester.getSize(
          find.byKey(const ValueKey('consent-terms')),
        );
        expect(
          terms.height,
          greaterThanOrEqualTo(platform == TargetPlatform.iOS ? 44 : 48),
        );
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('按鈕與同意文字本身放不下時整張 sheet 捲動', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _view(tester, const Size(390, 300));
      await openSignIn(tester, scale: 2);
      _noOverflow(tester);
      final sheet = find.byKey(const ValueKey('sign-in-sheet-scroll'));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: sheet, matching: find.byType(Scrollable)).first,
          )
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('consent-privacy')),
        100,
        scrollable: find
            .descendant(of: sheet, matching: find.byType(Scrollable))
            .first,
      );
      expect(
        find.byKey(const ValueKey('consent-privacy')).hitTestable(),
        findsOneWidget,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('連結在 App 內瀏覽器開啟', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      _view(tester, const Size(390, 844));
      await openSignIn(tester);
      await tester.tap(find.byKey(const ValueKey('consent-terms')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('consent-privacy')));
      await tester.pumpAndSettle();
      final urls = [
        for (final c in calls)
          if ((c.arguments as Map?)?['url'] case final String url) url,
      ];
      expect(urls, [
        'https://example.test/terms',
        'https://example.test/privacy',
      ]);
      // Still on sign-in.
      expect(find.text(consentLead), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('朗讀：按鈕帶同意提示，連結唸成服務條款、隱私權政策', (tester) async {
      final semantics = tester.ensureSemantics();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _view(tester, const Size(390, 844));
      await openSignIn(tester);
      expect(
        tester.getSemantics(find.byKey(const ValueKey('sign-in-google'))),
        matchesSemantics(
          label: '使用 Google 登入',
          hint: consentHint,
          isButton: true,
          isFocusable: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
          hasFocusAction: true,
        ),
      );
      for (final (key, label) in [
        ('consent-terms', consentTerms),
        ('consent-privacy', consentPrivacy),
      ]) {
        final node = tester.getSemantics(find.byKey(ValueKey(key)));
        expect(node.label, label);
        expect(node.flagsCollection.isLink, isTrue);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
      // Reading order: intro, buttons, consent, 服務條款, 隱私權政策.
      double y(Finder f) => tester.getTopLeft(f).dy;
      expect(
        y(find.text(signInNotNeededText)),
        lessThan(y(find.byKey(const ValueKey('sign-in-google')))),
      );
      expect(
        y(find.byKey(const ValueKey('sign-in-google'))),
        lessThan(y(find.text(consentLead))),
      );
      expect(
        y(find.text(consentLead)),
        lessThan(y(find.byKey(const ValueKey('consent-terms')))),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('consent-terms'))).dx,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('consent-privacy'))).dx,
        ),
      );
      debugDefaultTargetPlatformOverride = null;
      semantics.dispose();
    });

    for (final platform in _platforms) {
      testWidgets('網址空白時顯示純文字與「僅開發用」（${platform.name}）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        policyUrls = (privacy: '', terms: 'https://example.test/terms');
        _view(tester, const Size(390, 844));
        await openSignIn(tester);
        expect(find.text(consentPlain), findsOneWidget);
        expect(find.text(consentDevOnly), findsOneWidget);
        expect(find.byKey(const ValueKey('consent-terms')), findsNothing);
        expect(find.byKey(const ValueKey('consent-privacy')), findsNothing);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('回報表單的登入卡也帶同意文字', (tester) async {
      _view(tester, const Size(390, 844));
      await _mount(
        tester,
        signedIn: false,
        child: (context, store) =>
            _opener('新增', () => showReport(context, store, 25.0339, 121.5623)),
      );
      await tester.tap(find.text('新增'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInConsent), findsOneWidget);
      // Signed out: no name notice until sign-in.
      expect(find.byKey(const ValueKey('report-name-notice')), findsNothing);
      // P16b wording on the card, and the intro line is not repeated.
      expect(find.text(newSpotSignInMessage), findsOneWidget);
      expect(find.text('新增的停車點會顯示於地圖，回報資訊待管理者確認；停放資格請依現場標示。'), findsNothing);
    });
  });

  group('名稱公開提示（P16b）', () {
    Future<_Account> notice(
      WidgetTester tester, {
      Map<String, dynamic>? metadata,
      double scale = 1,
    }) => _mount(
      tester,
      metadata: metadata,
      scale: scale,
      child: (context, store) => Padding(
        padding: const EdgeInsets.all(16),
        child: ReportNameNotice(store: store),
      ),
    );

    String noticeText(WidgetTester tester) => tester
        .widget<Text>(find.byKey(const ValueKey('report-name-text')))
        .textSpan!
        .toPlainText();

    for (final platform in _platforms) {
      final target = platform == TargetPlatform.iOS ? 44.0 : 48.0;
      for (final size in _sizes) {
        final where =
            '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';
        testWidgets('有名稱：公開顯示名稱，改名稱在同一行（$where）', (tester) async {
          debugDefaultTargetPlatformOverride = platform;
          _view(tester, size);
          await notice(tester);
          _noOverflow(tester);
          expect(noticeText(tester), '停車點會公開顯示「由車友 阿哲 回報」');
          final button = find.byKey(const ValueKey('report-name-edit'));
          expect(
            find.descendant(of: button, matching: find.text(nameNoticeRename)),
            findsOneWidget,
          );
          expect(tester.getSize(button).height, greaterThanOrEqualTo(target));
          expect(tester.getSize(button).width, greaterThanOrEqualTo(target));
          // Beside the sentence, not under it.
          expect(
            tester.getCenter(button).dy,
            moreOrLessEquals(
              tester
                  .getCenter(find.byKey(const ValueKey('report-name-text')))
                  .dy,
              epsilon: 2,
            ),
          );
          expect(find.text('阿'), findsOneWidget);
          debugDefaultTargetPlatformOverride = null;
        });
      }

      testWidgets('字放大 200%：句子完整、改名稱移到下方（${platform.name}）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        _view(tester, const Size(390, 844));
        await notice(tester, scale: 2);
        _noOverflow(tester);
        final text = find.byKey(const ValueKey('report-name-text'));
        final button = find.byKey(const ValueKey('report-name-edit'));
        expect(tester.widget<Text>(text).maxLines, isNull);
        expect(
          tester.getTopLeft(button).dy,
          greaterThanOrEqualTo(tester.getBottomLeft(text).dy - 1),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(target));
        debugDefaultTargetPlatformOverride = null;
      });
    }

    for (final (title, metadata) in [
      ('沒有名稱', <String, dynamic>{}),
      ('只有空白', {'full_name': '   '}),
      ('email 名稱', {'full_name': 'rider@example.com'}),
    ]) {
      testWidgets('$title：只顯示由車友回報、通用人像、設定名稱', (tester) async {
        _view(tester, const Size(390, 844));
        await notice(tester, metadata: metadata);
        expect(noticeText(tester), nameNoticeHidden);
        expect(find.text(nameNoticeSetName), findsOneWidget);
        expect(find.byIcon(Icons.person_outline), findsOneWidget);
        expect(find.textContaining('rider'), findsNothing);
      });
    }

    testWidgets('長名稱只截名稱，朗讀完整名稱', (tester) async {
      final semantics = tester.ensureSemantics();
      const long = '重機騎士阿哲的週末松山信義區巡禮小隊長兼團購主揪';
      _view(tester, const Size(390, 844));
      await notice(tester, metadata: {'full_name': long});
      expect(noticeText(tester), '停車點會公開顯示「由車友 重機騎士阿哲的週末松山信義區巡禮小隊長兼… 回報」');
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey('report-name-text')))
            .label,
        '停車點會公開顯示「由車友 $long 回報」',
      );
      semantics.dispose();
    });

    for (final platform in _platforms) {
      testWidgets('改名後這一行立即更新，表單內容保留（${platform.name}）', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        _view(tester, const Size(390, 844));
        await _mount(
          tester,
          child: (context, store) => _opener(
            '新增',
            () => showReport(context, store, 25.0339, 121.5623),
          ),
        );
        await tester.tap(find.text('新增'));
        await tester.pumpAndSettle();
        // The form's state survives P12: what was filled in stays.
        final form = tester.state(find.byType(ReportForm));
        final edit = find.byKey(const ValueKey('report-name-edit'));
        await tester.scrollUntilVisible(
          edit,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(noticeText(tester), contains('阿哲'));
        await tester.tap(edit);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('profile-name')),
          '小林',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('profile-save')));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('profile-name')), findsNothing);
        expect(noticeText(tester), '停車點會公開顯示「由車友 小林 回報」');
        expect(tester.state(find.byType(ReportForm)), same(form));
        debugDefaultTargetPlatformOverride = null;
      });
    }

    testWidgets('修改建議不顯示名稱這一行', (tester) async {
      _view(tester, const Size(390, 844));
      await _mount(
        tester,
        child: (context, store) =>
            _opener('建議', () => showSpotSuggestions(context, store, _spot)),
      );
      await tester.tap(find.text('建議'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportNameNotice), findsNothing);
      expect(find.text(nameNoticeRename), findsNothing);
    });
  });
}

/// P11's second line, now right under the title.
const signInNotNeededText = '瀏覽地圖與記錄停車位置不需登入。';

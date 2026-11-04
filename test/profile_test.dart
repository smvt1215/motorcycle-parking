import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/profile_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/account_display.dart';
import 'package:motorcycle_parking/features/auth/profile_avatar.dart';
import 'package:motorcycle_parking/features/auth/profile_editor.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const userId = '10000000-0000-4000-8000-000000000001';
const oldPath = '$userId/10000000-0000-4000-8000-000000000002.png';

class ProfileStore extends AppStore {
  ProfileStore(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
}

class ProfileFixture {
  ProfileFixture({Map<String, dynamic>? metadata, this.provider = 'google'})
    : metadata = metadata ?? {'full_name': '原始名稱'} {
    client = SupabaseClient(
      'https://example.supabase.co',
      'test-key',
      authOptions: const AuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        autoRefreshToken: false,
      ),
      httpClient: MockClient(handle),
    );
  }
  Map<String, dynamic> metadata;
  final String provider;
  late final SupabaseClient client;
  late final ProfileStore store;
  final updates = <Map<String, dynamic>>[];
  bool failUpdate = false;

  Map<String, dynamic> get user => {
    'id': userId,
    'email': 'rider@example.com',
    'created_at': '2026-10-01T00:00:00Z',
    'app_metadata': {'provider': provider},
    'user_metadata': metadata,
    'is_anonymous': false,
  };

  Future<http.Response> handle(http.Request request) async {
    Object response;
    var status = 200;
    if (request.url.path == '/auth/v1/user') {
      if (request.method == 'PUT') {
        if (failUpdate) return http.Response('{"msg":"try again"}', 400);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final data = Map<String, dynamic>.from(body['data'] as Map);
        updates.add(data);
        metadata = {...metadata, ...data};
      }
      response = user;
    } else {
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }
    return http.Response(
      jsonEncode(response),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  Future<void> open() async {
    SharedPreferences.setMockInitialValues({});
    store = ProfileStore(
      LocalRepository(await SharedPreferences.getInstance()),
      client,
    );
    await client.auth.getSessionFromUrl(
      Uri.parse(
        'tw.motopark://login-callback/#access_token=test-access&refresh_token=test-refresh&expires_in=3600&token_type=bearer',
      ),
    );
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    store.dispose();
    await client.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('自訂名稱與頭像優先，明確移除不重新使用提供者照片', () async {
    final fixture = ProfileFixture(
      metadata: {
        'display_name': '自訂名稱',
        'full_name': '提供者名稱',
        'avatar_url': 'https://example.test/provider.png',
        'profile_avatar_url': '',
      },
    );
    await fixture.open();
    addTearDown(fixture.close);
    expect(profilePublicName(fixture.client.auth.currentUser), '自訂名稱');
    expect(profileNameSuggestion(fixture.client.auth.currentUser), isNull);
    expect(profileAvatarUrl(fixture.client.auth.currentUser), isNull);
    // Blank is valid (#319): saving it clears the public name.
    expect(profileNameError(''), isNull);
    expect(profileNameError('  '), isNull);
    expect(profileNameError('換\n行'), isNotNull);
    expect(profileNameError('名' * 41), isNotNull);
    // Mirrors #81 server cleanup: Cf (bidi/ZWJ/BOM) removed, spaces collapsed.
    expect(normalizeProfileName(' \u202e騎\u200b士  小\ufeff明 '), '騎士 小明');
    expect(profileNameError('\u200b\u2066'), isNull);
    expect(profileNameError('\u0085名稱'), isNotNull);
    expect(profileNameError('${'名' * 40}\u200d'), isNull);
  });

  test('儲存前移除隱形格式字元，和伺服器顯示名稱一致', () async {
    final fixture = ProfileFixture();
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.store.updateProfile(displayName: ' \u202e新\u200b名稱 ');
    expect(fixture.updates.single['display_name'], '新名稱');
  });

  test('只改名稱時只更新 metadata，不碰照片且保留其他欄位', () async {
    final fixture = ProfileFixture(
      metadata: {
        'full_name': '原始名稱',
        'profile_avatar_path': oldPath,
        'profile_avatar_url': 'https://example.test/original.png',
        'other': 'keep',
      },
    );
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.store.updateProfile(displayName: '  新名稱  ');
    expect(fixture.updates.single, {'display_name': '新名稱'});
    expect(fixture.metadata['profile_avatar_path'], oldPath);
    expect(fixture.metadata['other'], 'keep');
  });

  Future<ProfileFixture> host(
    WidgetTester tester,
    double width, {
    bool settings = false,
    Map<String, dynamic>? metadata,
    double height = 1000,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final fixture = (await tester.runAsync(() async {
      final value = ProfileFixture(metadata: metadata);
      await value.open();
      return value;
    }))!;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(fixture.close);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                if (settings) {
                  showSettings(context, fixture.store);
                } else {
                  showAdaptiveSheet<void>(
                    context,
                    (_) => ProfileEditor(store: fixture.store),
                  );
                }
              },
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟'));
    await tester.pumpAndSettle();
    return fixture;
  }

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width 的深色放大字級可以編輯名稱，取消不寫入', (tester) async {
      final fixture = await host(tester, width);
      await tester.enterText(
        find.byKey(const ValueKey('profile-name')),
        '還沒儲存',
      );
      await tester.tap(find.byTooltip('關閉'));
      await tester.pumpAndSettle();
      expect(fixture.updates, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width 鍵盤彈出時仍可捲到並點擊儲存', (tester) async {
      final fixture = await host(tester, width, height: 640);
      await tester.tap(find.byKey(const ValueKey('profile-name')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('profile-name')),
        '鍵盤上的名稱',
      );
      await tester.pumpAndSettle();
      final save = find.byKey(const ValueKey('profile-save'));
      final box = tester.getRect(save);
      expect(box.bottom, lessThanOrEqualTo(640 - 300));
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      await tester.tap(save);
      await tester.runAsync(
        () async =>
            await Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(fixture.metadata['display_name'], '鍵盤上的名稱');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('P12 不顯示從相簿選擇與上傳說明，沒有頭像時不顯示移除；儲存失敗保留名稱並可重試', (tester) async {
    final fixture = await host(tester, 390);
    expect(find.text('從相簿選擇'), findsNothing);
    expect(find.textContaining('照片上傳'), findsNothing);
    expect(find.text('移除頭像'), findsNothing);
    expect(find.text('移除頭像會改回名稱首字。'), findsNothing);
    final save = find.byKey(const ValueKey('profile-save'));
    // The Google name is only a suggestion: saving it unchanged is allowed.
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    await tester.enterText(find.byKey(const ValueKey('profile-name')), '新名稱');
    await tester.pump();
    fixture.failUpdate = true;
    await tester.tap(save);
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('資料尚未儲存，內容還在，請確認連線後再試一次'), findsOneWidget);
    expect(find.text('新名稱'), findsOneWidget);
    fixture.failUpdate = false;
    await tester.tap(save);
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-name')), findsNothing);
    expect(fixture.metadata['display_name'], '新名稱');
    expect(tester.takeException(), isNull);
  });

  testWidgets('有登入服務大頭貼時照常顯示；移除後改回名稱首字並保留其他欄位', (tester) async {
    final fixture = await host(
      tester,
      390,
      metadata: {
        'full_name': '原始名稱',
        'avatar_url': 'https://example.test/provider.png',
        'other': 'keep',
      },
    );
    ProfileAvatar avatar() =>
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar));
    expect(avatar().url, 'https://example.test/provider.png');
    final save = find.byKey(const ValueKey('profile-save'));
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    // ② no public name yet: removing goes back to the default avatar.
    expect(find.text(profileRemoveAvatarHintDefault), findsOneWidget);
    expect(find.text(profileRemoveAvatarHint), findsNothing);
    await tester.tap(find.text('移除頭像'));
    await tester.pump();
    expect(find.text('移除頭像'), findsNothing);
    expect(find.text(profileRemoveAvatarHintDefault), findsNothing);
    expect(avatar().url, '');
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-name')), findsNothing);
    expect(fixture.updates.single, {
      'display_name': '原始名稱',
      'profile_avatar_url': '',
    });
    expect(fixture.metadata['other'], 'keep');
    expect(profileAvatarUrl(fixture.client.auth.currentUser), isNull);
  });

  testWidgets('移除頭像說明依公開名稱切換：有名稱回首字，清空後回預設頭像', (tester) async {
    await host(
      tester,
      390,
      metadata: {
        'display_name': '阿哲',
        'avatar_url': 'https://example.test/provider.png',
      },
    );
    expect(find.text(profileRemoveAvatarHint), findsOneWidget);
    expect(find.text(profileRemoveAvatarHintDefault), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('profile-name')), '');
    await tester.pump();
    expect(find.text(profileRemoveAvatarHint), findsNothing);
    expect(find.text(profileRemoveAvatarHintDefault), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('profile-name')), '小林');
    await tester.pump();
    expect(find.text(profileRemoveAvatarHint), findsOneWidget);
  });

  testWidgets('設定卡提供編輯入口，名稱儲存後回到設定即時更新', (tester) async {
    final fixture = await host(tester, 390, settings: true);
    await tester.tap(find.byTooltip('編輯個人資料'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('profile-name')), '新的騎士');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.text('帳號與設定'), findsOneWidget);
    expect(find.text('新的騎士'), findsOneWidget);
    expect(fixture.metadata['display_name'], '新的騎士');
  });

  group('公開名稱只看 display_name（#319）', () {
    User user(Map<String, dynamic> metadata, {String provider = 'google'}) =>
        User.fromJson({
          'id': userId,
          'aud': 'authenticated',
          'created_at': '2026-10-01T00:00:00Z',
          'app_metadata': {'provider': provider},
          'user_metadata': metadata,
        })!;

    test('profilePublicName', () {
      expect(profilePublicName(null), isNull);
      expect(profilePublicName(user({'display_name': ' 阿哲 '})), '阿哲');
      expect(profilePublicName(user({'display_name': '騎士​  小明'})), '騎士 小明');
      for (final blank in ['', '   ', '　　', ' 　\t', '​']) {
        expect(
          profilePublicName(user({'display_name': blank, 'full_name': '阿哲'})),
          isNull,
          reason: 'display_name ${jsonEncode(blank)}',
        );
      }
      // Provider names are never public.
      expect(
        profilePublicName(user({'full_name': '阿哲', 'name': '阿哲'})),
        isNull,
      );
      expect(profilePublicName(user({'display_name': 3})), isNull);
    });

    test('profileNameSuggestion', () {
      expect(profileNameSuggestion(null), isNull);
      expect(profileNameSuggestion(user({'full_name': ' 陳小明 '})), '陳小明');
      expect(profileNameSuggestion(user({'name': '小明'})), '小明');
      expect(
        profileNameSuggestion(user({'full_name': '　', 'name': '小明'})),
        '小明',
      );
      expect(profileNameSuggestion(user({})), isNull);
      // A saved name, or one the rider cleared (key present, blank), means
      // no suggestion.
      for (final saved in ['阿哲', '', '  ', '　']) {
        expect(
          profileNameSuggestion(
            user({'display_name': saved, 'full_name': '陳小明'}),
          ),
          isNull,
          reason: 'display_name ${jsonEncode(saved)}',
        );
      }
      // Apple names are never kept or suggested.
      expect(
        profileNameSuggestion(user({'full_name': '陳小明'}, provider: 'apple')),
        isNull,
      );
    });

    test('清空名稱時寫入空字串', () async {
      final fixture = ProfileFixture(metadata: {'display_name': '阿哲'});
      await fixture.open();
      addTearDown(fixture.close);
      await fixture.store.updateProfile(displayName: ' 　 ');
      expect(fixture.updates.single, {'display_name': ''});
    });
  });

  group('P12 三種名稱狀態（#319）', () {
    Future<ProfileFixture> p12(
      WidgetTester tester,
      TargetPlatform platform,
      Size size, {
      required Map<String, dynamic> metadata,
      String provider = 'google',
      bool settings = false,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = (await tester.runAsync(() async {
        final value = ProfileFixture(metadata: metadata, provider: provider);
        await value.open();
        return value;
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            // Match the app's bridge for CNBottomSheet's Material localizations.
            // ignore: deprecated_member_use
            child: MaterialUiCompatibilityBridge(child: child!),
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => settings
                    ? showSettings(context, fixture.store)
                    : showProfileEditor(context, fixture.store),
                child: const Text('開啟'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開啟'));
      await tester.pumpAndSettle();
      return fixture;
    }

    final nameField = find.byKey(const ValueKey('profile-name'));
    final save = find.byKey(const ValueKey('profile-save'));
    String field(WidgetTester tester) =>
        tester.widget<TextFormField>(nameField).controller!.text;
    bool canSave(WidgetTester tester) =>
        tester.widget<TextButton>(save).onPressed != null;
    String? state(WidgetTester tester) {
      final caption = find.byKey(const ValueKey('profile-name-state'));
      return caption.evaluate().isEmpty
          ? null
          : tester.widget<Text>(caption).data;
    }

    String? avatarName(WidgetTester tester) =>
        tester.widget<ProfileAvatar>(find.byType(ProfileAvatar)).name;
    Future<void> tapSave(WidgetTester tester) async {
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.runAsync(
        () async =>
            await Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      for (final size in const [
        Size(390, 844),
        Size(820, 1180),
        Size(1180, 820),
      ]) {
        final where =
            '${platform.name} ${size.width.toInt()}×${size.height.toInt()} 字級 2.0';
        testWidgets(
          '① 已設定：顯示名稱與一般說明，沒改不能儲存（$where）',
          variant: TargetPlatformVariant.only(platform),
          (tester) async {
            await p12(
              tester,
              platform,
              size,
              metadata: {'display_name': '阿哲', 'full_name': '陳小明'},
            );
            expect(field(tester), '阿哲');
            expect(state(tester), isNull);
            expect(find.text(profileNameHelper), findsOneWidget);
            expect(avatarName(tester), '阿哲');
            expect(canSave(tester), isFalse);
            expect(tester.takeException(), isNull);
          },
        );

        testWidgets(
          '② 從沒設定：預填 Google 姓名，直接儲存才公開（$where）',
          variant: TargetPlatformVariant.only(platform),
          (tester) async {
            final fixture = await p12(
              tester,
              platform,
              size,
              metadata: {'full_name': '陳小明'},
            );
            expect(field(tester), '陳小明');
            expect(state(tester), profileNameUnset);
            expect(find.text(profileNameSuggestionHelper), findsOneWidget);
            expect(avatarName(tester), '');
            expect(canSave(tester), isTrue);
            expect(tester.takeException(), isNull);
            await tapSave(tester);
            expect(nameField, findsNothing);
            expect(fixture.updates.single, {'display_name': '陳小明'});
          },
        );

        testWidgets(
          '③ 清空：可以儲存，寫入空字串（$where）',
          variant: TargetPlatformVariant.only(platform),
          (tester) async {
            final fixture = await p12(
              tester,
              platform,
              size,
              metadata: {'display_name': '阿哲', 'full_name': '陳小明'},
            );
            await tester.enterText(nameField, '');
            await tester.pumpAndSettle();
            expect(state(tester), profileNameClearing);
            expect(find.text(profileNameClearedHelper), findsOneWidget);
            expect(avatarName(tester), '');
            expect(canSave(tester), isTrue);
            expect(tester.takeException(), isNull);
            await tapSave(tester);
            expect(nameField, findsNothing);
            expect(fixture.updates.single, {'display_name': ''});
          },
        );
      }

      testWidgets(
        '② 取消不儲存，下次仍是建議值（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          final fixture = await p12(
            tester,
            platform,
            const Size(390, 844),
            metadata: {'full_name': '陳小明'},
          );
          await tester.tap(
            platform == TargetPlatform.iOS
                ? find.text('取消')
                : find.byTooltip('關閉'),
          );
          await tester.pumpAndSettle();
          expect(nameField, findsNothing);
          expect(fixture.updates, isEmpty);
          expect(fixture.metadata.containsKey('display_name'), isFalse);
        },
      );

      testWidgets(
        'Apple 帳號欄位空白，只顯示一般說明（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          await p12(
            tester,
            platform,
            const Size(390, 844),
            provider: 'apple',
            metadata: {'full_name': 'Apple 姓名'},
          );
          expect(field(tester), '');
          expect(state(tester), isNull);
          expect(find.text(profileNameHelper), findsOneWidget);
          expect(find.text(profileNameSuggestionHelper), findsNothing);
          expect(canSave(tester), isFalse);
        },
      );

      testWidgets(
        '清空存檔後重新打開，欄位仍空白、不再預填（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          final fixture = await p12(
            tester,
            platform,
            const Size(390, 844),
            metadata: {'display_name': '阿哲', 'full_name': '陳小明'},
          );
          await tester.enterText(nameField, '');
          await tester.pumpAndSettle();
          await tapSave(tester);
          expect(fixture.metadata['display_name'], '');
          await tester.tap(find.text('開啟'));
          await tester.pumpAndSettle();
          expect(field(tester), '');
          expect(state(tester), profileNameUnset);
          expect(find.text(profileNameClearedHelper), findsOneWidget);
          expect(find.text(profileNameSuggestionHelper), findsNothing);
          expect(avatarName(tester), '');
          expect(canSave(tester), isFalse);
        },
      );

      testWidgets(
        'P10 沒有公開名稱：尚未設定名稱與設定名稱連結（${platform.name}）',
        variant: TargetPlatformVariant.only(platform),
        (tester) async {
          await p12(
            tester,
            platform,
            const Size(390, 844),
            settings: true,
            metadata: {'full_name': '陳小明'},
          );
          expect(
            tester
                .widget<Text>(find.byKey(const ValueKey('account-title')))
                .data,
            settingsNameUnset,
          );
          expect(find.text('rider@example.com'), findsOneWidget);
          expect(find.textContaining('陳小明'), findsNothing);
          final link = find.byKey(const ValueKey('account-set-name'));
          expect(
            find.descendant(of: link, matching: find.text(settingsSetName)),
            findsOneWidget,
          );
          final target = platform == TargetPlatform.iOS ? 44.0 : 48.0;
          expect(tester.getSize(link).height, greaterThanOrEqualTo(target));
          expect(tester.getSize(link).width, greaterThanOrEqualTo(target));
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(link);
          await tester.tap(link);
          await tester.pumpAndSettle();
          expect(field(tester), '陳小明');
          expect(state(tester), profileNameUnset);
        },
      );
    }

    testWidgets(
      'P10 有公開名稱時不顯示設定名稱',
      variant: TargetPlatformVariant.only(TargetPlatform.android),
      (tester) async {
        await p12(
          tester,
          TargetPlatform.android,
          const Size(390, 844),
          settings: true,
          metadata: {'display_name': '阿哲'},
        );
        expect(
          tester.widget<Text>(find.byKey(const ValueKey('account-title'))).data,
          '阿哲',
        );
        expect(find.byKey(const ValueKey('account-set-name')), findsNothing);
      },
    );
  });
}

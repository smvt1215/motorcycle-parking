import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/profile_repository.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/auth/profile_editor.dart';
import 'package:motorcycle_parking/features/settings/settings_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

const userId = '10000000-0000-4000-8000-000000000001';
const oldPath = '$userId/10000000-0000-4000-8000-000000000002.png';
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class ProfileStore extends AppStore {
  ProfileStore(super.local, super.client);
  @override
  Future<void> loadFavorites() async {}
}

class ProfileFixture {
  ProfileFixture({Map<String, dynamic>? metadata})
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
  late final SupabaseClient client;
  late final ProfileStore store;
  final updates = <Map<String, dynamic>>[];
  final uploaded = <String>[];
  final deleted = <String>[];
  bool failUpdate = false, failUpload = false;

  Map<String, dynamic> get user => {
    'id': userId,
    'email': 'rider@example.com',
    'created_at': '2026-10-01T00:00:00Z',
    'app_metadata': {'provider': 'google'},
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
    } else if (request.url.path.startsWith(
      '/storage/v1/object/$profileAvatarBucket',
    )) {
      if (request.method == 'DELETE') {
        deleted.addAll(
          (jsonDecode(request.body)['prefixes'] as List).cast<String>(),
        );
        response = [];
      } else {
        if (failUpload) {
          return http.Response(
            '{"message":"upload refused","statusCode":"400"}',
            400,
          );
        }
        final path = request.url.path.split('/$profileAvatarBucket/').last;
        uploaded.add(path);
        response = {'Key': '$profileAvatarBucket/$path'};
      }
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
    expect(profileDisplayName(fixture.client.auth.currentUser), '自訂名稱');
    expect(profileAvatarUrl(fixture.client.auth.currentUser), isNull);
    expect(profileNameError('  '), isNotNull);
    expect(profileNameError('換\n行'), isNotNull);
    expect(profileNameError('名' * 41), isNotNull);
    // Mirrors #81 server cleanup: Cf (bidi/ZWJ/BOM) removed, spaces collapsed.
    expect(normalizeProfileName(' \u202e騎\u200b士  小\ufeff明 '), '騎士 小明');
    expect(profileNameError('\u200b\u2066'), isNotNull);
    expect(profileNameError('\u0085名稱'), isNotNull);
    expect(profileNameError('${'名' * 40}\u200d'), isNull);
    expect(avatarFormat(png).contentType, 'image/png');
    expect(() => avatarFormat(Uint8List(maxAvatarBytes + 1)), throwsStateError);
    expect(() => avatarFormat(Uint8List.fromList([1, 2, 3])), throwsStateError);
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
    expect(fixture.uploaded, isEmpty);
    expect(fixture.deleted, isEmpty);
  });

  test('先上傳新頭像，再儲存帳號，成功後才刪除自己舊頭像', () async {
    final fixture = ProfileFixture(
      metadata: {'full_name': '原始名稱', 'profile_avatar_path': oldPath},
    );
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.store.updateProfile(displayName: '新名稱', avatarBytes: png);
    final path = fixture.uploaded.single;
    expect(ownedAvatarPath(path, userId), isTrue);
    expect(path, isNot(oldPath));
    expect(fixture.updates.single['profile_avatar_path'], path);
    expect(
      fixture.updates.single['profile_avatar_url'],
      'https://example.supabase.co/storage/v1/object/public/$profileAvatarBucket/$path',
    );
    expect(fixture.deleted, [oldPath]);
    expect(profileDisplayName(fixture.client.auth.currentUser), '新名稱');
  });

  test('帳號儲存失敗會清掉本次新照片，保留原名稱與舊照片', () async {
    final fixture = ProfileFixture(
      metadata: {'full_name': '原始名稱', 'profile_avatar_path': oldPath},
    )..failUpdate = true;
    await fixture.open();
    addTearDown(fixture.close);
    await expectLater(
      fixture.store.updateProfile(displayName: '新名稱', avatarBytes: png),
      throwsA(isA<AuthException>()),
    );
    expect(fixture.deleted, [fixture.uploaded.single]);
    expect(fixture.deleted, isNot(contains(oldPath)));
    expect(profileDisplayName(fixture.client.auth.currentUser), '原始名稱');
  });

  test('圖片上傳失敗不更新帳號，不刪其他帳號的 metadata 路徑', () async {
    final fixture = ProfileFixture(
      metadata: {
        'full_name': '原始名稱',
        'profile_avatar_path': 'other-user/object.png',
      },
    )..failUpload = true;
    await fixture.open();
    addTearDown(fixture.close);
    await expectLater(
      fixture.store.updateProfile(displayName: '新名稱', avatarBytes: png),
      throwsA(isA<StorageException>()),
    );
    expect(fixture.updates, isEmpty);
    expect(
      fixture.deleted.every((path) => path.startsWith('$userId/')),
      isTrue,
    );
    fixture.failUpload = false;
    await fixture.store.updateProfile(displayName: '新名稱', removeAvatar: true);
    expect(fixture.metadata['profile_avatar_url'], '');
    expect(fixture.deleted, isNot(contains('other-user/object.png')));
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

  testWidgets('從相簿選擇停用並說明，沒有頭像時不顯示移除；儲存失敗保留名稱並可重試', (tester) async {
    final fixture = await host(tester, 390);
    final pick = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '從相簿選擇'),
    );
    expect(pick.onPressed, isNull);
    expect(find.text('照片上傳開放後才能用（社群核實 P2）。現在使用預設頭像。'), findsOneWidget);
    expect(find.text('移除頭像'), findsNothing);
    final save = find.byKey(const ValueKey('profile-save'));
    expect(tester.widget<TextButton>(save).onPressed, isNull);
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
    expect(fixture.uploaded, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('移除頭像仍可用：移除後回到預設頭像並沿用原本的移除流程', (tester) async {
    final fixture = await host(
      tester,
      390,
      metadata: {
        'full_name': '原始名稱',
        'profile_avatar_path': oldPath,
        'profile_avatar_url': 'https://example.test/original.png',
      },
    );
    final save = find.byKey(const ValueKey('profile-save'));
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    await tester.tap(find.text('移除頭像'));
    await tester.pump();
    expect(find.text('移除頭像'), findsNothing);
    expect(tester.widget<TextButton>(save).onPressed, isNotNull);
    await tester.tap(save);
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('profile-name')), findsNothing);
    expect(fixture.metadata['profile_avatar_url'], '');
    expect(fixture.deleted, contains(oldPath));
    expect(fixture.uploaded, isEmpty);
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
}

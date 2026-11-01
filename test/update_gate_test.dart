import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/core/update_gate.dart';
import 'package:motorcycle_parking/domain/update_display.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// P14 需要更新: the version check and where the update button goes.
void main() {
  group('版本以數值逐段比較', () {
    test('1.10.0 高於 1.9.0，不用字串比較', () {
      expect(isBelowMinimum('1.9.0', '1.10.0'), isTrue);
      expect(isBelowMinimum('1.10.0', '1.9.0'), isFalse);
      expect(isBelowMinimum('0.9.9', '1.0.0'), isTrue);
      expect(isBelowMinimum('2.0.0', '1.99.99'), isFalse);
      expect(isBelowMinimum('1.2.3', '1.2.10'), isTrue);
    });

    test('相同版本不擋', () {
      expect(isBelowMinimum('1.10.0', '1.10.0'), isFalse);
      expect(isBelowMinimum(' 0.1.0 ', '0.1.0'), isFalse);
    });

    test('格式不是 x.y.z 時不擋', () {
      for (final bad in [
        '',
        '1.10',
        '1.10.0.1',
        '1.10.0-beta.1',
        'v1.10.0',
        '1.x.0',
        '１.10.0',
      ]) {
        expect(isBelowMinimum('0.1.0', bad), isFalse, reason: bad);
        expect(isBelowMinimum(bad, '9.9.9'), isFalse, reason: bad);
      }
      expect(parseAppVersion('1.10.0'), [1, 10, 0]);
      expect(parseAppVersion('1.10'), isNull);
    });
  });

  group('寧可不擋', () {
    const installed = (version: '1.9.0', packageName: 'tw.example');
    UpdateGate gate(Future<String> Function() minimum) =>
        UpdateGate(minimum: minimum, installed: () async => installed);

    test('低於最低支援版本時擋下', () async {
      final updates = gate(() async => '1.10.0');
      await updates.check();
      expect(
        updates.required,
        const UpdateRequirement(
          installed: '1.9.0',
          minimum: '1.10.0',
          packageName: 'tw.example',
        ),
      );
    });

    test('離線、拋例外、TypeError、格式錯誤都照常進入', () async {
      for (final minimum in <Future<String> Function()>[
        () async => throw const SocketException('offline'),
        () async => throw Exception('backend'),
        () async =>
            (<String, Object?>{})['min_supported_app_version'] as String,
        () async => '1.10',
        () async => '0.1.0',
      ]) {
        final updates = gate(minimum);
        await updates.check();
        expect(updates.required, isNull);
      }
    });

    test('讀不到安裝版本時也不擋', () async {
      final updates = UpdateGate(
        minimum: () async => '9.0.0',
        installed: () async => throw StateError('no platform'),
      );
      await updates.check();
      expect(updates.required, isNull);
    });

    test('示範模式（沒有 client）不檢查', () async {
      final updates = UpdateGate.forClient(null);
      await updates.check();
      expect(updates.required, isNull);
      expect(updates.minimum, isNull);
    });

    test('擋下後重新檢查失敗，維持擋下；版本仍舊就繼續擋', () async {
      var answer = '1.10.0';
      var fail = false;
      final updates = gate(() async {
        if (fail) throw const SocketException('offline');
        return answer;
      });
      var notified = 0;
      updates.addListener(() => notified++);
      await updates.check();
      expect(updates.required, isNotNull);
      fail = true;
      await updates.check();
      expect(updates.required, isNotNull);
      fail = false;
      await updates.check();
      expect(updates.required, isNotNull);
      expect(notified, 1);
      answer = '1.9.0';
      await updates.check();
      expect(updates.required, isNull);
      expect(notified, 2);
    });

    test('經 api_v1.client_config 讀取；舊後端缺欄位不擋', () async {
      UpdateGate served(Object body, {int status = 200}) {
        final client = SupabaseClient(
          'https://example.supabase.co',
          'anon',
          httpClient: MockClient(
            (request) async => http.Response(
              jsonEncode(body),
              status,
              headers: {'content-type': 'application/json'},
              request: request,
            ),
          ),
        );
        final updates = UpdateGate.forClient(client);
        return UpdateGate(
          minimum: updates.minimum!,
          installed: () async => installed,
        );
      }

      const config = {
        'rules_version': 1,
        'spots_version': 1,
        'availability_beta_cities': <String>[],
      };
      final blocked = served({...config, 'min_supported_app_version': '2.0.0'});
      await blocked.check();
      expect(blocked.required?.minimum, '2.0.0');

      for (final updates in [
        served(config),
        served({...config, 'min_supported_app_version': 2}),
        served([]),
        served({'message': 'down'}, status: 503),
      ]) {
        await updates.check();
        expect(updates.required, isNull);
      }
    });
  });

  group('更新按鈕依建置來源', () {
    test('APP_CHANNEL 與 flavor 對應', () {
      expect(updateChannelOf(''), UpdateChannel.store);
      expect(updateChannelOf('release'), UpdateChannel.store);
      // The RC binary is the one the stores ship.
      expect(updateChannelOf('rc'), UpdateChannel.store);
      expect(updateChannelOf('beta'), UpdateChannel.beta);
      expect(updateChannelOf('staging'), UpdateChannel.staging);
      expect(updateChannelOf('', flavor: 'staging'), UpdateChannel.staging);
      expect(updateChannelOf('beta', flavor: 'staging'), UpdateChannel.staging);
    });

    Uri? link(
      UpdateChannel channel, {
      required bool ios,
      String appStoreId = '',
      String testflightUrl = '',
    }) => updateLink(
      channel: channel,
      ios: ios,
      packageName: 'tw.motopark.motorcycle_parking',
      appStoreId: appStoreId,
      testflightUrl: testflightUrl,
    );

    test('production：App Store 與 Google Play', () {
      expect(
        link(UpdateChannel.store, ios: false).toString(),
        'https://play.google.com/store/apps/details?id=tw.motopark.motorcycle_parking',
      );
      expect(
        link(UpdateChannel.store, ios: true, appStoreId: '6700000000'),
        Uri.parse('https://apps.apple.com/app/id6700000000'),
      );
      // No App Store ID yet (#262): words instead of a made-up link.
      expect(link(UpdateChannel.store, ios: true), isNull);
      expect(link(UpdateChannel.store, ios: true, appStoreId: 'abc'), isNull);
      expect(updateOffer(UpdateChannel.store, ios: true, hasLink: true), (
        button: '前往 App Store',
        fallback: null,
        note: null,
      ));
      expect(updateOffer(UpdateChannel.store, ios: true, hasLink: false), (
        button: null,
        fallback: '請到 App Store 更新',
        note: null,
      ));
      expect(updateOffer(UpdateChannel.store, ios: false, hasLink: true), (
        button: '前往 Google Play',
        fallback: null,
        note: null,
      ));
    });

    test('Beta：iOS 開 TestFlight 公開連結，Android 開 Google Play', () {
      const testflight = 'https://testflight.apple.com/join/AbCdEf12';
      expect(
        link(UpdateChannel.beta, ios: true, testflightUrl: testflight),
        Uri.parse(testflight),
      );
      expect(link(UpdateChannel.beta, ios: true), isNull);
      expect(
        link(UpdateChannel.beta, ios: true, testflightUrl: 'itms-beta://x'),
        isNull,
      );
      expect(
        link(UpdateChannel.beta, ios: false),
        link(UpdateChannel.store, ios: false),
      );
      expect(updateOffer(UpdateChannel.beta, ios: true, hasLink: true), (
        button: '前往 TestFlight',
        fallback: null,
        note: '這是測試版，透過 TestFlight 安裝',
      ));
      expect(updateOffer(UpdateChannel.beta, ios: true, hasLink: false), (
        button: null,
        fallback: '請打開 TestFlight 更新',
        note: '這是測試版，透過 TestFlight 安裝',
      ));
      expect(updateOffer(UpdateChannel.beta, ios: false, hasLink: true), (
        button: '前往 Google Play',
        fallback: null,
        note: '這是測試版，透過 Play 內部測試安裝',
      ));
    });

    test('staging：Firebase App Tester', () {
      for (final ios in [true, false]) {
        expect(
          link(UpdateChannel.staging, ios: ios),
          Uri.parse('https://appdistribution.firebase.google.com'),
        );
        expect(updateOffer(UpdateChannel.staging, ios: ios, hasLink: true), (
          button: '前往 App Tester',
          fallback: null,
          note: '測試版透過 Firebase App Tester 安裝',
        ));
      }
    });
  });
}

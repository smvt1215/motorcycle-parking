import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/app.dart';
import 'package:motorcycle_parking/core/update_gate.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/features/update/update_required_page.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'app_test.dart' show testStore;

const _requirement = UpdateRequirement(
  installed: '1.9.0',
  minimum: '1.10.0',
  packageName: 'tw.motopark.motorcycle_parking',
);
const _testflight = 'https://testflight.apple.com/join/AbCdEf12';
final _play = Uri.parse(
  'https://play.google.com/store/apps/details?id=tw.motopark.motorcycle_parking',
);

void main() {
  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    final ios = platform == TargetPlatform.iOS;
    for (final size in const [
      Size(390, 844),
      Size(820, 1180),
      Size(1180, 820),
    ]) {
      final name =
          '${platform.name} ${size.width.toInt()}×${size.height.toInt()}';

      void setUp(WidgetTester tester) {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
      }

      for (final (channel, button, note, url) in [
        (
          UpdateChannel.store,
          ios ? '前往 App Store' : '前往 Google Play',
          null,
          ios ? Uri.parse('https://apps.apple.com/app/id6700000000') : _play,
        ),
        (
          UpdateChannel.beta,
          ios ? '前往 TestFlight' : '前往 Google Play',
          ios ? '這是測試版，透過 TestFlight 安裝' : '這是測試版，透過 Play 內部測試安裝',
          ios ? Uri.parse(_testflight) : _play,
        ),
        (
          UpdateChannel.staging,
          '前往 App Tester',
          '測試版透過 Firebase App Tester 安裝',
          Uri.parse('https://appdistribution.firebase.google.com'),
        ),
      ]) {
        testWidgets('$name ${channel.name}：按鈕文字與連結', (tester) async {
          setUp(tester);
          final opened = <Uri>[];
          await tester.pumpWidget(
            MaterialApp(
              home: UpdateRequiredPage(
                requirement: _requirement,
                channel: channel,
                appStoreId: '6700000000',
                testflightUrl: _testflight,
                launch: (uri) async {
                  opened.add(uri);
                  return true;
                },
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('需要更新'), findsOneWidget);
          expect(find.text('這個版本已不支援，更新後才能繼續使用。'), findsOneWidget);
          expect(find.text('目前版本 1.9.0・最低支援版本 1.10.0'), findsOneWidget);
          // No way back or out.
          expect(find.byType(BackButton), findsNothing);
          expect(find.byType(CloseButton), findsNothing);

          final target = find.byKey(const ValueKey('update-button'));
          expect(
            find.descendant(of: target, matching: find.text(button)),
            findsOneWidget,
          );
          final rect = tester.getRect(target);
          expect(rect.height, greaterThanOrEqualTo(ios ? 44 : 48));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(size.width));
          // A phone column on a tablet.
          expect(rect.width, lessThanOrEqualTo(480));
          if (note == null) {
            expect(find.textContaining('測試版'), findsNothing);
          } else {
            expect(find.text(note), findsOneWidget);
          }
          await tester.tap(target);
          await tester.pump();
          expect(opened, [url]);
          debugDefaultTargetPlatformOverride = null;
        });
      }

      testWidgets('$name 沒有 TestFlight 連結或 App Store ID 時改顯示文字', (
        tester,
      ) async {
        setUp(tester);
        for (final channel in [UpdateChannel.beta, UpdateChannel.store]) {
          await tester.pumpWidget(
            MaterialApp(
              home: UpdateRequiredPage(
                key: ValueKey(channel),
                requirement: _requirement,
                channel: channel,
                appStoreId: '',
                testflightUrl: '',
                launch: (_) async => fail('nothing to open'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final fallback = find.byKey(const ValueKey('update-fallback'));
          if (ios) {
            expect(find.byKey(const ValueKey('update-button')), findsNothing);
            expect(
              tester.widget<Text>(fallback).data,
              channel == UpdateChannel.beta
                  ? '請打開 TestFlight 更新'
                  : '請到 App Store 更新',
            );
            expect(
              tester.getRect(fallback).bottom,
              lessThanOrEqualTo(size.height),
            );
          } else {
            // Google Play needs neither.
            expect(fallback, findsNothing);
            expect(find.text('前往 Google Play'), findsOneWidget);
          }
        }
        debugDefaultTargetPlatformOverride = null;
      });

      testWidgets('$name 擋下時整個 App 只顯示 P14，返回鍵與返回手勢不會離開', (tester) async {
        setUp(tester);
        var minimum = '1.10.0';
        var checks = 0;
        final gate = UpdateGate(
          minimum: () async {
            checks++;
            return minimum;
          },
          installed: () async =>
              (version: '1.9.0', packageName: 'tw.motopark.motorcycle_parking'),
        );
        addTearDown(gate.dispose);
        final exits = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'SystemNavigator.pop') exits.add(call);
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        final store = (await tester.runAsync(testStore))!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [storeProvider.overrideWith((ref) => store)],
            child: ParkingApp(updateGate: gate),
          ),
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        final page = find.byKey(const ValueKey('update-required'));
        expect(page, findsOneWidget);
        expect(find.byType(AdaptiveScaffold), findsNothing);
        expect(checks, 1);

        // Android back button and predictive back gesture.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(page, findsOneWidget);
        expect(exits, isEmpty);

        // Back from the store, still too old: still blocked.
        Future<void> resume() async {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pumpAndSettle();
        }

        await resume();
        expect(checks, 2);
        expect(page, findsOneWidget);

        // The backend lowers the minimum: the app comes back.
        minimum = '1.9.0';
        await resume();
        expect(checks, 3);
        expect(page, findsNothing);
        expect(find.byType(AdaptiveScaffold), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}

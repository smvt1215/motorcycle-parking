import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/core/navigation.dart';
import 'package:motorcycle_parking/data/app_store.dart' show navigateTo;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const lat = 25.083217, lng = 121.557515;
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  void responses(Future<bool> Function(Uri) launch) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      expect(call.method, 'launch');
      final args = call.arguments as Map;
      expect(args['useSafariVC'], isFalse);
      expect(args['useWebView'], isFalse);
      return launch(Uri.parse(args['url'] as String));
    });
  }

  List<Uri> getTargets() => calls
      .map((call) => Uri.parse((call.arguments as Map)['url'] as String))
      .toList();

  test('iOS 已安裝 Google Maps 時只開 Google App，保留座標與開車模式', () async {
    responses((_) async => true);
    await navigateTo(lat, lng);
    final target = getTargets().single;
    expect(target.scheme, 'comgooglemaps');
    expect(target.queryParameters['daddr'], '$lat,$lng');
    expect(target.queryParameters['directionsmode'], 'driving');
  });

  test('iOS Google App 無法開啟時回退 Apple Maps', () async {
    responses((uri) async => uri.host == 'maps.apple.com');
    await navigateTo(lat, lng);
    final targets = getTargets();
    expect(targets, hasLength(2));
    expect(targets.first.scheme, 'comgooglemaps');
    expect(targets.last.host, 'maps.apple.com');
    expect(targets.last.queryParameters['daddr'], '$lat,$lng');
    expect(targets.last.queryParameters['dirflg'], 'd');
  });

  test('Google App 的平台錯誤仍會回退 Apple Maps', () async {
    responses((uri) async {
      if (uri.scheme == 'comgooglemaps') {
        throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
      }
      return true;
    });
    await navigateTo(lat, lng);
    expect(getTargets().last.host, 'maps.apple.com');
  });

  test('所有導航目標都失敗時才回報無法開啟', () async {
    responses((_) async => false);
    await expectLater(navigateTo(lat, lng), throwsStateError);
    expect(getTargets(), hasLength(2));
  });

  test('Android 維持 Google 導航網址', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    responses((_) async => true);
    await navigateTo(lat, lng);
    final target = getTargets().single;
    expect(target.host, 'www.google.com');
    expect(target.path, '/maps/dir/');
    expect(target.queryParameters['destination'], '$lat,$lng');
  });

  test('Web 即使是 iOS 平台也使用可開啟的 Google 網址', () {
    final target = navigationTargets(
      lat,
      lng,
      platform: TargetPlatform.iOS,
      web: true,
    ).single;
    expect(target.scheme, 'https');
    expect(target.host, 'www.google.com');
    expect(target.queryParameters['travelmode'], 'driving');
  });
}

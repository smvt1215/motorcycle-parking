import 'package:flutter/foundation.dart';

class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const redirectUrl = String.fromEnvironment(
    'OAUTH_REDIRECT_URL',
    defaultValue: 'tw.motopark.motorcycleparking://login-callback',
  );
  static const offlineMap = bool.fromEnvironment('OFFLINE_MAP');

  /// How the build is distributed: the release workflow's RELEASE_CHANNEL
  /// (beta, rc, release) or `staging`; empty in a local build (P14).
  static const appChannel = String.fromEnvironment('APP_CHANNEL');

  /// The App Store's numeric Apple ID; empty until the app exists (#262).
  static const appStoreId = String.fromEnvironment('APP_STORE_ID');

  /// The TestFlight public link of the beta group; empty when not set.
  static const testflightPublicUrl = String.fromEnvironment(
    'TESTFLIGHT_PUBLIC_URL',
  );
  static const googleMapsWebKey = String.fromEnvironment(
    'GOOGLE_MAPS_WEB_API_KEY',
  );
  static const googleMapsAndroidEnabled = bool.fromEnvironment(
    'GOOGLE_MAPS_ANDROID_ENABLED',
  );
  static const googleMapsIosEnabled = bool.fromEnvironment(
    'GOOGLE_MAPS_IOS_ENABLED',
  );
  static bool get useGoogleMaps =>
      !offlineMap &&
      (kIsWeb
          ? googleMapsWebKey.isNotEmpty
          : switch (defaultTargetPlatform) {
              TargetPlatform.android => googleMapsAndroidEnabled,
              TargetPlatform.iOS => googleMapsIosEnabled,
              _ => false,
            });

  /// OpenStreetMap tiles load only for the no-key preview, never offline;
  /// its credit must not appear over Google Maps or an empty test map.
  static bool get showsOsmTiles => !useGoogleMaps && !offlineMap;
  static bool get demo => supabaseUrl.isEmpty && supabaseKey.isEmpty;
  static void validate() {
    if (supabaseUrl.isEmpty != supabaseKey.isEmpty) {
      throw StateError('SUPABASE_URL 與 SUPABASE_ANON_KEY 必須同時設定');
    }
  }
}

import 'package:flutter/foundation.dart';

class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_ANON_KEY');
  static const redirectUrl = String.fromEnvironment(
    'OAUTH_REDIRECT_URL',
    defaultValue: 'tw.motopark.motorcycleparking://login-callback',
  );
  static const offlineMap = bool.fromEnvironment('OFFLINE_MAP');
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
  static bool get demo => supabaseUrl.isEmpty && supabaseKey.isEmpty;
  static void validate() {
    if (supabaseUrl.isEmpty != supabaseKey.isEmpty) {
      throw StateError('SUPABASE_URL 與 SUPABASE_ANON_KEY 必須同時設定');
    }
  }
}

import 'dart:async';

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// The header the write endpoints read the App Check token from (#203,
/// `supabase/functions/_shared/app_check.ts`); never put the token in a URL.
const appCheckHeader = 'X-Firebase-AppCheck';

/// Where a token comes from; [AppCheck.token] by default, a stub in tests.
typedef AppCheckTokenSource = Future<String?> Function();

/// The FirebaseOptions App Check needs, from `--dart-define` (#203).
///
/// CD writes them per platform into `config/<environment>.json`
/// (`tool/cd_config.py`); no google-services.json or GoogleService-Info.plist
/// is used. Local runs, PR CI, web and the admin build have none of them, so
/// Firebase is never initialised there.
@visibleForTesting
FirebaseOptions? appCheckOptions({
  String apiKey = const String.fromEnvironment('FIREBASE_API_KEY'),
  String appId = const String.fromEnvironment('FIREBASE_APP_ID'),
  String messagingSenderId = const String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  ),
  String projectId = const String.fromEnvironment('FIREBASE_PROJECT_ID'),
  bool web = kIsWeb,
  TargetPlatform? platform,
}) {
  if (web) return null;
  final target = platform ?? defaultTargetPlatform;
  if (target != TargetPlatform.android && target != TargetPlatform.iOS) {
    return null;
  }
  if ([apiKey, appId, messagingSenderId, projectId].any((v) => v.isEmpty)) {
    return null;
  }
  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
  );
}

/// A token from [source], or null when there is none, it fails, or it takes
/// longer than [timeout]: App Check never holds up or blocks a submission.
Future<String?> fetchAppCheckToken(
  AppCheckTokenSource? source, {
  Duration timeout = AppCheck.timeout,
}) async {
  if (source == null) return null;
  try {
    final token = await source().timeout(timeout);
    return token == null || token.isEmpty ? null : token;
  } catch (_) {
    return null;
  }
}

/// The App Check client (#203).
///
/// [start] runs once from `main`; it never blocks launch and never throws.
/// Debug builds use the debug providers (the SDK prints a debug token to the
/// device log on first use; register it in the Firebase console, see
/// docs/CICD.md). Release and profile builds use Play Integrity on Android
/// and App Attest on iOS, falling back to DeviceCheck where App Attest is
/// unavailable.
///
/// Calling an endpoint that verifies App Check:
///
/// ```dart
/// final res = await client.functions.invoke(
///   'submit-sighting',
///   body: body,
///   headers: await AppCheck.headers(),
/// );
/// ```
///
/// [headers] is null without a token, so the request goes out unchanged; the
/// backend decides from APP_CHECK_MODE whether that is only logged.
class AppCheck {
  AppCheck._();

  /// How long a submission waits for a token before going without one.
  static const timeout = Duration(seconds: 3);

  /// Set once [start] has activated App Check; null while it is off.
  static Future<AppCheckTokenSource?>? _ready;

  /// Initialises Firebase and activates App Check when [options] are given
  /// (by default from `--dart-define`); otherwise App Check stays off.
  static Future<void> start({FirebaseOptions? options}) {
    final resolved = options ?? appCheckOptions();
    if (resolved == null) {
      _ready = null;
      return Future.value();
    }
    final ready = _activate(resolved);
    _ready = ready;
    return ready.then((_) {});
  }

  static Future<AppCheckTokenSource?> _activate(FirebaseOptions options) async {
    try {
      await Firebase.initializeApp(options: options);
      const debugToken = String.fromEnvironment('APP_CHECK_DEBUG_TOKEN');
      await FirebaseAppCheck.instance.activate(
        providerAndroid: kDebugMode
            ? AndroidDebugProvider(
                debugToken: debugToken.isEmpty ? null : debugToken,
              )
            : const AndroidPlayIntegrityProvider(),
        providerApple: kDebugMode
            ? AppleDebugProvider(
                debugToken: debugToken.isEmpty ? null : debugToken,
              )
            : const AppleAppAttestWithDeviceCheckFallbackProvider(),
      );
      return FirebaseAppCheck.instance.getToken;
    } catch (error) {
      debugPrint('App Check unavailable: $error');
      return null;
    }
  }

  /// Replaces the token source (tests); null turns App Check off.
  @visibleForTesting
  static set debugSource(AppCheckTokenSource? source) =>
      _ready = source == null ? null : Future.value(source);

  /// The current token, or null (off, failed or over [timeout]).
  static Future<String?> token() {
    final ready = _ready;
    if (ready == null) return Future.value();
    return fetchAppCheckToken(() async {
      final source = await ready;
      return source == null ? null : source();
    });
  }

  /// The [appCheckHeader] for a request, or null without a token.
  static Future<Map<String, String>?> headers([
    AppCheckTokenSource source = token,
  ]) async {
    final value = await fetchAppCheckToken(source);
    return value == null ? null : {appCheckHeader: value};
  }
}

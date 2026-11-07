import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config.dart';

/// Apple's authorization code works once, for about this long.
const appleCodeLifetime = Duration(minutes: 5);

/// How a sign-in reaches the rider.
enum SignInRoute { nativeApple, nativeGoogle, browser }

/// iOS signs in natively with both providers and Android with Google; Apple
/// has no native sign-in on Android, and the web has none here (#352).
SignInRoute signInRoute(OAuthProvider provider) {
  if (kIsWeb) return SignInRoute.browser;
  return switch ((defaultTargetPlatform, provider)) {
    (TargetPlatform.iOS, OAuthProvider.apple) => SignInRoute.nativeApple,
    (TargetPlatform.iOS || TargetPlatform.android, OAuthProvider.google) =>
      SignInRoute.nativeGoogle,
    _ => SignInRoute.browser,
  };
}

/// The rider closed the native sign-in panel: not an error.
class SignInCancelled implements Exception {
  const SignInCancelled();
}

/// The nonce a provider puts in its ID token. Supabase Auth hashes the raw
/// nonce the same way and compares.
String hashNonce(String rawNonce) =>
    sha256.convert(utf8.encode(rawNonce)).toString();

/// What a native panel hands back.
@immutable
class NativeCredential {
  const NativeCredential({required this.idToken, this.authorizationCode});
  final String idToken;

  /// Apple's one-time code, for `apple-revoke`.
  final String? authorizationCode;
}

/// The native panels; [PluginNativeIdentity] in the app, a fake in tests.
/// Both throw [SignInCancelled] when the rider closes the panel.
abstract interface class NativeIdentity {
  Future<NativeCredential> apple(String hashedNonce);
  Future<NativeCredential> google(String hashedNonce);
}

/// [NativeIdentity] over `sign_in_with_apple` and `google_sign_in`.
class PluginNativeIdentity implements NativeIdentity {
  Future<void>? _googleReady;

  @override
  Future<NativeCredential> apple(String hashedNonce) async {
    final AuthorizationCredentialAppleID credential;
    try {
      credential = await SignInWithApple.getAppleIDCredential(
        scopes: const [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code == AuthorizationErrorCode.canceled) {
        throw const SignInCancelled();
      }
      rethrow;
    }
    final idToken = credential.identityToken;
    if (idToken == null) throw const AuthException('Apple 沒有回傳 ID token');
    // Apple's name is dropped here: names are never saved for the rider
    // (#319), and a non-empty display_name counts as choosing to publish.
    return NativeCredential(
      idToken: idToken,
      authorizationCode: credential.authorizationCode,
    );
  }

  @override
  Future<NativeCredential> google(String hashedNonce) async {
    final signIn = GoogleSignIn.instance;
    try {
      await (_googleReady ??= signIn.initialize(
        serverClientId: AppConfig.googleServerClientId,
        nonce: hashedNonce,
      ));
    } catch (_) {
      _googleReady = null;
      rethrow;
    }
    try {
      final account = await signIn.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) throw const AuthException('Google 沒有回傳 ID token');
      return NativeCredential(idToken: idToken);
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw const SignInCancelled();
      }
      rethrow;
    } finally {
      // The Supabase session is the sign-in: leave no Google one on the phone.
      try {
        await signIn.signOut();
      } catch (_) {
        // Nothing to clear, or it stays until the next sign-in.
      }
    }
  }
}

/// Signs in on the route [signInRoute] picks, for the sign-in buttons and for
/// the re-sign-in before deleting an account, and keeps the Apple code that
/// sign-in brought until `apple-revoke` uses it.
class AuthFlow {
  AuthFlow(this.client, {NativeIdentity? identity, DateTime Function()? clock})
    : identity = identity ?? PluginNativeIdentity(),
      clock = clock ?? DateTime.now;
  final SupabaseClient client;
  final NativeIdentity identity;
  final DateTime Function() clock;

  /// `GoogleSignIn.initialize`, the only way to give it a nonce, may run only
  /// once: every Google sign-in of this launch shares one.
  String? _googleNonce;

  String? _appleCode;
  DateTime? _appleCodeAt;

  /// The latest native Apple sign-in's code, while it can still work.
  String? get appleCode {
    final at = _appleCodeAt;
    if (at == null || clock().difference(at) >= appleCodeLifetime) return null;
    return _appleCode;
  }

  void clearAppleCode() {
    _appleCode = null;
    _appleCodeAt = null;
  }

  /// Signs in; throws [SignInCancelled] when the rider closes a native panel.
  /// On the browser route this returns once the page has opened, and the
  /// session arrives later through the deep link.
  Future<void> signIn(OAuthProvider provider) async {
    switch (signInRoute(provider)) {
      case SignInRoute.browser:
        await openBrowser(provider);
      case SignInRoute.nativeApple:
        await _signInApple();
      case SignInRoute.nativeGoogle:
        await _signInGoogle();
    }
  }

  /// Opens the provider's page; false when it did not open.
  Future<bool> openBrowser(OAuthProvider provider) {
    clearAppleCode();
    return client.auth.signInWithOAuth(
      provider,
      redirectTo: kIsWeb
          ? Uri.base.replace(fragment: '', query: '').toString()
          : AppConfig.redirectUrl,
      // An in-app Safari view can remain blank above the app after callback.
      authScreenLaunchMode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
    );
  }

  Future<void> _signInApple() async {
    clearAppleCode();
    final rawNonce = client.auth.generateRawNonce();
    final credential = await identity.apple(hashNonce(rawNonce));
    await client.auth.signInWithIdToken(
      provider: OAuthProvider.apple,
      idToken: credential.idToken,
      nonce: rawNonce,
    );
    _appleCode = credential.authorizationCode;
    _appleCodeAt = clock();
  }

  Future<void> _signInGoogle() async {
    clearAppleCode();
    final rawNonce = _googleNonce ??= client.auth.generateRawNonce();
    final credential = await identity.google(hashNonce(rawNonce));
    await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: credential.idToken,
      nonce: rawNonce,
    );
  }
}

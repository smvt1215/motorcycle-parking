import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart';
import '../core/app_check.dart';
import '../core/config.dart';
import 'app_store.dart';

export '../api/v1/api_v1.g.dart' show AccountDeletionState;

/// The backend wants a sign-in within 10 minutes (`max_age_seconds` 600); the
/// App asks again after 9, leaving a minute for the confirmation and request.
const recentSignInLimit = Duration(minutes: 9);

/// The latest authentication time in a Supabase access token's `amr` claim,
/// as the backend reads it (anonymous entries do not count); null when the
/// token has none or is not a JWT.
DateTime? signedInAtFromJwt(String? accessToken) {
  final parts = accessToken?.split('.');
  if (parts == null || parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final amr = payload is Map ? payload['amr'] : null;
    if (amr is! List) return null;
    num latest = 0;
    for (final entry in amr) {
      if (entry is! Map || entry['method'] == 'anonymous') continue;
      final timestamp = entry['timestamp'];
      if (timestamp is num && timestamp > latest) latest = timestamp;
    }
    if (latest == 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      (latest * 1000).round(),
      isUtc: true,
    );
  } catch (_) {
    return null;
  }
}

/// Whether a session signed in at [signedInAt] must sign in again before
/// requesting deletion; an unknown time always must.
bool needsRecentSignIn(DateTime? signedInAt, DateTime now) =>
    signedInAt == null || now.difference(signedInAt) > recentSignInLimit;

/// Whether a pending request was made after this session signed in: a
/// sign-in during the cooling-off period, which may cancel it (P15b ②).
/// Unknown times count as new, so the rider still chooses explicitly.
bool signedInAfterRequest(DateTime? signedInAt, String? requestedAt) {
  final requested = requestedAt == null ? null : DateTime.tryParse(requestedAt);
  if (signedInAt == null || requested == null) return true;
  return signedInAt.isAfter(requested);
}

/// The signed-in rider as the deletion flow needs them.
@immutable
class AccountIdentity {
  const AccountIdentity({
    required this.id,
    this.email,
    this.name,
    this.apple = false,
    this.signedInAt,
    this.appleToken,
    this.appleTokenHint,
  });
  final String id;
  final String? email;
  final String? name;

  /// Signed in with Apple: its grant is revoked before the request (#268).
  final bool apple;

  /// The latest sign-in, from the access token's `amr`.
  final DateTime? signedInAt;

  /// The provider token Apple revokes, from this session's OAuth sign-in,
  /// with its `token_type_hint`; a restored session may have none.
  final String? appleToken;
  final String? appleTokenHint;
}

/// Why a deletion step stopped (P15c).
sealed class DeletionFailure implements Exception {
  const DeletionFailure();
}

/// The session is older than [recentSignInLimit], or the backend said so.
class ReauthRequired extends DeletionFailure {
  const ReauthRequired();
}

/// The rider closed the Google or Apple page, or it failed (P15c ③).
class ReauthIncomplete extends DeletionFailure {
  const ReauthIncomplete();
}

/// Another account signed in (P15c ④); the original session was restored.
class WrongAccount extends DeletionFailure {
  const WrongAccount(this.email);
  final String? email;
}

/// 403 `account.admin_cannot_self_delete` (P15c ①).
class AdminCannotDelete extends DeletionFailure {
  const AdminCannotDelete();
}

/// 401 `auth.sign_in_required`: the session is gone; sign in (P11).
class SignInRequired extends DeletionFailure {
  const SignInRequired();
}

/// 409 `account.deletion_in_progress` on cancel (P15b ⑤).
class DeletionInProgress extends DeletionFailure {
  const DeletionInProgress();
}

/// Offline or timed out; the request may or may not have arrived, and
/// repeating it is safe (P15c ②).
class DeletionNetworkError extends DeletionFailure {
  const DeletionNetworkError();
}

/// 400 `request.invalid` and anything else unexpected.
class DeletionUnexpected extends DeletionFailure {
  const DeletionUnexpected([this.cause]);
  final Object? cause;
}

/// The [DeletionFailure] an API error stands for.
DeletionFailure deletionFailure(Object error) => switch (error) {
  DeletionFailure() => error,
  ApiV1Exception(message: 'auth.sign_in_required') => const SignInRequired(),
  ApiV1Exception(message: 'auth.recent_sign_in_required') =>
    const ReauthRequired(),
  ApiV1Exception(message: 'account.admin_cannot_self_delete') =>
    const AdminCannotDelete(),
  ApiV1Exception(message: 'account.deletion_in_progress') =>
    const DeletionInProgress(),
  ApiV1Exception() || PostgrestException() => DeletionUnexpected(error),
  _ => const DeletionNetworkError(),
};

/// What the deletion flow needs from auth and the API; [SupabaseAccountGateway]
/// in the app, a fake in tests.
abstract interface class AccountDeletionGateway {
  /// The signed-in Google or Apple rider; null when signed out or anonymous.
  AccountIdentity? get current;

  /// A sign-in completed or a session was restored at launch.
  Stream<void> get signIns;

  Future<AccountDeletionState> status();
  Future<AccountDeletionState> request();
  Future<AccountDeletionState> cancel();

  /// `apple-revoke`; throws [AdminCannotDelete] on 403, anything else on
  /// other failures (which never block the request).
  Future<void> revokeApple(String token, String hint);

  /// Signs in again with the rider's provider and returns who signed in;
  /// throws [ReauthIncomplete] when that does not finish.
  Future<AccountIdentity> reauthenticate({required bool apple});

  /// Puts back the session from before [reauthenticate].
  Future<void> restorePrevious();

  /// Clears this device's session; the server's are already revoked, so
  /// errors are ignored.
  Future<void> signOutLocal();
}

/// One pass through 刪除帳號 from the explanation page: re-sign-in, then
/// for Apple `apple-revoke`, then `request_account_deletion()` (#215, #268).
class DeletionAttempt {
  DeletionAttempt(this.gateway, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final AccountDeletionGateway gateway;
  final DateTime Function() clock;

  bool _appleSignedIn = false;
  bool _revokeAttempted = false;
  bool _backendWantsSignIn = false;

  /// Whether the last `apple-revoke` did not revoke the grant (P15c ⑤).
  bool appleRevokeFailed = false;

  /// Whether [submit] needs [reauthenticate] first. Apple accounts always
  /// sign in again once: the revoke needs that sign-in's provider token.
  bool get needsReauth {
    final me = gateway.current;
    if (me == null) return true;
    if (me.apple && !_appleSignedIn) return true;
    return _backendWantsSignIn || needsRecentSignIn(me.signedInAt, clock());
  }

  /// Signs in again and checks it is the same rider; another account is
  /// signed out again and the original session put back.
  Future<void> reauthenticate() async {
    final before = gateway.current;
    if (before == null) throw const SignInRequired();
    final after = await gateway.reauthenticate(apple: before.apple);
    if (after.id != before.id) {
      await gateway.restorePrevious();
      throw WrongAccount(after.email);
    }
    _backendWantsSignIn = false;
    if (before.apple) {
      _appleSignedIn = true;
      // A new Apple sign-in is a new grant to revoke.
      _revokeAttempted = false;
    }
  }

  /// Revokes Apple's grant (failures do not block), then requests deletion.
  /// A retry after a failed request does not revoke again.
  Future<AccountDeletionState> submit() async {
    if (needsReauth) throw const ReauthRequired();
    final me = gateway.current!;
    if (me.apple && !_revokeAttempted) {
      _revokeAttempted = true;
      appleRevokeFailed = !await revokeApple(gateway, me);
    }
    try {
      return await gateway.request();
    } catch (error) {
      final failure = deletionFailure(error);
      if (failure is ReauthRequired) _backendWantsSignIn = true;
      throw failure;
    }
  }
}

/// Revokes [me]'s Apple grant; false when it did not (no token, Apple or the
/// network failed). Only an admin account stops the flow.
Future<bool> revokeApple(
  AccountDeletionGateway gateway,
  AccountIdentity me,
) async {
  final token = me.appleToken, hint = me.appleTokenHint;
  if (token == null || hint == null) return false;
  try {
    await gateway.revokeApple(token, hint);
    return true;
  } on AdminCannotDelete {
    rethrow;
  } catch (_) {
    return false;
  }
}

/// The signed-out notice (P15b ①) after a request on this device, or after
/// an old session found a request made elsewhere.
@immutable
class DeletionNotice {
  const DeletionNotice({this.scheduledAt, this.appleRevokeFailed = false});
  final String? scheduledAt;
  final bool appleRevokeFailed;
}

/// The short confirmation after the cooling-off choice (P15b ③④).
@immutable
class DeletionBanner {
  const DeletionBanner.cancelled() : continued = false, scheduledAt = null;
  const DeletionBanner.continued(this.scheduledAt) : continued = true;
  final bool continued;
  final String? scheduledAt;
}

final accountDeletionProvider =
    ChangeNotifierProvider<AccountDeletionController>((ref) {
      // read, not watch: the store notifies on every change, and a rebuilt
      // controller would leave the router and settings with different ones.
      // The store instance itself never changes.
      final store = ref.read(storeProvider);
      final client = store.client;
      return AccountDeletionController(
        client == null ? null : SupabaseAccountGateway(client),
        clearLocalData: store.clearParking,
      );
    });

/// The app-wide deletion state: the pending choice that blocks the app
/// (P15b ②), the signed-out notice (①) and the confirmations (③④).
class AccountDeletionController extends ChangeNotifier
    with WidgetsBindingObserver {
  AccountDeletionController(
    this.gateway, {
    this.clearLocalData,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Null in the example build: no accounts there.
  final AccountDeletionGateway? gateway;

  /// Clears this phone's parking record after a request.
  final Future<void> Function()? clearLocalData;
  final DateTime Function() clock;

  /// A pending request this session must decide on before using the app.
  AccountDeletionState? pending;

  /// Shown after signing out (①); cleared by 完成 or signing in.
  DeletionNotice? notice;

  /// ③ or ④, shown over the app once.
  DeletionBanner? banner;

  StreamSubscription<void>? _signIns;
  bool _started = false, _disposed = false;
  int _busy = 0, _check = 0;

  /// Follows sign-ins and the app returning to the foreground. Idempotent.
  void start() {
    final gateway = this.gateway;
    if (_started || gateway == null) return;
    _started = true;
    _signIns = gateway.signIns.listen((_) {
      // A new session: a status read for the previous one no longer applies.
      _check++;
      unawaited(check());
    });
    WidgetsBinding.instance.addObserver(this);
    // Not during the build that starts it.
    scheduleMicrotask(() => unawaited(check()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(check());
  }

  /// Runs [action] with the sign-in checks paused: the flow's own
  /// re-sign-in and request must not be read as a cooling-off sign-in.
  /// Starting it invalidates a status read in flight (it may predate a
  /// cancel or request); a check skipped meanwhile, such as a sign-in on P11
  /// opened from the flow, runs once it ends.
  Future<T> guard<T>(Future<T> Function() action) async {
    _busy++;
    _check++;
    try {
      return await action();
    } finally {
      _busy--;
      if (_busy == 0 && _skipped && !_disposed) {
        _skipped = false;
        unawaited(check());
      }
    }
  }

  /// A check was skipped or dropped while [guard] ran.
  bool _skipped = false;

  DeletionAttempt attempt() => DeletionAttempt(gateway!, clock: clock);

  /// Reads the status for a signed-in session: a pending request made
  /// before this sign-in signs this old session out (①); one made after it
  /// asks the rider to choose (②). Failures leave things as they are.
  ///
  /// Calls while one runs (the auth stream replays its history on listen)
  /// share it and run it once more afterwards.
  Future<void> check() {
    if (_running case final running?) {
      _again = true;
      return running;
    }
    return _running = _checkRepeatedly();
  }

  Future<void>? _running;
  bool _again = false;

  Future<void> _checkRepeatedly() async {
    try {
      do {
        _again = false;
        await _checkOnce();
      } while (_again && !_disposed);
    } finally {
      _running = null;
    }
  }

  Future<void> _checkOnce() async {
    final gateway = this.gateway;
    if (gateway == null) return;
    if (_busy > 0) {
      _skipped = true;
      return;
    }
    final me = gateway.current;
    if (me == null) {
      _set(pending: null);
      return;
    }
    final check = ++_check;
    final AccountDeletionState state;
    try {
      state = await gateway.status();
    } catch (_) {
      return;
    }
    if (_disposed) return;
    if (check != _check || _busy > 0) {
      // Superseded by a newer check, or by a cancel or request: a guard
      // that is still running checks again when it ends.
      if (_busy > 0) _skipped = true;
      return;
    }
    // The session changed meanwhile (signed out, or signed in again): its
    // own check, queued by the sign-in, decides instead.
    final still = gateway.current;
    if (still?.id != me.id || still?.signedInAt != me.signedInAt) return;
    if (state.status != 'pending') {
      // Signed in without a request (cancelled elsewhere): no notice either.
      final hadNotice = notice != null;
      notice = null;
      _set(pending: null, changed: hadNotice);
      return;
    }
    if (signedInAfterRequest(me.signedInAt, state.requestedAt)) {
      notice = null;
      _set(pending: state);
    } else {
      await gateway.signOutLocal();
      notice = DeletionNotice(scheduledAt: state.scheduledAt);
      _set(pending: null, changed: true);
    }
  }

  /// After a successful request: sign out here, clear the parking record,
  /// then show ①.
  Future<void> completeRequest(
    AccountDeletionState state, {
    bool appleRevokeFailed = false,
  }) async {
    await gateway?.signOutLocal();
    try {
      await clearLocalData?.call();
    } catch (_) {
      // The record is best effort; the request already succeeded.
    }
    notice = DeletionNotice(
      scheduledAt: state.scheduledAt,
      appleRevokeFailed: appleRevokeFailed,
    );
    _set(pending: null, changed: true);
  }

  /// 取消刪除 (③); throws a [DeletionFailure].
  Future<void> cancelPending() => guard(() async {
    try {
      await gateway!.cancel();
    } catch (error) {
      throw deletionFailure(error);
    }
    banner = const DeletionBanner.cancelled();
    _set(pending: null, changed: true);
  });

  /// 繼續刪除 (④): the request stays; Apple's new grant is revoked
  /// (failures do not block), then this device signs out.
  Future<void> continuePending() => guard(() async {
    final gateway = this.gateway!;
    final scheduledAt = pending?.scheduledAt;
    final me = gateway.current;
    if (me != null && me.apple) {
      try {
        await revokeApple(gateway, me);
      } catch (_) {
        // Not even an admin answer stops signing out here.
      }
    }
    await gateway.signOutLocal();
    banner = DeletionBanner.continued(scheduledAt);
    _set(pending: null, changed: true);
  });

  /// 好 on ⑤: the deletion is running; sign out.
  Future<void> acknowledgeInProgress() => guard(() async {
    await gateway?.signOutLocal();
    _set(pending: null);
  });

  void dismissNotice() {
    if (notice == null) return;
    notice = null;
    _notify();
  }

  void dismissBanner() {
    if (banner == null) return;
    banner = null;
    _notify();
  }

  void _set({required AccountDeletionState? pending, bool changed = false}) {
    if (!changed && pending == this.pending && pending == null) return;
    this.pending = pending;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    unawaited(_signIns?.cancel());
    super.dispose();
  }
}

/// [AccountDeletionGateway] over Supabase: `api_v1` RPCs, the `apple-revoke`
/// Edge Function and OAuth re-sign-in. Every call carries the App Check
/// header when there is a token (#203).
class SupabaseAccountGateway implements AccountDeletionGateway {
  SupabaseAccountGateway(
    this.client, {
    this.signInGrace = const Duration(seconds: 10),
  });
  final SupabaseClient client;

  /// How long after returning from the browser a sign-in may still arrive
  /// (the code exchange) before it counts as closed.
  final Duration signInGrace;

  String? _previousRefreshToken;

  static Future<Map<String, String>> _headers() async =>
      await AppCheck.headers() ?? const {};

  ApiV1Client get _api => ApiV1Client(client, headers: _headers);

  @override
  AccountIdentity? get current {
    final session = client.auth.currentSession;
    final user = session?.user ?? client.auth.currentUser;
    if (session == null || user == null || user.isAnonymous) return null;
    final apple =
        (user.identities ?? const []).any((i) => i.provider == 'apple') ||
        user.appMetadata['provider'] == 'apple';
    final refresh = session.providerRefreshToken,
        access = session.providerToken;
    final metadata = user.userMetadata ?? const {};
    return AccountIdentity(
      id: user.id,
      email: user.email,
      name: (metadata['full_name'] ?? metadata['name']) as String?,
      apple: apple,
      signedInAt: signedInAtFromJwt(session.accessToken),
      appleToken: refresh ?? access,
      appleTokenHint: refresh != null
          ? 'refresh_token'
          : access != null
          ? 'access_token'
          : null,
    );
  }

  @override
  Stream<void> get signIns => client.auth.onAuthStateChange
      .where(
        (s) =>
            s.event == AuthChangeEvent.signedIn ||
            s.event == AuthChangeEvent.initialSession,
      )
      .map((_) {});

  @override
  Future<AccountDeletionState> status() => _api.accountDeletionStatus();

  @override
  Future<AccountDeletionState> request() =>
      _api.requestAccountDeletion(pSource: 'app');

  @override
  Future<AccountDeletionState> cancel() => _api.cancelAccountDeletion();

  @override
  Future<void> revokeApple(String token, String hint) async {
    try {
      await client.functions.invoke(
        'apple-revoke',
        body: {'token': token, 'token_type_hint': hint},
        headers: await _headers(),
      );
    } on FunctionException catch (e) {
      final details = e.details;
      if (e.status == 403 &&
          details is Map &&
          details['error'] == 'account.admin_cannot_self_delete') {
        throw const AdminCannotDelete();
      }
      rethrow;
    }
  }

  @override
  Future<AccountIdentity> reauthenticate({required bool apple}) async {
    final before = client.auth.currentSession;
    _previousRefreshToken = before?.refreshToken;
    final done = Completer<void>();
    // The auth stream replays its history: only a new session counts.
    final sub = client.auth.onAuthStateChange.listen((s) {
      if (s.event == AuthChangeEvent.signedIn &&
          s.session != null &&
          s.session!.accessToken != before?.accessToken &&
          !done.isCompleted) {
        done.complete();
      }
    }, onError: (Object _) {});
    final returned = _ReturnWatcher(signInGrace, () {
      if (!done.isCompleted) done.completeError(const ReauthIncomplete());
    });
    try {
      final opened = await client.auth.signInWithOAuth(
        apple ? OAuthProvider.apple : OAuthProvider.google,
        redirectTo: kIsWeb
            ? Uri.base.replace(fragment: '', query: '').toString()
            : AppConfig.redirectUrl,
        authScreenLaunchMode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
      if (!opened) throw const ReauthIncomplete();
      await done.future.timeout(
        const Duration(minutes: 5),
        onTimeout: () => throw const ReauthIncomplete(),
      );
    } on DeletionFailure {
      rethrow;
    } catch (_) {
      throw const ReauthIncomplete();
    } finally {
      returned.dispose();
      unawaited(sub.cancel());
    }
    final me = current;
    if (me == null) throw const ReauthIncomplete();
    return me;
  }

  @override
  Future<void> restorePrevious() async {
    final token = _previousRefreshToken;
    _previousRefreshToken = null;
    if (token == null) {
      await signOutLocal();
      return;
    }
    try {
      await client.auth.setSession(token);
    } catch (_) {
      // The old session cannot come back: sign the other account out rather
      // than leave it signed in.
      await signOutLocal();
    }
  }

  @override
  Future<void> signOutLocal() async {
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // The local session is removed before the server call that failed.
    }
  }
}

/// Calls [onClosed] when the app comes back from the browser and no
/// sign-in arrives within [grace].
class _ReturnWatcher with WidgetsBindingObserver {
  _ReturnWatcher(this.grace, this.onClosed) {
    WidgetsBinding.instance.addObserver(this);
  }
  final Duration grace;
  final VoidCallback onClosed;
  bool _left = false;
  Timer? _timer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _left = true;
        _timer?.cancel();
      case AppLifecycleState.resumed when _left:
        _timer?.cancel();
        _timer = Timer(grace, onClosed);
      default:
        break;
    }
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

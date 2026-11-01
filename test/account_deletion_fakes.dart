import 'dart:async';
import 'dart:convert';

import 'package:motorcycle_parking/api/v1/api_v1.g.dart';
import 'package:motorcycle_parking/data/account_deletion.dart';

/// An access token whose `amr` says it signed in at [at].
String jwtSignedInAt(DateTime at) {
  String part(Object value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.'
      '${part({
        'sub': 'rider',
        'amr': [
          {'method': 'oauth', 'timestamp': at.millisecondsSinceEpoch ~/ 1000},
        ],
      })}.sig';
}

AccountDeletionState deletionState({
  String status = 'none',
  String? requestedAt,
  String? scheduledAt,
  bool canSelfDelete = true,
}) => AccountDeletionState(
  status: status,
  requestedAt: requestedAt,
  scheduledAt: scheduledAt,
  canSelfDelete: canSelfDelete,
  cannotSelfDeleteReason: canSelfDelete
      ? null
      : 'account.admin_cannot_self_delete',
);

const pendingRequestedAt = '2026-11-01T02:00:00Z';
const pendingScheduledAt = '2026-11-08T02:00:00Z';

AccountDeletionState pendingState() => deletionState(
  status: 'pending',
  requestedAt: pendingRequestedAt,
  scheduledAt: pendingScheduledAt,
);

ApiV1Exception apiError(String message, [String code = 'PT401']) =>
    ApiV1Exception(code: code, message: message);

/// Records every call in [calls]; each queue gives the next result (a value,
/// or an [Object] to throw) and falls back to success.
class FakeDeletionGateway implements AccountDeletionGateway {
  FakeDeletionGateway({this.current});

  @override
  AccountIdentity? current;
  final calls = <String>[];
  final signInEvents = StreamController<void>.broadcast();
  final statuses = <Object>[];
  AccountDeletionState statusFallback = deletionState();

  /// Answers held back by the test, used before [statuses].
  final statusFutures = <Future<AccountDeletionState>>[];

  /// Also signs the real client out, for flows that then open P11.
  Future<void> Function()? onSignOut;
  final requests = <Object>[];
  final cancels = <Object>[];
  final revokes = <Object>[];

  /// Who signs in on [reauthenticate]; null throws [ReauthIncomplete].
  final reauths = <AccountIdentity?>[];
  AccountIdentity? previous;

  Future<T> _next<T>(List<Object> queue, T fallback) async {
    final Object next = queue.isEmpty ? fallback as Object : queue.removeAt(0);
    if (next is T) return next as T;
    throw next;
  }

  @override
  Stream<void> get signIns => signInEvents.stream;

  @override
  Future<AccountDeletionState> status() {
    calls.add('status');
    if (statusFutures.isNotEmpty) return statusFutures.removeAt(0);
    return _next(statuses, statusFallback);
  }

  @override
  Future<AccountDeletionState> request() {
    calls.add('request');
    return _next(requests, pendingState());
  }

  @override
  Future<AccountDeletionState> cancel() {
    calls.add('cancel');
    return _next(cancels, deletionState());
  }

  @override
  Future<void> revokeApple(String token, String hint) async {
    calls.add('revoke:$token:$hint');
    if (revokes.isNotEmpty) {
      final next = revokes.removeAt(0);
      if (next is! bool) throw next;
    }
  }

  @override
  Future<AccountIdentity> reauthenticate({required bool apple}) async {
    calls.add(apple ? 'reauth:apple' : 'reauth:google');
    previous = current;
    final next = reauths.isEmpty ? current : reauths.removeAt(0);
    if (next == null) throw const ReauthIncomplete();
    current = next;
    return next;
  }

  @override
  Future<void> restorePrevious() async {
    calls.add('restore');
    current = previous;
  }

  @override
  Future<void> signOutLocal() async {
    calls.add('signOut');
    current = null;
    await onSignOut?.call();
  }
}

AccountIdentity google({DateTime? signedInAt, String id = 'rider'}) =>
    AccountIdentity(
      id: id,
      email: '$id@gmail.com',
      name: '阿哲',
      signedInAt: signedInAt,
    );

AccountIdentity apple({DateTime? signedInAt, String token = 'apple-rt'}) =>
    AccountIdentity(
      id: 'rider',
      email: 'x@privaterelay.appleid.com',
      name: '阿哲',
      apple: true,
      signedInAt: signedInAt,
      appleToken: token,
      appleTokenHint: 'refresh_token',
    );

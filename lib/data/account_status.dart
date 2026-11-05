import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/app_check.dart';
import 'app_store.dart';

export 'account_suspended.dart';

/// What `api_v1.my_account_status()` (authenticated only) says about the
/// signed-in account.
// TODO(#331): #332 合併後改用 AccountStatus（lib/api/v1/api_v1.g.dart）。
@immutable
class AccountStatus {
  const AccountStatus({required this.suspended, this.until});

  /// The RPC's `{suspended, suspended_until}`; a one-row list is read the
  /// same. Throws [FormatException] for anything else.
  factory AccountStatus.fromJson(Object? json) {
    final row = json is List && json.length == 1 ? json.single : json;
    if (row case {'suspended': final bool suspended}) {
      final until = row['suspended_until'];
      return AccountStatus(
        suspended: suspended,
        until: until is String ? DateTime.tryParse(until)?.toUtc() : null,
      );
    }
    throw FormatException('my_account_status', json);
  }

  final bool suspended;

  /// Null while suspended means until further notice.
  final DateTime? until;
}

// TODO(#331): #332 合併後改用 ApiV1Client 的 myAccountStatus。
/// Reads `api_v1.my_account_status()` with the App Check header when there
/// is a token (#203).
Future<AccountStatus> readMyAccountStatus(SupabaseClient client) async {
  var request = client.schema('api_v1').rpc<Object?>('my_account_status');
  for (final header in (await AppCheck.headers() ?? const {}).entries) {
    request = request.setHeader(header.key, header.value);
  }
  return AccountStatus.fromJson(await request);
}

final accountStatusProvider = ChangeNotifierProvider<AccountStatusController>((
  ref,
) {
  // read, not watch: the store instance never changes (as for deletion).
  final store = ref.read(storeProvider);
  final client = store.client;
  return AccountStatusController(
    client == null ? null : () => readMyAccountStatus(client),
    userId: () => store.riderId,
  )..start();
});

/// The signed-in account's suspension for P10's card (③) and P12's
/// read-only name (④). Read when P10 opens ([refresh]) and when the App
/// returns to the foreground. Fails open: a failed read leaves the status
/// unknown and nothing is blocked; a write still gets the shared panel.
class AccountStatusController extends ChangeNotifier
    with WidgetsBindingObserver {
  AccountStatusController(this._read, {required this.userId});

  /// Null in the example build: no accounts there.
  final Future<AccountStatus> Function()? _read;

  /// The signed-in account; null when signed out.
  final String? Function() userId;

  AccountStatus? _status;
  String? _statusFor;
  int _request = 0;
  bool _started = false, _disposed = false;

  /// The last status read for the account signed in now; null while unknown.
  AccountStatus? get status =>
      _statusFor != null && _statusFor == userId() ? _status : null;

  /// The current suspension, or null when not suspended or unknown.
  AccountStatus? get suspension => status?.suspended == true ? status : null;

  /// Follows the App returning to the foreground. Idempotent.
  void start() {
    if (_started || _read == null) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && userId() != null) {
      unawaited(refresh());
    }
  }

  /// Reads the status again; a failure, or no signed-in account, forgets it.
  Future<void> refresh() async {
    final read = _read;
    final user = userId();
    final request = ++_request;
    if (read == null || user == null) return _set(null, null);
    try {
      final status = await read();
      if (request == _request && user == userId()) _set(status, user);
    } catch (_) {
      if (request == _request) _set(null, null);
    }
  }

  void _set(AccountStatus? status, String? user) {
    if (_disposed) return;
    final changed =
        status?.suspended != _status?.suspended ||
        status?.until != _status?.until ||
        user != _statusFor;
    _status = status;
    _statusFor = user;
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

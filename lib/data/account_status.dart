import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show AccountStatus, ApiV1Client;
import '../core/app_check.dart';
import 'app_store.dart';

export '../api/v1/api_v1.g.dart' show AccountStatus;
export 'account_suspended.dart';

/// When [AccountStatus] (`api_v1.my_account_status()`, authenticated only)
/// says the suspension ends.
extension AccountStatusUntil on AccountStatus {
  /// Null while suspended means until further notice.
  DateTime? get until => switch (suspendedUntil) {
    final String value => DateTime.tryParse(value)?.toUtc(),
    null => null,
  };
}

/// Reads `api_v1.my_account_status()` with the App Check header when there
/// is a token (#203).
Future<AccountStatus> readMyAccountStatus(SupabaseClient client) => ApiV1Client(
  client,
  headers: () async => await AppCheck.headers() ?? const {},
).myAccountStatus();

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

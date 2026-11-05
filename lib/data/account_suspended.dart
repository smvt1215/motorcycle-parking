import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show ApiV1Exception;

/// The backend refused a write because the account is suspended (#331):
/// only the App's writes stop; browsing, favourites and account deletion
/// carry on. [until] is when it ends; null means until further notice.
class AccountSuspended implements Exception {
  const AccountSuspended(this.until) : untilKnown = true;

  /// The end could not be learnt (a profile that kept its old values while
  /// the status cannot be read): nothing is said about when it ends, so it
  /// is not mistaken for an indefinite suspension.
  const AccountSuspended.untilUnknown() : until = null, untilKnown = false;

  final DateTime? until;

  /// Whether [until] is the backend's answer; false for [untilUnknown].
  final bool untilKnown;

  @override
  String toString() => untilKnown
      ? 'AccountSuspended(until: $until)'
      : 'AccountSuspended(until: unknown)';
}

const _suspendedCode = 'account.suspended';

/// The suspension [error] reports, or null when it is something else:
/// - an Edge Function's HTTP 403 `{"error":"account.suspended","until":…}`;
/// - an `api_v1` RPC's PostgREST 403 (`PT403`, message
///   `account.suspended`, details the JSON string `{"until":…}`), raw or
///   as [ApiV1Exception];
/// - an [AccountSuspended] already.
AccountSuspended? accountSuspendedFrom(Object? error) => switch (error) {
  AccountSuspended() => error,
  FunctionException(status: 403, :final details) => switch (_json(details)) {
    {'error': _suspendedCode} && final Map<Object?, Object?> body =>
      AccountSuspended(_until(body['until'])),
    _ => null,
  },
  ApiV1Exception(message: _suspendedCode, :final details) => AccountSuspended(
    _until(_json(details), nested: true),
  ),
  PostgrestException(message: _suspendedCode, :final details) =>
    AccountSuspended(_until(_json(details), nested: true)),
  _ => null,
};

/// [value] decoded when it is a JSON string; as is otherwise.
Object? _json(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

/// The end time in [value] (an ISO 8601 string), or under its `until` key
/// when [nested]; null when absent or unreadable.
DateTime? _until(Object? value, {bool nested = false}) {
  final raw = nested && value is Map ? value['until'] : value;
  return raw is String ? DateTime.tryParse(raw)?.toUtc() : null;
}

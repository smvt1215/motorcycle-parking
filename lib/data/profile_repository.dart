import 'package:supabase_flutter/supabase_flutter.dart';

import 'account_status.dart';

/// The name new spots show publicly: only the name the rider saved
/// (display_name), cleaned like the server does. Blank, whitespace-only
/// (including the full-width space U+3000) or missing means no public name,
/// so spots show 由車友回報. Provider names (full_name, name) never count.
String? profilePublicName(User? user) {
  final value = user?.userMetadata?['display_name'];
  if (value is! String) return null;
  final name = normalizeProfileName(value);
  return name.isEmpty ? null : name;
}

/// The sign-in provider's name (Google full_name, then name), offered as
/// P12's prefilled suggestion only to a rider who has never saved a name:
/// metadata without a display_name key. Once the key exists, even blank
/// because the rider cleared the name, there is no suggestion. It becomes
/// public only once saved.
String? profileNameSuggestion(User? user) {
  final data = user?.userMetadata;
  if (data == null || data.containsKey('display_name')) return null;
  // Apple names are never kept (#319): an Apple account gets no suggestion.
  if (user?.appMetadata['provider'] == 'apple') return null;
  for (final key in ['full_name', 'name']) {
    final value = data[key];
    if (value is! String) continue;
    final name = normalizeProfileName(value);
    if (name.isNotEmpty) return name;
  }
  return null;
}

String? profileAvatarUrl(User? user) {
  final data = user?.userMetadata;
  final values = data?.containsKey('profile_avatar_url') == true
      ? [data?['profile_avatar_url']]
      : [data?['avatar_url'], data?['picture']];
  for (final value in values) {
    if (value is! String) continue;
    final uri = Uri.tryParse(value.trim());
    if (uri?.scheme == 'https' &&
        uri!.host.isNotEmpty &&
        uri.userInfo.isEmpty) {
      return uri.toString();
    }
  }
  return null;
}

/// Mirrors the server-side contributor name cleanup: invisible format
/// characters (Unicode Cf, including bidi controls and ZWJ) are removed and
/// runs of whitespace become one space.
String normalizeProfileName(String value) => value
    .replaceAll(RegExp(r'\p{Cf}', unicode: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Why [value] cannot be saved as the display name, or null. An empty name
/// is valid and means the name stays private.
String? profileNameError(String value) {
  if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) return '顯示名稱請使用單行文字';
  // Blank is allowed: saving it clears the public name (#319).
  final name = normalizeProfileName(value);
  if (name.runes.length > 40) return '顯示名稱最多 40 個字';
  return null;
}

/// Saves the display name in user metadata; an empty name is saved as ''
/// so new spots show 由車友回報. Avatar uploads were cancelled
/// (2026-11-01): the avatar is the name's first character or the sign-in
/// provider's picture, read by [profileAvatarUrl]. [removeAvatar] hides the
/// provider's picture so the name's first character shows instead.
class ProfileRepository {
  ProfileRepository(this.client);
  final SupabaseClient client;

  Future<void> update({
    required String displayName,
    bool removeAvatar = false,
  }) async {
    final issue = profileNameError(displayName);
    if (issue != null) throw StateError(issue);
    final user = client.auth.currentUser;
    if (user == null || user.isAnonymous) throw StateError('請先登入再編輯個人資料');
    final name = normalizeProfileName(displayName);
    await client.auth.updateUser(
      UserAttributes(
        data: {
          'display_name': name,
          // An explicit empty value prevents falling back to a provider avatar.
          if (removeAvatar) 'profile_avatar_url': '',
        },
      ),
    );
    await _checkSaved(name: name, removeAvatar: removeAvatar);
  }

  /// A suspended account's profile keeps its old values without an error
  /// (#331), and `updateUser` answers with the values it was sent, so ask
  /// again: suspended per `my_account_status`, or, when that cannot be
  /// read, the stored profile without the change, throws [AccountSuspended]
  /// after taking the stored profile back into the session.
  Future<void> _checkSaved({
    required String name,
    required bool removeAvatar,
  }) async {
    AccountSuspended? refused;
    try {
      final status = await readMyAccountStatus(client);
      if (status.suspended) refused = AccountSuspended(status.until);
    } catch (_) {
      try {
        final data = (await client.auth.getUser()).user?.userMetadata;
        final kept =
            data?['display_name'] != name ||
            (removeAvatar && data?['profile_avatar_url'] != '');
        // When it ends is unknown here.
        if (kept) refused = const AccountSuspended.untilUnknown();
      } catch (_) {
        // Nothing more to tell; the save stands as answered.
      }
    }
    if (refused == null) return;
    try {
      // The session still holds the values sent; the server's come back.
      await client.auth.refreshSession();
    } catch (_) {}
    throw refused;
  }
}

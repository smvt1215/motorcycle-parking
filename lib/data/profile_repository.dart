import 'package:supabase_flutter/supabase_flutter.dart';

String? profileDisplayName(User? user) {
  final data = user?.userMetadata;
  for (final key in ['display_name', 'full_name', 'name']) {
    final value = data?[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
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

String? profileNameError(String value) {
  if (RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) return '顯示名稱請使用單行文字';
  final name = normalizeProfileName(value);
  if (name.isEmpty) return '請填寫顯示名稱';
  if (name.runes.length > 40) return '顯示名稱最多 40 個字';
  return null;
}

/// Saves the display name in user metadata. Avatar uploads were cancelled
/// (2026-11-01): the avatar is the name's first character or the sign-in
/// provider's picture, read by [profileAvatarUrl].
class ProfileRepository {
  ProfileRepository(this.client);
  final SupabaseClient client;

  Future<void> update({required String displayName}) async {
    final issue = profileNameError(displayName);
    if (issue != null) throw StateError(issue);
    final user = client.auth.currentUser;
    if (user == null || user.isAnonymous) throw StateError('請先登入再編輯個人資料');
    await client.auth.updateUser(
      UserAttributes(data: {'display_name': normalizeProfileName(displayName)}),
    );
  }
}

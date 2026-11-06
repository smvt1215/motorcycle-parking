import 'package:supabase_flutter/supabase_flutter.dart';

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
/// so new spots show 由車友回報. Avatar uploads were cancelled (2026-11-01)
/// and sign-in providers' pictures are not used (2026-11-07): the avatar is
/// only the name's first character, so the name is the only thing saved.
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

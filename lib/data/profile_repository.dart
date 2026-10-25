import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

const profileAvatarBucket = 'motopark-avatars';
const maxAvatarBytes = 2 * 1024 * 1024;

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

String? profileNameError(String value) {
  final name = value.trim();
  if (name.isEmpty) return '請填寫顯示名稱';
  if (name.runes.length > 40) return '顯示名稱最多 40 個字';
  if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) return '顯示名稱請使用單行文字';
  return null;
}

/// Determine the upload type from the content, not a picked file's name.
({String extension, String contentType}) avatarFormat(Uint8List bytes) {
  if (bytes.isEmpty || bytes.length > maxAvatarBytes) {
    throw StateError('頭像照片需小於 2 MB');
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47 &&
      bytes[4] == 0x0d &&
      bytes[5] == 0x0a &&
      bytes[6] == 0x1a &&
      bytes[7] == 0x0a) {
    return (extension: 'png', contentType: 'image/png');
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xff &&
      bytes[1] == 0xd8 &&
      bytes[2] == 0xff) {
    return (extension: 'jpg', contentType: 'image/jpeg');
  }
  if (bytes.length >= 12 &&
      String.fromCharCodes(bytes.take(4)) == 'RIFF' &&
      String.fromCharCodes(bytes.skip(8).take(4)) == 'WEBP') {
    return (extension: 'webp', contentType: 'image/webp');
  }
  throw StateError('請選擇 JPEG、PNG 或 WebP 照片');
}

bool ownedAvatarPath(Object? path, String userId) =>
    path is String &&
    path.startsWith('$userId/') &&
    RegExp(r'^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|png|webp)$').hasMatch(path);

/// Saves metadata only after the new image is uploaded. Every object has a
/// fresh path; neither overwriting nor another account's path is needed.
class ProfileRepository {
  ProfileRepository(this.client);
  final SupabaseClient client;

  Future<void> update({
    required String displayName,
    Uint8List? avatarBytes,
    bool removeAvatar = false,
  }) async {
    final issue = profileNameError(displayName);
    if (issue != null) throw StateError(issue);
    final user = client.auth.currentUser;
    if (user == null || user.isAnonymous) throw StateError('請先登入再編輯個人資料');
    final userId = user.id;
    final oldPath = user.userMetadata?['profile_avatar_path'];
    String? newPath;
    final data = <String, dynamic>{'display_name': displayName.trim()};
    try {
      if (avatarBytes != null) {
        final format = avatarFormat(avatarBytes);
        newPath = '$userId/${const Uuid().v4()}.${format.extension}';
        await client.storage
            .from(profileAvatarBucket)
            .uploadBinary(
              newPath,
              avatarBytes,
              fileOptions: FileOptions(
                contentType: format.contentType,
                upsert: false,
              ),
            );
        data['profile_avatar_url'] = client.storage
            .from(profileAvatarBucket)
            .getPublicUrl(newPath);
        data['profile_avatar_path'] = newPath;
      } else if (removeAvatar) {
        // An explicit empty value prevents falling back to a provider avatar.
        data['profile_avatar_url'] = '';
        data['profile_avatar_path'] = '';
      }
      if (client.auth.currentUser?.id != userId) {
        throw StateError('帳號已變更，請重新開啟個人資料');
      }
      await client.auth.updateUser(UserAttributes(data: data));
    } catch (_) {
      if (newPath != null) await _removeOwned(newPath, userId);
      rethrow;
    }
    if ((newPath != null || removeAvatar) && oldPath != newPath) {
      await _removeOwned(oldPath, userId);
    }
  }

  Future<void> _removeOwned(Object? path, String userId) async {
    if (!ownedAvatarPath(path, userId)) return;
    try {
      await client.storage.from(profileAvatarBucket).remove([path as String]);
    } catch (_) {
      // Cleanup must not turn a successfully saved profile into a failed save.
    }
  }
}

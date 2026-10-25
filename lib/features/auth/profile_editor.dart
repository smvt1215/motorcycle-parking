import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

import '../../data/app_store.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';
import 'profile_avatar.dart';

Future<void> showProfileEditor(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(context, (_) => ProfileEditor(store: store));

Future<Uint8List?> pickProfilePhoto() async {
  final file = await ImagePicker().pickImage(
    source: ImageSource.gallery,
    maxWidth: 768,
    maxHeight: 768,
    imageQuality: 85,
    requestFullMetadata: false,
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  avatarFormat(bytes);
  return bytes;
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.store,
    this.pickPhoto = pickProfilePhoto,
  });
  final AppStore store;
  final Future<Uint8List?> Function() pickPhoto;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final form = GlobalKey<FormState>();
  late final user = widget.store.client?.auth.currentUser;
  late final name = TextEditingController(text: profileDisplayName(user) ?? '');
  Uint8List? photo;
  bool remove = false, saving = false, picking = false;
  String? error;
  bool get changed =>
      photo != null ||
      remove ||
      name.text.trim() != (profileDisplayName(user) ?? '');

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> pick() async {
    setState(() {
      picking = true;
      error = null;
    });
    try {
      final value = await widget.pickPhoto();
      if (value != null) {
        avatarFormat(value);
        if (mounted) {
          setState(() {
            photo = value;
            remove = false;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError ? e.message.toString() : '無法讀取照片，請再試一次',
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      if (widget.store.client?.auth.currentUser?.id != user?.id) {
        throw StateError('帳號已變更，請重新開啟個人資料');
      }
      await widget.store.updateProfile(
        displayName: name.text,
        avatarBytes: photo,
        removeAvatar: remove,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError
              ? e.message.toString()
              : '資料尚未儲存，內容還在，請確認連線後再試一次',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = saving || picking;
    return PopScope(
      canPop: !saving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: form,
          child: ContentPage(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '編輯個人資料',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '關閉',
                    onPressed: saving ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Center(
                child: ProfileAvatar(
                  bytes: photo,
                  url: remove ? '' : profileAvatarUrl(user),
                  name: name.text,
                  size: 96,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  children: [
                    TextButton.icon(
                      onPressed: busy ? null : pick,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(picking ? '讀取照片中…' : '從相簿選擇'),
                    ),
                    if (photo != null ||
                        (!remove && profileAvatarUrl(user) != null))
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                photo = null;
                                remove = true;
                              }),
                        child: const Text('移除頭像'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const ValueKey('profile-name'),
                controller: name,
                enabled: !busy,
                maxLength: 40,
                decoration: const InputDecoration(
                  labelText: '顯示名稱',
                  helperText: '你回報的停車點會顯示這個名稱',
                ),
                validator: (value) => profileNameError(value ?? ''),
                onChanged: (_) => setState(() {}),
              ),
              if (user?.email case final email?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(email),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 20),
              AdaptiveButton(
                label: saving ? '儲存中…' : '儲存個人資料',
                onPressed: busy || !changed ? null : save,
              ),
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

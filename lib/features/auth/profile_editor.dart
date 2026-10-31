import '../../data/app_store.dart';
import '../../domain/account_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';
import 'profile_avatar.dart';

Future<void> showProfileEditor(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(context, (_) => ProfileEditor(store: store));

/// 編輯個人資料 (P12). Avatar uploads count as photos and stay off until
/// photo uploads open (社群核實 P2): the editor changes the name and can
/// remove the avatar the account has, which falls back to the default.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.store});
  final AppStore store;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final form = GlobalKey<FormState>();
  late final user = widget.store.client?.auth.currentUser;
  late final name = TextEditingController(text: profileDisplayName(user) ?? '');
  bool saving = false, remove = false;
  String? error;
  bool get changed =>
      remove ||
      normalizeProfileName(name.text) != (profileDisplayName(user) ?? '');

  @override
  void dispose() {
    name.dispose();
    super.dispose();
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

  Widget _header(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = Text(
      '編輯個人資料',
      style: isCupertino
          ? Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600)
          : Theme.of(context).textTheme.titleLarge,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final saveButton = TextButton(
      key: const ValueKey('profile-save'),
      onPressed: saving || !changed ? null : save,
      child: Text(
        saving ? '儲存中…' : '儲存',
        style: TextStyle(fontWeight: isCupertino ? FontWeight.w600 : null),
      ),
    );
    final close = saving ? null : () => Navigator.pop(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: isCupertino
            // iOS sheet navigation bar: 取消 / title / 儲存.
            ? Row(
                children: [
                  TextButton(onPressed: close, child: const Text('取消')),
                  Expanded(child: Center(child: title)),
                  saveButton,
                ],
              )
            // Android full-screen dialog bar: close, title, 儲存.
            : Row(
                children: [
                  IconButton(
                    tooltip: '關閉',
                    onPressed: close,
                    icon: Icon(Icons.close, color: colors.onSurface),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: title),
                  saveButton,
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final quiet = Theme.of(context).textTheme.bodySmall
        ?.copyWith(color: colors.onSurfaceVariant);
    return PopScope(
      canPop: !saving,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              Flexible(
                child: ContentPage(
                  children: [
                    Center(
                      child: ProfileAvatar(
                        url: remove ? '' : profileAvatarUrl(user),
                        name: name.text,
                        size: 96,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Semantics(
                        label: profilePhotoSemantics,
                        button: true,
                        enabled: false,
                        excludeSemantics: true,
                        child: isCupertino
                            ? TextButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.photo_library_outlined),
                                label: const Text(profilePhotoLabel),
                              )
                            : const OutlinedButton(
                                onPressed: null,
                                child: Text(profilePhotoLabel),
                              ),
                      ),
                    ),
                    if (!remove && profileAvatarUrl(user) != null)
                      Center(
                        child: TextButton(
                          key: const ValueKey('profile-remove-avatar'),
                          onPressed: saving
                              ? null
                              : () => setState(() => remove = true),
                          child: const Text(profileRemoveAvatar),
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      profilePhotoDisabled,
                      textAlign: TextAlign.center,
                      style: quiet,
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      key: const ValueKey('profile-name'),
                      controller: name,
                      enabled: !saving,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: '顯示名稱',
                        helperText: profileNameHelper,
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) => profileNameError(value ?? ''),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (user?.email case final email?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(email, style: quiet),
                      ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          error!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

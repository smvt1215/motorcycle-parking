import '../../data/app_store.dart';
import '../../domain/account_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';
import 'profile_avatar.dart';

Future<void> showProfileEditor(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(context, (_) => ProfileEditor(store: store));

/// 編輯個人資料 (P12): the editor changes the name. Avatar uploads were
/// cancelled (2026-11-01) and sign-in providers' pictures are not used
/// (2026-11-07), so the avatar is only the name's first character.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.store});
  final AppStore store;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  final form = GlobalKey<FormState>();
  late final user = widget.store.client?.auth.currentUser;
  late final public = profilePublicName(user);
  // Only a rider who has never saved a name gets the Google name prefilled
  // (②); saving it, even unchanged, makes it public. 取消 keeps it unset.
  late final suggestion = profileNameSuggestion(user);
  late final name = TextEditingController(text: public ?? suggestion ?? '');
  bool saving = false;
  String? error;
  String get _typed => normalizeProfileName(name.text);
  bool get changed => _typed != (public ?? '') || suggestion != null;

  /// ② the untouched suggestion; nothing is public yet.
  bool get _suggesting => suggestion != null && _typed == suggestion;

  /// ③ a blank field that saving turns into no public name: a saved name or
  /// the suggestion was cleared, or the rider cleared the name before
  /// (display_name saved blank, so no suggestion comes back).
  bool get _blankPrivate =>
      _typed.isEmpty &&
      (public != null ||
          suggestion != null ||
          (user?.userMetadata?.containsKey('display_name') ?? false));

  /// No public name to show (② ③ or a blank field): the avatar falls back
  /// to the generic person, not a letter.
  bool get _noPublicName => _suggesting || _blankPrivate || _typed.isEmpty;

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
      await widget.store.updateProfile(displayName: name.text);
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
    // Under the avatar: 尚未設定公開名稱 while nothing is public and saving
    // would not change that by itself; 儲存後不公開名稱 when saving clears it.
    final caption = _blankPrivate && (public != null || suggestion != null)
        ? profileNameClearing
        : _suggesting || _blankPrivate
        ? profileNameUnset
        : null;
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
                        // No public name (② ③): the generic person.
                        name: _noPublicName ? '' : name.text,
                        size: 96,
                      ),
                    ),
                    if (caption case final caption?)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          caption,
                          key: const ValueKey('profile-name-state'),
                          textAlign: TextAlign.center,
                          style: quiet,
                        ),
                      ),
                    const SizedBox(height: 20),
                    TextFormField(
                      key: const ValueKey('profile-name'),
                      controller: name,
                      enabled: !saving,
                      maxLength: 40,
                      decoration: InputDecoration(
                        labelText: '顯示名稱',
                        helperText: _suggesting
                            ? profileNameSuggestionHelper
                            : _blankPrivate
                            ? profileNameClearedHelper
                            : profileNameHelper,
                        helperMaxLines: 4,
                        border: const OutlineInputBorder(),
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

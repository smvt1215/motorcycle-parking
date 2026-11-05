import 'dart:async';

import '../../data/account_status.dart';
import '../../data/app_store.dart';
import '../../domain/account_display.dart';
import '../../domain/account_status_display.dart';
import '../account/suspended_sheet.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../data/profile_repository.dart';
import 'profile_avatar.dart';

Future<void> showProfileEditor(
  BuildContext context,
  AppStore store, {
  AccountStatusController? status,
}) => showAdaptiveSheet<void>(
  context,
  (_) => ProfileEditor(store: store, status: status),
);

/// 編輯個人資料 (P12): the editor changes the name and can remove the
/// sign-in provider's picture. Avatar uploads were cancelled (2026-11-01);
/// the avatar is the name's first character or the provider's picture.
class ProfileEditor extends StatefulWidget {
  const ProfileEditor({super.key, required this.store, this.status});
  final AppStore store;

  /// While it says the account is suspended (#331 ④), the name is read
  /// only and nothing can be saved.
  final AccountStatusController? status;
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

  AccountStatus? get suspension => widget.status?.suspension;

  void _statusChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.status?.addListener(_statusChanged);
    // Read on opening: a suspension makes the name read only (④).
    if (widget.status case final status?) unawaited(status.refresh());
  }

  @override
  void dispose() {
    widget.status?.removeListener(_statusChanged);
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
      // The status was unknown on opening: the shared panel (#331).
      if (accountSuspendedFrom(e) case final suspended?) {
        unawaited(widget.status?.refresh());
        if (!mounted) return;
        // The profile kept its old values: show them again.
        setState(() {
          name.text = profileDisplayName(user) ?? '';
          remove = false;
        });
        await showSuspendedSheet(context, suspended.until);
        return;
      }
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
      onPressed: saving || !changed || suspension != null ? null : save,
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
                    if (!remove && profileAvatarUrl(user) != null) ...[
                      Center(
                        child: TextButton(
                          key: const ValueKey('profile-remove-avatar'),
                          onPressed: saving || suspension != null
                              ? null
                              : () => setState(() => remove = true),
                          child: const Text(profileRemoveAvatar),
                        ),
                      ),
                      Text(
                        profileRemoveAvatarHint,
                        textAlign: TextAlign.center,
                        style: quiet,
                      ),
                    ],
                    const SizedBox(height: 20),
                    TextFormField(
                      key: const ValueKey('profile-name'),
                      controller: name,
                      enabled: !saving && suspension == null,
                      maxLength: 40,
                      decoration: InputDecoration(
                        labelText: '顯示名稱',
                        helperText: suspension == null
                            ? profileNameHelper
                            : null,
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) => profileNameError(value ?? ''),
                      onChanged: (_) => setState(() {}),
                    ),
                    if (suspension case final suspension?)
                      Column(
                        key: const ValueKey('profile-suspended'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            suspendedNameNote(suspension.until),
                            style: quiet,
                          ),
                          const SuspendedContactLink(
                            label: suspendedContactShort,
                          ),
                        ],
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

import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' as cu;

import '../../data/account_deletion.dart';
import '../../data/app_store.dart';
import '../../domain/account_deletion_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/sign_in.dart';

/// The platform's destructive color: iOS system red (accessible variant),
/// the theme's error color elsewhere.
Color destructiveColor(BuildContext context) => isCupertino
    ? (Theme.of(context).brightness == Brightness.dark
          ? const Color(0xffff6961)
          : const Color(0xffd70015))
    : Theme.of(context).colorScheme.error;

/// Pushes the deletion explanation (P15a ②) over the app.
Future<void> openAccountDeletion(
  BuildContext context, {
  required AppStore store,
  required AccountDeletionController deletion,
}) => Navigator.of(context, rootNavigator: true).push(
  isCupertino
      ? cu.CupertinoPageRoute<void>(
          builder: (_) => AccountDeletionPage(store: store, deletion: deletion),
        )
      : MaterialPageRoute<void>(
          builder: (_) => AccountDeletionPage(store: store, deletion: deletion),
        ),
);

/// 刪除帳號 (P15a): what is deleted, what stays anonymous, then the request.
class AccountDeletionPage extends StatefulWidget {
  const AccountDeletionPage({
    super.key,
    required this.store,
    required this.deletion,
  });
  final AppStore store;
  final AccountDeletionController deletion;

  @override
  State<AccountDeletionPage> createState() => _AccountDeletionPageState();
}

class _AccountDeletionPageState extends State<AccountDeletionPage> {
  late final DeletionAttempt attempt = widget.deletion.attempt();
  bool sending = false;

  /// From `account_deletion_status()`: false for admins (P15c ①). Until it
  /// answers, or if it cannot, the button stays: the request itself is
  /// refused for admins.
  bool canSelfDelete = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStatus());
  }

  Future<void> _loadStatus() async {
    final AccountDeletionState state;
    try {
      state = await widget.deletion.gateway!.status();
    } catch (_) {
      return;
    }
    if (!mounted || state.canSelfDelete) return;
    setState(() => canSelfDelete = false);
    await _showAdmin();
  }

  Future<void> _start() async {
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => _DeletionDialog<bool>(
        key: const ValueKey('deletion-confirm'),
        icon: Icons.delete_forever_outlined,
        title: deletionConfirmTitle,
        body: deletionConfirmBody,
        actions: [
          (deletionConfirmCancel, false, false),
          (deletionConfirmAction, true, true),
        ],
      ),
    );
    if (confirmed == true && mounted) await _run();
  }

  /// Re-sign-in when needed, then the request; retries the request on a
  /// network failure and asks for a sign-in again when the backend does.
  Future<void> _run() async {
    setState(() => sending = true);
    try {
      await widget.deletion.guard(() async {
        while (mounted) {
          if (attempt.needsReauth && !await _reauth()) return;
          try {
            final state = await attempt.submit();
            await _finish(state);
            return;
          } on ReauthRequired {
            continue;
          } on DeletionNetworkError {
            if (!await _askRetry()) return;
          } on AdminCannotDelete {
            if (mounted) setState(() => canSelfDelete = false);
            await _showAdmin();
            return;
          } on SignInRequired {
            await _toSignIn();
            return;
          } on DeletionFailure {
            await _showGeneric();
            return;
          }
        }
      });
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<bool> _reauth() async {
    if (!mounted) return false;
    final me = widget.deletion.gateway!.current;
    if (me == null) {
      await _toSignIn();
      return false;
    }
    final result = await showAdaptiveSheet<_ReauthResult>(
      context,
      (_) => _ReauthSheet(attempt: attempt, identity: me),
    );
    if (result == _ReauthResult.signInRequired) await _toSignIn();
    return result == _ReauthResult.signedIn;
  }

  /// Leaves for the signed-out notice (P15b ①): this phone signs out (the
  /// server already signed every device out) and the parking record goes.
  Future<void> _finish(AccountDeletionState state) async {
    final deletion = widget.deletion;
    if (mounted) {
      Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    }
    await deletion.completeRequest(
      state,
      appleRevokeFailed: attempt.appleRevokeFailed,
    );
  }

  /// 401 `auth.sign_in_required`: the session is gone; sign in again (P11).
  Future<void> _toSignIn() async {
    final store = widget.store;
    final navigator = Navigator.of(context, rootNavigator: true);
    await widget.deletion.gateway?.signOutLocal();
    navigator.popUntil((r) => r.isFirst);
    if (navigator.mounted) await showSignIn(navigator.context, store);
  }

  Future<bool> _askRetry() async {
    if (!mounted) return false;
    final retry = await showAdaptiveDialog<bool>(
      context: context,
      builder: (_) => const _DeletionDialog<bool>(
        key: ValueKey('deletion-network'),
        icon: Icons.wifi_off,
        title: networkFailedTitle,
        body: networkFailedBody,
        actions: [
          (deletionConfirmCancel, false, false),
          (networkRetry, true, false),
        ],
      ),
    );
    return retry == true;
  }

  Future<void> _showAdmin() async {
    if (!mounted) return;
    await showAdaptiveDialog<void>(
      context: context,
      builder: (_) => const _DeletionDialog<void>(
        key: ValueKey('deletion-admin'),
        icon: Icons.admin_panel_settings_outlined,
        title: adminCannotDeleteTitle,
        body: adminCannotDeleteBody,
        actions: [(dialogOk, null, false)],
      ),
    );
  }

  Future<void> _showGeneric() async {
    if (!mounted) return;
    await showAdaptiveDialog<void>(
      context: context,
      builder: (_) => const _DeletionDialog<void>(
        key: ValueKey('deletion-error'),
        icon: Icons.error_outline,
        title: genericErrorTitle,
        body: genericErrorBody,
        actions: [(dialogOk, null, false)],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.bodyMedium?.copyWith(color: colors.onSurfaceVariant);
    final body = ListView(
      key: const ValueKey('deletion-scroll'),
      padding: EdgeInsets.fromLTRB(
        16,
        12,
        16,
        32 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        Text(deletionIntro, style: muted),
        _Section(
          title: deletionCoolingOffHeading,
          rows: [
            for (final (i, (title, detail)) in deletionCoolingOff.indexed)
              _Row(
                icon: const [
                  Icons.schedule,
                  Icons.visibility_off_outlined,
                  Icons.logout,
                ][i],
                title: title,
                detail: detail,
              ),
          ],
        ),
        _Section(
          title: deletionDeletedHeading,
          rows: [
            for (final item in deletionDeleted)
              _Row(icon: Icons.delete_outline, title: item),
          ],
        ),
        _Section(
          title: deletionKeptHeading,
          rows: [
            for (final item in deletionKept)
              _Row(icon: Icons.person_off_outlined, title: item),
          ],
          note: deletionKeptNote,
        ),
        const _Section(
          title: deletionHashHeading,
          rows: [
            _Row(
              icon: Icons.fingerprint,
              title: deletionHashTitle,
              detail: deletionHashDetail,
            ),
          ],
        ),
        const SizedBox(height: 24),
        if (canSelfDelete) ...[
          _DangerButton(
            key: const ValueKey('deletion-submit'),
            label: sending ? deletionSending : deletionButton,
            onPressed: sending ? null : () => unawaited(_start()),
          ),
          const SizedBox(height: 8),
          Text(deletionReauthNote, style: muted, textAlign: TextAlign.center),
        ] else
          _Notice(
            key: const ValueKey('deletion-admin-note'),
            icon: Icons.admin_panel_settings_outlined,
            title: adminCannotDeleteTitle,
            body: adminCannotDeleteBody,
          ),
      ],
    );
    return Scaffold(
      appBar: isCupertino
          ? cu.CupertinoNavigationBar(
              previousPageTitle: '帳號與設定',
              middle: const Text(deletionButton),
              backgroundColor: colors.surface.withValues(alpha: .9),
            )
          : AppBar(title: const Text(deletionButton)),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.rows, this.note});
  final String title;
  final List<Widget> rows;
  final String? note;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: isCupertino
                  ? text.bodySmall?.copyWith(color: colors.onSurfaceVariant)
                  : text.titleSmall?.copyWith(color: colors.primary),
            ),
          ),
          const SizedBox(height: 6),
          Material(
            color: isCupertino
                ? colors.surfaceContainerHigh
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(children: rows),
          ),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(
              note!,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.detail});
  final IconData icon;
  final String title;
  final String? detail;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: isCupertino ? 14 : 0,
            vertical: 8,
          ),
          child: Row(
            children: [
              Icon(icon, color: colors.onSurfaceVariant),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.bodyLarge),
                    if (detail != null)
                      Text(
                        detail!,
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
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

/// iOS: a grouped row in system red; Android: a filled error button.
class _DangerButton extends StatelessWidget {
  const _DangerButton({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final danger = destructiveColor(context);
    if (isCupertino) {
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: onPressed == null
                      ? danger.withValues(alpha: .5)
                      : danger,
                ),
              ),
            ),
          ),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: danger,
        foregroundColor: Theme.of(context).colorScheme.onError,
        minimumSize: const Size.fromHeight(56),
      ),
      icon: const Icon(Icons.delete_forever_outlined),
      label: Text(label),
    );
  }
}

/// An inline notice card (the admin explanation without a button).
class _Notice extends StatelessWidget {
  const _Notice({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });
  final IconData icon;
  final String title, body;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      container: true,
      child: Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(body, style: text.bodyMedium),
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

/// An alert in the platform's style. Each action is (label, value popped,
/// destructive); Android shows [icon] above the title, as M3 does.
class _DeletionDialog<T> extends StatelessWidget {
  const _DeletionDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.actions,
  });
  final IconData icon;
  final String title, body;
  final List<(String, T?, bool)> actions;
  @override
  Widget build(BuildContext context) {
    final danger = destructiveColor(context);
    if (isCupertino) {
      return cu.CupertinoAlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          for (final (i, (label, value, destructive)) in actions.indexed)
            cu.CupertinoDialogAction(
              isDefaultAction: i == actions.length - 1 && !destructive,
              isDestructiveAction: destructive,
              onPressed: () => Navigator.pop(context, value),
              child: Text(label),
            ),
        ],
      );
    }
    return AlertDialog(
      icon: Icon(icon, color: actions.any((a) => a.$3) ? danger : null),
      title: Text(title),
      content: Text(body),
      actions: [
        for (final (label, value, destructive) in actions)
          TextButton(
            style: destructive
                ? TextButton.styleFrom(foregroundColor: danger)
                : null,
            onPressed: () => Navigator.pop(context, value),
            child: Text(label),
          ),
      ],
    );
  }
}

/// Shows an alert in the deletion dialogs' style; for the status pages.
Future<T?> showDeletionDialog<T>(
  BuildContext context, {
  Key? key,
  required IconData icon,
  required String title,
  required String body,
  required List<(String, T?, bool)> actions,
  bool dismissible = true,
}) => showAdaptiveDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  builder: (_) => PopScope(
    canPop: dismissible,
    child: _DeletionDialog<T>(
      key: key,
      icon: icon,
      title: title,
      body: body,
      actions: actions,
    ),
  ),
);

enum _ReauthResult { signedIn, signInRequired }

/// 再登入一次 (P15a ④⑤, P15c ③④): the rider's own provider only; the
/// request goes out as soon as the same rider is back.
class _ReauthSheet extends StatefulWidget {
  const _ReauthSheet({required this.attempt, required this.identity});
  final DeletionAttempt attempt;
  final AccountIdentity identity;
  @override
  State<_ReauthSheet> createState() => _ReauthSheetState();
}

class _ReauthSheetState extends State<_ReauthSheet> {
  bool busy = false;
  String? error;

  Future<void> _signIn() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.attempt.reauthenticate();
      if (mounted) Navigator.pop(context, _ReauthResult.signedIn);
      return;
    } on WrongAccount catch (e) {
      error = reauthWrongAccount(e.email);
    } on SignInRequired {
      if (mounted) Navigator.pop(context, _ReauthResult.signInRequired);
      return;
    } catch (_) {
      error = reauthIncomplete;
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final me = widget.identity;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final name = me.name ?? me.email ?? '';
    return ContentPage(
      children: [
        SheetTitle(reauthTitle),
        Text(me.apple ? reauthBodyApple : reauthBody, style: text.bodyMedium),
        if (error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Container(
              key: const ValueKey('reauth-error'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error, color: colors.onErrorContainer, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      error!,
                      style: text.bodyMedium?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: Text(name.isEmpty ? '?' : name.characters.first),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (me.name != null)
                      Text(
                        me.name!,
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(
                      reauthAccountLine(email: me.email, apple: me.apple),
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        AdaptiveButton(
          key: const ValueKey('reauth-sign-in'),
          label: reauthButton(apple: me.apple),
          secondary: true,
          onPressed: busy ? null : () => unawaited(_signIn()),
        ),
        if (!isCupertino) ...[
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(reauthCancel),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          reauthFootnote,
          textAlign: isCupertino ? TextAlign.start : TextAlign.center,
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

import 'dart:async';

import '../../data/account_deletion.dart';
import '../../data/app_store.dart';
import '../../domain/account_deletion_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/sign_in.dart';
import 'account_deletion_page.dart';

/// Where the router shows P15b ② and ①.
const pendingDeletionPath = '/account-deletion/pending';
const deletionNoticePath = '/account-deletion/requested';

/// The redirect that keeps a pending choice (②) and the signed-out notice
/// (①) in front of every other route; null leaves [path] as it is.
String? accountDeletionRedirect(
  AccountDeletionController deletion,
  String path,
) {
  if (deletion.pending != null) {
    return path == pendingDeletionPath ? null : pendingDeletionPath;
  }
  if (deletion.notice != null) {
    return path == deletionNoticePath ? null : deletionNoticePath;
  }
  if (path == pendingDeletionPath || path == deletionNoticePath) return '/map';
  return null;
}

/// Full screen, centered and phone-width on tablets, actions at the bottom.
class _StatusLayout extends StatelessWidget {
  const _StatusLayout({
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.content,
    required this.actions,
  });
  final IconData icon;
  final Color iconColor, iconBackground;
  final String title;
  final List<Widget> content, actions;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(24, 48, 24, 16),
                    children: [
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Container(
                          width: 68,
                          height: 68,
                          decoration: BoxDecoration(
                            color: iconBackground,
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(icon, color: iconColor, size: 36),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: text.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...content,
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: actions,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoRows extends StatelessWidget {
  const _InfoRows(this.rows);
  final List<(IconData, String, String?)> rows;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (i, (icon, title, detail)) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, color: colors.outlineVariant),
            MergeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, color: colors.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: text.bodyLarge),
                            if (detail != null)
                              Text(
                                detail,
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
            ),
          ],
        ],
      ),
    );
  }
}

/// P15b ①: the request went through (here or elsewhere) and this phone is
/// signed out. 完成 returns to the map; 登入以取消刪除 opens P11, after
/// which the pending choice (②) comes first.
class DeletionNoticePage extends StatelessWidget {
  const DeletionNoticePage({
    super.key,
    required this.deletion,
    required this.store,
  });
  final AccountDeletionController deletion;
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final notice = deletion.notice;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) deletion.dismissNotice();
      },
      child: _StatusLayout(
        icon: Icons.event_busy,
        iconColor: Colors.white,
        iconBackground: brand,
        title: requestedTitle,
        content: [
          Text(
            scheduledLine(notice?.scheduledAt),
            key: const ValueKey('deletion-scheduled'),
            style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          _InfoRows([
            (Icons.login, requestedRows[0], null),
            (Icons.visibility_off_outlined, requestedRows[1], null),
            (Icons.logout, requestedRows[2], null),
          ]),
          if (notice?.appleRevokeFailed ?? false) ...[
            const SizedBox(height: 16),
            Semantics(
              container: true,
              child: Container(
                key: const ValueKey('apple-revoke-failed'),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.tertiaryContainer,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info, color: colors.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            appleRevokeFailedTitle,
                            style: text.titleSmall?.copyWith(
                              color: colors.onTertiaryContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            appleRevokeFailedBody,
                            style: text.bodySmall?.copyWith(
                              color: colors.onTertiaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
        actions: [
          AdaptiveButton(
            key: const ValueKey('deletion-notice-done'),
            label: requestedDone,
            onPressed: deletion.dismissNotice,
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('deletion-notice-sign-in'),
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => unawaited(showSignIn(context, store)),
            child: const Text(requestedSignIn),
          ),
        ],
      ),
    );
  }
}

/// P15b ②: signed in during the cooling-off period. The rider must choose
/// before using the app; neither a back gesture nor a swipe closes it.
class PendingDeletionPage extends StatefulWidget {
  const PendingDeletionPage({super.key, required this.deletion});
  final AccountDeletionController deletion;
  @override
  State<PendingDeletionPage> createState() => _PendingDeletionPageState();
}

class _PendingDeletionPageState extends State<PendingDeletionPage> {
  bool busy = false;

  Future<void> _cancel() async {
    setState(() => busy = true);
    try {
      await widget.deletion.cancelPending();
    } on DeletionInProgress {
      if (!mounted) return;
      await showDeletionDialog<void>(
        context,
        key: const ValueKey('deletion-in-progress'),
        icon: Icons.hourglass_top,
        title: inProgressTitle,
        body: inProgressBody,
        actions: [(dialogOk, null, false)],
        dismissible: false,
      );
      await widget.deletion.acknowledgeInProgress();
    } on SignInRequired {
      await widget.deletion.acknowledgeInProgress();
    } on DeletionNetworkError {
      if (mounted) showMessage(context, networkFailedBody);
    } catch (_) {
      if (mounted) showMessage(context, genericErrorBody);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _continue() async {
    setState(() => busy = true);
    try {
      await widget.deletion.continuePending();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheduledAt = widget.deletion.pending?.scheduledAt;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final danger = destructiveColor(context);
    return PopScope(
      canPop: false,
      child: _StatusLayout(
        icon: Icons.schedule,
        iconColor: danger,
        iconBackground: colors.errorContainer,
        title: pendingTitle,
        content: [
          Text(
            scheduledLine(scheduledAt),
            key: const ValueKey('pending-scheduled'),
            style: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Text(pendingBody, style: text.bodyLarge),
          const SizedBox(height: 16),
          _InfoRows([
            (Icons.undo, pendingCancel, pendingCancelDetail),
            (Icons.logout, pendingContinue, pendingContinueDetail(scheduledAt)),
          ]),
        ],
        actions: [
          AdaptiveButton(
            key: const ValueKey('pending-cancel'),
            label: pendingCancel,
            onPressed: busy ? null : () => unawaited(_cancel()),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const ValueKey('pending-continue'),
            style: TextButton.styleFrom(
              foregroundColor: danger,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: busy ? null : () => unawaited(_continue()),
            child: const Text(pendingContinue),
          ),
          Text(
            pendingFootnote,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// P15b ③④ over the app: iOS a top banner, Android a snackbar above the
/// navigation bar; both close after 5 seconds or on their button.
class DeletionBannerOverlay extends StatefulWidget {
  const DeletionBannerOverlay({
    super.key,
    required this.deletion,
    required this.child,
  });
  final AccountDeletionController deletion;
  final Widget child;
  @override
  State<DeletionBannerOverlay> createState() => _DeletionBannerOverlayState();
}

class _DeletionBannerOverlayState extends State<DeletionBannerOverlay> {
  DeletionBanner? shown;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    widget.deletion.addListener(_changed);
  }

  @override
  void didUpdateWidget(DeletionBannerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deletion != widget.deletion) {
      oldWidget.deletion.removeListener(_changed);
      widget.deletion.addListener(_changed);
    }
  }

  void _changed() {
    final banner = widget.deletion.banner;
    if (banner == shown) return;
    timer?.cancel();
    setState(() => shown = banner);
    if (banner != null) {
      timer = Timer(const Duration(seconds: 5), widget.deletion.dismissBanner);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.deletion.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final banner = shown;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (banner != null)
          isCupertino
              ? Positioned(
                  left: 16,
                  right: 16,
                  top: 0,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 56),
                      child: _IosBanner(
                        banner: banner,
                        onClose: widget.deletion.dismissBanner,
                      ),
                    ),
                  ),
                )
              : Positioned(
                  left: 16,
                  right: 16,
                  // Above the navigation bar.
                  bottom: 96,
                  child: SafeArea(
                    top: false,
                    child: _AndroidSnackbar(
                      banner: banner,
                      onClose: widget.deletion.dismissBanner,
                    ),
                  ),
                ),
      ],
    );
  }
}

class _IosBanner extends StatelessWidget {
  const _IosBanner({required this.banner, required this.onClose});
  final DeletionBanner banner;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Semantics(
          liveRegion: true,
          child: Material(
            key: const ValueKey('deletion-banner'),
            color: colors.surfaceContainerLowest,
            elevation: 6,
            borderRadius: BorderRadius.circular(18),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    banner.continued ? Icons.logout : Icons.check_circle,
                    color: banner.continued ? colors.onSurface : brand,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          banner.continued
                              ? continuedTitle
                              : cancelledBannerTitle,
                          style: text.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          banner.continued
                              ? scheduledLine(banner.scheduledAt)
                              : cancelledBannerBody,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // No tooltip: the banner sits above the navigator's
                  // overlay.
                  Semantics(
                    label: '關閉',
                    button: true,
                    child: IconButton(
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AndroidSnackbar extends StatelessWidget {
  const _AndroidSnackbar({required this.banner, required this.onClose});
  final DeletionBanner banner;
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Semantics(
          liveRegion: true,
          child: Material(
            key: const ValueKey('deletion-banner'),
            color: colors.inverseSurface,
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      banner.continued ? continuedTitle : cancelledSnackbar,
                      style: text.bodyMedium?.copyWith(
                        color: colors.onInverseSurface,
                      ),
                    ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: colors.inversePrimary,
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: onClose,
                    child: const Text(bannerDismiss),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

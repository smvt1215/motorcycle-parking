import 'package:url_launcher/url_launcher.dart';

import '../../domain/account_status_display.dart';
import '../../ui/adaptive/adaptive.dart';

/// The amber of the suspension notices (P18a): fixed tones, a darker fill
/// in dark mode, as the closure card does.
Color suspendedTone(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xfff2c46d)
    : const Color(0xff865500);

Color suspendedFill(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff3a2f1c)
    : const Color(0xfffbf3e4);

/// The shared panel (P18a ① ②) for a write refused because the account is
/// suspended: over the form, which keeps what was filled in; 知道了 returns
/// to it. Does not say why the account was suspended. Without
/// [untilKnown] the line saying when it ends is left out.
Future<void> showSuspendedSheet(
  BuildContext context,
  DateTime? until, {
  bool untilKnown = true,
}) => showAdaptiveSheet<void>(
  context,
  (_) => SuspendedPanel(until: until, untilKnown: untilKnown),
);

class SuspendedPanel extends StatelessWidget {
  const SuspendedPanel({
    super.key,
    required this.until,
    this.untilKnown = true,
  });

  /// When it ends; null is until further notice.
  final DateTime? until;

  /// False when when it ends is unknown: no date line at all, so it does
  /// not read as indefinite.
  final bool untilKnown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final title = isCupertino
        ? theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.headlineSmall;
    final body = theme.textTheme.bodyLarge?.copyWith(
      color: colors.onSurfaceVariant,
      height: 1.55,
    );
    return SingleChildScrollView(
      key: const ValueKey('suspended-panel'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: suspendedFill(context),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.pause_circle_outline,
                size: 30,
                color: suspendedTone(context),
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Read first: the title and when it ends.
          MergeSemantics(
            child: Semantics(
              liveRegion: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(suspendedTitle, style: title),
                  ),
                  if (untilKnown) ...[
                    const SizedBox(height: 14),
                    Text(
                      suspendedUntilSentence(until),
                      key: const ValueKey('suspended-until'),
                      style: body,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (!untilKnown) const SizedBox(height: 14),
          Text(suspendedStillAllowed, style: body),
          const SizedBox(height: 14),
          const Align(
            alignment: AlignmentDirectional.centerStart,
            child: SuspendedContactLink(label: suspendedContact),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: AdaptiveButton(
              key: const ValueKey('suspended-dismiss'),
              label: suspendedDismiss,
              onPressed: () => Navigator.pop(context),
            ),
          ),
        ],
      ),
    );
  }
}

/// 有疑問請聯絡我們／聯絡我們: the support page in the in-app browser, as
/// the policy links open.
class SuspendedContactLink extends StatelessWidget {
  const SuspendedContactLink({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    final target = isCupertino ? 44.0 : 48.0;
    void open() => runAction(context, () async {
      if (!await launchUrl(
        suspendedSupportUri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        throw StateError(suspendedContactFailed);
      }
    });
    return Semantics(
      link: true,
      label: label,
      onTap: open,
      excludeSemantics: true,
      child: TextButton(
        key: const ValueKey('suspended-contact'),
        onPressed: open,
        style: TextButton.styleFrom(
          minimumSize: Size(target, target),
          tapTargetSize: MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          foregroundColor: color,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.open_in_new, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

/// P10's standing card (P18a ③) under the account, while the account is
/// suspended.
class SuspendedNoticeCard extends StatelessWidget {
  const SuspendedNoticeCard({
    super.key,
    required this.until,
    required this.now,
  });
  final DateTime? until;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xfff6e3bd) : const Color(0xff4a3a06);
    final quiet = dark ? const Color(0xffe6d2a6) : const Color(0xff5c4710);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: const ValueKey('suspended-card'),
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 14, 4),
        decoration: BoxDecoration(
          color: suspendedFill(context),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.pause_circle, size: 22, color: suspendedTone(context)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suspendedCardTitle(until, now),
                    style: text.titleSmall?.copyWith(
                      color: ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    suspendedCardDetail,
                    style: text.bodySmall?.copyWith(color: quiet, height: 1.45),
                  ),
                  const SuspendedContactLink(label: suspendedContactShort),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

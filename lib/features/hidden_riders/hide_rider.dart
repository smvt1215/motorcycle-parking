import 'dart:async';

import '../../data/app_store.dart';
import '../../data/hidden_riders.dart';
import '../../domain/hidden_riders_display.dart';
import '../../ui/adaptive/adaptive.dart';

/// How long the undo toast stays; with a screen reader on it stays until
/// dismissed (P17a ③).
const undoToastDuration = Duration(seconds: 8);

/// P17a ②: asks before hiding. True when the rider pressed 隱藏.
Future<bool> confirmHideRider(BuildContext context, String name) async {
  final ok = await showAdaptiveDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog.adaptive(
      key: const ValueKey('hide-rider-confirm'),
      icon: isCupertino ? null : const Icon(Icons.visibility_off_outlined),
      title: const Text(hideRiderConfirmTitle),
      content: Text(hideRiderConfirmBody(name)),
      actions: [
        adaptiveDialogAction(
          ctx,
          label: hideRiderCancel,
          onPressed: () => Navigator.pop(ctx, false),
        ),
        adaptiveDialogAction(
          ctx,
          label: hideRiderConfirm,
          primary: true,
          onPressed: () => Navigator.pop(ctx, true),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Confirms, hides [handle], runs [onHidden] (closing the details) and
/// offers 復原. Returns whether the rider was hidden.
Future<bool> hideRider(
  BuildContext context,
  AppStore store, {
  required String handle,
  required String name,
  required String spotName,
  VoidCallback? onHidden,
}) async {
  if (!await confirmHideRider(context, name)) return false;
  if (!context.mounted) return false;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final media = MediaQuery.of(context);
  await store.hiddenRiders.hide(handle: handle, name: name, spotName: spotName);
  onHidden?.call();
  if (messenger != null) {
    showUndoToast(
      messenger,
      media,
      key: const ValueKey('hidden-toast'),
      icon: Icons.visibility_off_outlined,
      text: hiddenToast(name),
      onUndo: () => unawaited(store.hiddenRiders.unhide(handle)),
    );
    // The account may refuse the list past 500: say so once it answers;
    // the device keeps the rider hidden.
    final hidden = store.hiddenRiders;
    if (hidden.followsAccount) {
      unawaited(
        hidden.sync().then((_) {
          if (hidden.accountFull) {
            messenger
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text(hiddenRidersFull)));
          }
        }),
      );
    }
  }
  return true;
}

/// Unhides [handle] at once (no confirmation, P17c) and offers 復原.
Future<void> unhideRider(
  BuildContext context,
  HiddenRiders hidden,
  String handle,
) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final media = MediaQuery.of(context);
  final removed = await hidden.unhide(handle);
  if (removed == null || messenger == null) return;
  showUndoToast(
    messenger,
    media,
    key: const ValueKey('unhidden-toast'),
    icon: Icons.visibility_outlined,
    text: unhiddenToast(removed.name),
    onUndo: () => unawaited(hidden.restore(removed)),
  );
}

/// A floating toast with 復原 (P17a ③④, P17c ②): about 8 seconds, kept
/// while a screen reader runs. A long name or large text wraps to two
/// lines and moves 復原 below it. On a tablet it stays within the
/// details' width.
void showUndoToast(
  ScaffoldMessengerState messenger,
  MediaQueryData media, {
  required String text,
  required IconData icon,
  required VoidCallback onUndo,
  Key? key,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: key,
        behavior: SnackBarBehavior.floating,
        duration: undoToastDuration,
        persist: media.accessibleNavigation,
        width: media.size.width >= 680 ? 560 : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(isCupertino ? 22 : 8),
        ),
        content: _UndoToast(
          text: text,
          icon: icon,
          onUndo: () {
            messenger.hideCurrentSnackBar();
            onUndo();
          },
        ),
      ),
    );
}

class _UndoToast extends StatelessWidget {
  const _UndoToast({
    required this.text,
    required this.icon,
    required this.onUndo,
  });
  final String text;
  final IconData icon;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style =
        theme.snackBarTheme.contentTextStyle ??
        theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onInverseSurface,
        );
    final actionColor = theme.colorScheme.inversePrimary;
    final undo = TextButton(
      key: const ValueKey('undo-toast-action'),
      onPressed: onUndo,
      style: TextButton.styleFrom(
        foregroundColor: actionColor,
        minimumSize: Size(isCupertino ? 44 : 48, isCupertino ? 44 : 48),
      ),
      child: const Text(undoAction),
    );
    final label = Text(
      text,
      key: const ValueKey('undo-toast-text'),
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // One line when the text fits beside 復原; else 復原 moves down.
        final scaler = MediaQuery.textScalerOf(context);
        final painter = TextPainter(
          text: TextSpan(text: text, style: style),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        // Icon and gaps, then 復原: two characters and its padding.
        final undoWidth = (scaler.scale(14) * 2 + 24).clamp(48.0, 400.0);
        final room = constraints.maxWidth - 20 - 12 - 8 - undoWidth;
        final fits = !painter.didExceedMaxLines && painter.width <= room;
        painter.dispose();
        final iconWidget = Icon(icon, size: 20, color: style?.color);
        if (fits) {
          return Row(
            children: [
              iconWidget,
              const SizedBox(width: 12),
              Expanded(child: label),
              const SizedBox(width: 8),
              undo,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: iconWidget,
                ),
                const SizedBox(width: 12),
                Expanded(child: label),
              ],
            ),
            Align(alignment: AlignmentDirectional.centerEnd, child: undo),
          ],
        );
      },
    );
  }
}

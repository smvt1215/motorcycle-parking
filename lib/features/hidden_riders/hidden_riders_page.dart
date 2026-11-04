import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' as cu;

import '../../data/app_store.dart';
import '../../data/hidden_riders.dart';
import '../../domain/hidden_riders_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/sign_in.dart';
import 'hide_rider.dart';

/// Opens 已隱藏的車友 (P17c) over 帳號與設定.
Future<void> openHiddenRiders(BuildContext context, AppStore store) =>
    Navigator.of(context, rootNavigator: true).push(
      isCupertino
          ? cu.CupertinoPageRoute<void>(
              builder: (_) => HiddenRidersPage(store: store),
            )
          : MaterialPageRoute<void>(
              builder: (_) => HiddenRidersPage(store: store),
            ),
    );

/// 已隱藏的車友 (P17c): who is hidden on this device, newest first, each
/// with 解除隱藏; an empty state otherwise. Works signed out.
class HiddenRidersPage extends StatelessWidget {
  const HiddenRidersPage({super.key, required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hidden = store.hiddenRiders;
    final muted = text.bodyMedium?.copyWith(color: colors.onSurfaceVariant);
    return Scaffold(
      appBar: isCupertino
          ? cu.CupertinoNavigationBar(
              previousPageTitle: '帳號與設定',
              middle: const Text(hiddenRidersTitle),
              backgroundColor: colors.surface.withValues(alpha: .9),
            )
          : AppBar(title: const Text(hiddenRidersTitle)),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListenableBuilder(
              // The store too: signing in from the guest card swaps the
              // foot for the synced note.
              listenable: Listenable.merge([hidden, store]),
              builder: (context, _) {
                final riders = hidden.riders;
                return ListView(
                  key: const ValueKey('hidden-riders-list'),
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    32 + MediaQuery.paddingOf(context).bottom,
                  ),
                  children: [
                    Text(hiddenRidersIntro, style: muted),
                    const SizedBox(height: 16),
                    // The account refused the list past 500 (not drawn on
                    // the canvas): the device keeps it.
                    if (hidden.accountFull) ...[
                      Text(
                        hiddenRidersFull,
                        key: const ValueKey('hidden-riders-full'),
                        style: text.bodyMedium?.copyWith(color: colors.error),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (riders.isEmpty)
                      const _Empty()
                    else
                      Material(
                        color: colors.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(
                          isCupertino ? 12 : 16,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (final (i, rider) in riders.indexed) ...[
                              if (i > 0)
                                Divider(
                                  height: 1,
                                  indent: 16,
                                  color: colors.outlineVariant,
                                ),
                              _RiderRow(
                                key: ValueKey('hidden-rider-${rider.handle}'),
                                rider: rider,
                                onUnhide: () => unawaited(
                                  unhideRider(context, hidden, rider.handle),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),
                    if (store.riderId == null && !store.demo)
                      _GuestNote(store: store)
                    else
                      Text(
                        hiddenRidersFootnote,
                        key: const ValueKey('hidden-riders-footnote'),
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// P17c ④: signed out, the list stays on this device until sign-in.
class _GuestNote extends StatelessWidget {
  const _GuestNote({required this.store});
  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('hidden-riders-guest'),
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(isCupertino ? 12 : 16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, color: colors.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                hiddenRidersGuestNote,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('hidden-riders-sign-in'),
              onPressed: () => showSignIn(context, store),
              style: FilledButton.styleFrom(
                minimumSize: Size(isCupertino ? 44 : 48, isCupertino ? 44 : 48),
              ),
              child: const Text(hiddenRidersSignIn),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      key: const ValueKey('hidden-riders-empty'),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.visibility_outlined, size: 40, color: colors.outline),
          const SizedBox(height: 12),
          Text(
            hiddenRidersEmptyTitle,
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            hiddenRidersEmptyBody,
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _RiderRow extends StatelessWidget {
  const _RiderRow({super.key, required this.rider, required this.onUnhide});
  final HiddenRider rider;
  final VoidCallback onUnhide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final initial = hiddenRiderInitial(rider.name);
    // Never the rider's own picture: a grey letter or a generic person.
    final avatar = ExcludeSemantics(
      child: CircleAvatar(
        radius: 18,
        backgroundColor: colors.outline,
        foregroundColor: colors.surface,
        child: initial.isEmpty
            ? const Icon(Icons.person, size: 20)
            : Text(
                initial,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
      ),
    );
    final button = Semantics(
      button: true,
      label: unhideLabel(rider.name),
      excludeSemantics: true,
      child: OutlinedButton(
        key: ValueKey('unhide-${rider.handle}'),
        onPressed: onUnhide,
        style: OutlinedButton.styleFrom(
          minimumSize: Size(isCupertino ? 44 : 48, isCupertino ? 44 : 48),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: const Text(unhideRiderAction),
      ),
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          hiddenRiderTitle(rider),
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          hiddenRiderSubtitle(rider),
          style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Large text: the button moves under the name instead of
          // squeezing it.
          final stacked =
              MediaQuery.textScalerOf(context).scale(14) > 24 ||
              constraints.maxWidth < 280;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    avatar,
                    const SizedBox(width: 12),
                    Expanded(child: details),
                  ],
                ),
                const SizedBox(height: 8),
                Align(alignment: AlignmentDirectional.centerEnd, child: button),
              ],
            );
          }
          return Row(
            children: [
              avatar,
              const SizedBox(width: 12),
              Expanded(child: details),
              const SizedBox(width: 8),
              button,
            ],
          );
        },
      ),
    );
  }
}

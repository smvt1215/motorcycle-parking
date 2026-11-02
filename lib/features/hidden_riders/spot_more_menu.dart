import 'dart:async';

import '../../data/app_store.dart';
import '../../domain/hidden_riders_display.dart';
import '../../domain/spot_contributor.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../content_report/content_report.dart';
import 'hide_rider.dart';

enum _SpotAction { hide, unhide, report }

/// The ⋯ beside 資料來源 (P17a ①⑤, P17d ②): 隱藏這位車友 or 解除隱藏,
/// and 檢舉內容不當. Nothing for official spots or the rider's own.
/// [onClose] closes the details after hiding or after hiding from a
/// report's result.
class SpotMoreButton extends StatelessWidget {
  const SpotMoreButton({
    super.key,
    required this.store,
    required this.spot,
    required this.onClose,
  });
  final AppStore store;
  final ParkingSpot spot;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final menu = spotMenu(
      spot,
      store.hiddenRiders,
      handle: store.handleOf(spot),
    );
    if (!menu.show) return const SizedBox.shrink();
    final label = moreActionsLabel(byRider: menu.byRider);
    final colors = Theme.of(context).colorScheme;
    PopupMenuItem<_SpotAction> item(
      _SpotAction value,
      String text,
      IconData icon,
    ) => PopupMenuItem(
      key: ValueKey('spot-menu-${value.name}'),
      value: value,
      height: isCupertino ? 44 : 48,
      child: isCupertino
          ? Row(
              children: [
                Expanded(child: Text(text)),
                const SizedBox(width: 16),
                Icon(icon, size: 20),
              ],
            )
          : Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 12),
                Flexible(child: Text(text)),
              ],
            ),
    );
    return Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: PopupMenuButton<_SpotAction>(
        key: const ValueKey('spot-more'),
        tooltip: label,
        icon: Icon(isCupertino ? Icons.more_horiz : Icons.more_vert),
        iconColor: colors.primary,
        constraints: const BoxConstraints(minWidth: 200),
        style: IconButton.styleFrom(
          minimumSize: Size(isCupertino ? 44 : 48, isCupertino ? 44 : 48),
        ),
        onSelected: (action) => unawaited(_run(context, action)),
        itemBuilder: (ctx) => [
          if (isCupertino)
            PopupMenuItem<_SpotAction>(
              enabled: false,
              height: 32,
              child: Text(
                moreActionsTitle(byRider: menu.byRider),
                style: Theme.of(ctx).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          if (menu.hide)
            item(
              _SpotAction.hide,
              hideRiderAction,
              Icons.visibility_off_outlined,
            ),
          if (menu.unhide)
            item(
              _SpotAction.unhide,
              unhideRiderAction,
              Icons.visibility_outlined,
            ),
          item(_SpotAction.report, reportContentAction, Icons.flag_outlined),
        ],
      ),
    );
  }

  Future<void> _run(BuildContext context, _SpotAction action) async {
    final handle = store.handleOf(spot);
    switch (action) {
      case _SpotAction.hide:
        if (handle == null) return;
        await hideRider(
          context,
          store,
          handle: handle,
          name: publicRiderName(spot),
          spotName: spot.name,
          onHidden: onClose,
        );
      case _SpotAction.unhide:
        if (handle == null) return;
        await unhideRider(context, store.hiddenRiders, handle);
      case _SpotAction.report:
        if (await showContentReport(context, store, spot)) onClose();
    }
  }
}

/// Atop the details of a hidden rider's spot opened from 我的收藏 or
/// another list (P17d): it stays off the map unless unhidden here.
class HiddenSpotBanner extends StatelessWidget {
  const HiddenSpotBanner({super.key, required this.store, required this.spot});
  final AppStore store;
  final ParkingSpot spot;

  @override
  Widget build(BuildContext context) {
    final handle = store.handleOf(spot);
    if (handle == null || !store.riderHidden(spot)) {
      return const SizedBox.shrink();
    }
    final name = store.hiddenRiders.byHandle(handle)?.name ?? '';
    final shown = publicRiderName(spot).isNotEmpty
        ? publicRiderName(spot)
        : name;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        key: const ValueKey('hidden-spot-banner'),
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.visibility_off_outlined,
                    size: 20,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      hiddenSpotBanner(shown),
                      style: text.bodyMedium,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: UnhideButton(store: store, handle: handle, name: shown),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 解除隱藏, read with whom it unhides (P17c, P17d).
class UnhideButton extends StatelessWidget {
  const UnhideButton({
    super.key,
    required this.store,
    required this.handle,
    required this.name,
  });
  final AppStore store;
  final String handle;
  final String name;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: unhideLabel(name),
    excludeSemantics: true,
    child: OutlinedButton(
      key: ValueKey('unhide-$handle'),
      onPressed: () =>
          unawaited(unhideRider(context, store.hiddenRiders, handle)),
      style: OutlinedButton.styleFrom(
        minimumSize: Size(isCupertino ? 44 : 48, isCupertino ? 44 : 48),
        padding: const EdgeInsets.symmetric(horizontal: 14),
      ),
      child: const Text(unhideRiderAction),
    ),
  );
}

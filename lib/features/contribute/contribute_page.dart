import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../domain/contribution_display.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../map/space_type_sheet.dart';
import '../report/report_sheet.dart';
import '../auth/sign_in.dart';
import '../report/spot_suggestions.dart';
import 'my_contributions.dart';
import 'my_contributions_page.dart';

/// Nearby spots listed in the panel before "show all".
const _listed = 3;

class ContributePage extends ConsumerWidget {
  const ContributePage({super.key});

  /// Every spot in view, for when the panel's short list is not enough.
  void _pickSpot(BuildContext context, AppStore store) {
    final spots = store.spots;
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle(contributeFixTitle),
          const SizedBox(height: 8),
          const Text(contributeFixHint),
          const SizedBox(height: 16),
          for (final spot in spots)
            _SpotRow(
              spot: spot,
              onTap: () {
                Navigator.pop(ctx);
                showSpotSuggestions(context, store, spot);
              },
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  /// Where "nearby" is measured from: the device once located, else the
  /// map's centre.
  static (double, double) _origin(AppStore store) =>
      store.located ? (store.lat, store.lng) : (store.mapLat, store.mapLng);

  void _newSpot(BuildContext context, AppStore store) =>
      showReport(context, store, store.mapLat, store.mapLng, mapCenter: true);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final user = store.client?.auth.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    final (oLat, oLng) = _origin(store);
    double away(ParkingSpot s) => distanceMeters(oLat, oLng, s.lat, s.lng);
    final nearby = [...store.spots]..sort((a, b) => away(a).compareTo(away(b)));
    final quiet = text.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontSize: 13,
    );
    final panel = MapPanel(
      title: '貢獻',
      children: [
        // The account itself lives in the personal center; here only what
        // it means for contributing, when it limits anything.
        if (store.demo || !signedIn) ...[
          Material(
            color: colors.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              child: Row(
                children: [
                  Icon(
                    store.demo ? Icons.science_outlined : Icons.lock_outline,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      store.demo ? '範例模式：回報只用於功能測試。' : '登入後才能新增與修正停車資訊。',
                    ),
                  ),
                  if (!store.demo)
                    TextButton(
                      onPressed: () => showSignIn(context, store),
                      child: const Text('登入'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
        ],
        // iOS: the primary action heads the page; Android puts it in the
        // extended FAB below.
        if (isCupertino) ...[
          AdaptiveButton(
            key: const ValueKey('contribute-new-spot'),
            label: contributeNewSpot,
            icon: Icons.add_location_alt_outlined,
            onPressed: () => _newSpot(context, store),
          ),
          const SizedBox(height: 8),
          Text(
            contributeNewSpotHint,
            textAlign: TextAlign.center,
            style: quiet,
          ),
          const SizedBox(height: 24),
        ],
        _GroupHeader(contributeFixTitle),
        if (store.spots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('還沒有停車資料。回到探索移動地圖，或新增你找到的停車點。'),
          )
        else
          _Group(
            children: [
              for (final spot in nearby.take(_listed))
                _SpotRow(
                  spot: spot,
                  distance: store.located ? away(spot) : null,
                  onTap: () => showSpotSuggestions(context, store, spot),
                ),
            ],
          ),
        const SizedBox(height: 6),
        Text(contributeFixHint, style: quiet),
        if (store.spots.length > _listed)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
              ),
              onPressed: () => _pickSpot(context, store),
              child: Text(showAllSpots(store.spots.length)),
            ),
          ),
        const SizedBox(height: 24),
        MyContributionsSection(
          store: store,
          preview: 2,
          onShowAll: () => context.go(myContributionsPath),
        ),
        const SizedBox(height: 24),
        Text(contributeFootnote, style: quiet),
        // Room for the extended FAB over the last lines.
        if (!isCupertino) const SizedBox(height: 72),
      ],
    );
    if (isCupertino) return panel;
    return Stack(
      children: [
        panel,
        PositionedDirectional(
          end: 16,
          bottom: 16,
          child: SafeArea(
            top: false,
            child: M3EExtendedFab(
              key: const ValueKey('contribute-new-spot'),
              label: contributeNewSpot,
              icon: const Icon(Icons.add_location_alt_outlined),
              onPressed: () => _newSpot(context, store),
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 0, 16, 6),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isCupertino ? colors.onSurfaceVariant : colors.primary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// iOS inset grouped list; a plain list on Android.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!isCupertino) return Column(children: children);
    return Material(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0)
              Divider(height: 1, indent: 72, color: colors.outlineVariant),
            child,
          ],
        ],
      ),
    );
  }
}

/// One nearby spot: its ground marking, kind and distance, and 「修改」.
class _SpotRow extends StatelessWidget {
  const _SpotRow({required this.spot, required this.onTap, this.distance});
  final ParkingSpot spot;
  final double? distance;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final kind = spot.isFacility ? '路外停車場' : '路邊格位';
    final detail = [kind, if (distance case final d?) distanceText(d)];
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 8, 8, 8),
          child: Row(
            children: [
              ExcludeSemantics(
                child: GroundMarking(type: spot.spaceType, size: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      spot.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      detail.join('　'),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: onTap,
                child: Semantics(
                  label: '$editSpot${spot.name}',
                  excludeSemantics: true,
                  child: const Text(editSpot),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_store.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/map_legend.dart';
import '../map/spot_sheet.dart';

/// Every favorite, in the same rows as the personal center's preview; the
/// app bar already names the page.
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    return ContentPage(
      children: [
        if (store.favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              children: [
                Icon(Icons.bookmark_outline, size: 40, color: colors.primary),
                const SizedBox(height: 12),
                const Text('還沒有收藏。在地圖點選停車點，再按「收藏」。'),
              ],
            ),
          )
        else
          Text(
            '${store.favorites.length} 個停車點',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        const SizedBox(height: 8),
        for (final spot in store.favorites)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ExcludeSemantics(
              child: SizedBox.square(
                dimension: 40,
                child: SpotMarker(
                  look: markerLook(store.eligible(spot)),
                  badge: spaceBadge(spot),
                  size: 32,
                ),
              ),
            ),
            title: Text(
              spot.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${spot.city}${spot.district} · ${store.eligible(spot).label}',
            ),
            onTap: () => showSpot(context, store, spot),
            trailing: IconButton(
              tooltip: '取消收藏',
              icon: const Icon(Icons.bookmark),
              onPressed: () =>
                  runAction(context, () => store.toggleFavorite(spot)),
            ),
          ),
      ],
    );
  }
}

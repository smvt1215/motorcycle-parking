import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_store.dart';
import '../../domain/favorites_display.dart';
import '../../ui/adaptive/adaptive.dart';
import 'favorite_card.dart';

/// Every favourite (canvas v157 P6): nearest first, each with its four
/// signs; the app bar already names the page.
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final entries = favoritesByDistance(store);
    if (entries.isEmpty) {
      return ContentPage(
        children: [
          Padding(
            key: const ValueKey('favorites-empty'),
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Column(
              children: [
                Icon(
                  Icons.bookmark_add_outlined,
                  size: 40,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text(
                  favoritesEmptyTitle,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  favoritesEmptyBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                AdaptiveButton(
                  key: const ValueKey('favorites-explore'),
                  label: favoritesExplore,
                  secondary: true,
                  onPressed: () => context.go('/map'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ContentPage(
      children: [
        Text(
          favoritesCount(entries.length, byDistance: store.located),
          key: const ValueKey('favorites-count'),
          style: TextStyle(color: colors.primary),
        ),
        const SizedBox(height: 8),
        for (final e in entries)
          FavoriteCard(
            key: ValueKey('favorite-${e.spot.id}'),
            store: store,
            entry: e,
            detailed: true,
            padding: const EdgeInsets.symmetric(vertical: 10),
            trailing: UnfavoriteButton(store: store, spot: e.spot),
          ),
      ],
    );
  }
}

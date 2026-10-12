import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_store.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/spot_sheet.dart';

class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    return ContentPage(
      children: [
        Text('常去的停車點', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        if (store.favorites.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Text('還沒有收藏。在地圖點選停車點，再按「收藏」。'),
          ),
        for (final spot in store.favorites)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bookmark),
            title: Text(spot.name),
            subtitle: Text('${spot.feeNote}\n${store.eligible(spot).label}'),
            isThreeLine: true,
            onTap: () => showSpot(context, store, spot),
            trailing: IconButton(
              tooltip: '移除收藏',
              icon: const Icon(Icons.bookmark_remove_outlined),
              onPressed: () =>
                  runAction(context, () => store.toggleFavorite(spot)),
            ),
          ),
      ],
    );
  }
}

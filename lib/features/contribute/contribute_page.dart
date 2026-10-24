import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../map/map_legend.dart';
import '../report/report_sheet.dart';
import '../report/spot_suggestions.dart';

/// Spots listed in the panel before "show all".
const _listed = 8;

class ContributePage extends ConsumerWidget {
  const ContributePage({super.key});

  /// Every spot in view, for when the panel's short list is not enough.
  void _pickSpot(BuildContext context, AppStore store) {
    final spots = store.spots;
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle('修正現有資訊'),
          const SizedBox(height: 8),
          const Text('選擇目前地圖範圍內的停車點，修改資訊或回報已不存在。'),
          const SizedBox(height: 16),
          for (final spot in spots)
            _SpotRow(
              store: store,
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final user = store.client?.auth.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    return MapPanel(
      title: '貢獻',
      children: [
        // The account itself lives in the personal center; here only what
        // it means for contributing, when it limits anything.
        if (store.demo || !signedIn)
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
                      onPressed: () => showSettings(context, store),
                      child: const Text('登入'),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 20),
        // One way in for each kind of contribution. Editing a spot and
        // reporting it gone share the suggestion sheet, so they share the
        // list below rather than two buttons that did the same thing.
        Material(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Tooltip(
            message: '新增停車點',
            child: InkWell(
              onTap: () => showReport(
                context,
                store,
                store.mapLat,
                store.mapLng,
                mapCenter: true,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.add_location_alt_outlined,
                      size: 28,
                      color: colors.onPrimaryContainer,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '新增停車點',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(color: colors.onPrimaryContainer),
                          ),
                          Text(
                            '回報地圖上還沒有的停車點',
                            style: TextStyle(color: colors.onPrimaryContainer),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.onPrimaryContainer),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 32),
        Text(
          '修正現有資訊',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '選擇目前地圖範圍內的停車點，修改資訊或回報已不存在。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        if (store.spots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('還沒有停車資料。回到探索移動地圖，或新增你找到的停車點。'),
          ),
        for (final spot in store.spots.take(_listed))
          _SpotRow(
            store: store,
            spot: spot,
            onTap: () => showSpotSuggestions(context, store, spot),
          ),
        if (store.spots.length > _listed)
          TextButton(
            onPressed: () => _pickSpot(context, store),
            child: Text('查看全部 ${store.spots.length} 個停車點'),
          ),
        const SizedBox(height: 24),
        Text(
          '回報會先標示待確認；停車前仍請確認現場公告。',
          style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
        ),
      ],
    );
  }
}

class _SpotRow extends StatelessWidget {
  const _SpotRow({
    required this.store,
    required this.spot,
    required this.onTap,
  });
  final AppStore store;
  final ParkingSpot spot;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final eligibility = store.eligible(spot);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: ExcludeSemantics(
        child: SizedBox.square(
          dimension: 40,
          child: SpotMarker(
            look: markerLook(eligibility),
            badge: spaceBadge(spot),
            size: 32,
          ),
        ),
      ),
      title: Text(spot.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text('${spot.city}${spot.district} · ${eligibility.label}'),
      trailing: const Icon(Icons.edit_outlined),
      onTap: onTap,
    );
  }
}

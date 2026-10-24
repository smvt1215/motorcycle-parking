import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_store.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../map/map_legend.dart';
import '../map/spot_sheet.dart';
import '../report/report_sheet.dart';

/// Favorites shown here; the rest are one tap away on the favorites page.
const _favoritePreview = 3;

/// Where the bike is first (needed right away), then favorites, then the
/// rules. Each appears once: favorites have one section, not a list and a
/// separate shortcut.
class ParkingPage extends ConsumerWidget {
  const ParkingPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final favorites = store.favorites;
    return MapPanel(
      title: '個人中心',
      trailing: IconButton.filledTonal(
        tooltip: '設定與登入',
        onPressed: () => showSettings(context, store),
        icon: const Icon(Icons.person_outline),
      ),
      children: [
        _ParkedCard(store: store),
        const SizedBox(height: 28),
        _SectionHeader(
          title: '我的收藏',
          count: favorites.length,
          action: favorites.isEmpty
              ? null
              : TextButton(
                  key: const ValueKey('all-favorites'),
                  onPressed: () => context.go('/favorites'),
                  child: const Text('查看全部 ›'),
                ),
        ),
        const SizedBox(height: 4),
        if (favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                Icon(Icons.bookmark_outline, size: 32, color: colors.primary),
                const SizedBox(width: 16),
                const Expanded(child: Text('還沒有收藏。在地圖點選停車點，再按「收藏」。')),
              ],
            ),
          ),
        for (final spot in favorites.take(_favoritePreview))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: ExcludeSemantics(
              child: SizedBox.square(
                dimension: 40,
                child: SpotMarker(
                  look: markerLook(store.eligible(spot)),
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
            trailing: IconButton(
              tooltip: '取消收藏',
              icon: const Icon(Icons.bookmark),
              onPressed: () =>
                  runAction(context, () => store.toggleFavorite(spot)),
            ),
            onTap: () => showSpot(context, store, spot),
          ),
        const SizedBox(height: 24),
        const _SectionHeader(title: '更多'),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('停車規則'),
          subtitle: const Text('各縣市 × 普通機車／大型重機'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/rules'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.count, this.action});
  final String title;
  final int? count;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (count case final count? when count > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: colors.secondaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: TextStyle(color: colors.onSecondaryContainer),
            ),
          ),
        ],
        const Spacer(),
        ?action,
      ],
    );
  }
}

/// The parking record: a prompt to save one, or where the bike is and how
/// to get back to it.
class _ParkedCard extends StatelessWidget {
  const _ParkedCard({required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final parked = store.parked;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.two_wheeler, color: colors.primary),
                const SizedBox(width: 10),
                Text(
                  '我停哪裡',
                  style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '位置與備註只保存在這台裝置。',
              style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (parked == null) ...[
              const Text('停好車後，記錄位置、樓層與備註。'),
              const SizedBox(height: 16),
              AdaptiveButton(
                label: '記錄停車',
                icon: Icons.add_location_alt_outlined,
                onPressed: () => showParkingForm(context, store),
              ),
            ] else ...[
              Text(
                '已停車 ${parkedDuration(DateTime.now().difference(parked.at))}',
                key: const ValueKey('parked-duration'),
                style: text.headlineSmall,
              ),
              const SizedBox(height: 12),
              for (final (label, value) in [
                ('停車時間', _time(parked.at)),
                if (parked.floor.isNotEmpty) ('樓層', parked.floor),
                if (parked.note.isNotEmpty) ('備註', parked.note),
                if (parked.remindAt case final remind?) ('提醒', _time(remind)),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text('$label：$value'),
                ),
              const SizedBox(height: 16),
              AdaptiveButton(
                label: '導航回車旁',
                icon: Icons.navigation_outlined,
                onPressed: () => runAction(
                  context,
                  () => navigateTo(parked.lat, parked.lng),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: TextButton(
                  onPressed: () => runAction(context, store.clearParking),
                  child: const Text('已取車，清除紀錄'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _time(DateTime at) => at.toLocal().toString().substring(0, 16);
}

/// e.g. `5 分鐘`, `2 小時 5 分鐘`, `1 天 3 小時`.
String parkedDuration(Duration elapsed) {
  // A clock set back never shows a negative time; clamp before splitting,
  // since Dart's % turns -1 hour into 23.
  if (elapsed.isNegative) elapsed = Duration.zero;
  final days = elapsed.inDays,
      hours = elapsed.inHours % 24,
      minutes = elapsed.inMinutes % 60;
  if (days > 0) return hours > 0 ? '$days 天 $hours 小時' : '$days 天';
  if (hours > 0) return minutes > 0 ? '$hours 小時 $minutes 分鐘' : '$hours 小時';
  return '$minutes 分鐘';
}

import 'package:cupertino_ui/cupertino_ui.dart' as cu;
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
              '${spot.city}${spot.district} · ${store.eligibleLabel(spot)}',
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
        _MoreLinks(
          links: [
            (
              icon: Icons.fact_check_outlined,
              title: '停車規則',
              subtitle: '各縣市 × 普通機車／大型重機',
              onTap: () => context.go('/rules'),
            ),
            (
              icon: Icons.help_outline,
              title: '地圖怎麼看',
              subtitle: '標記顏色、空位數字與小圖示',
              onTap: () => showMapLegend(
                context,
                store.vehicle,
                availability: store.availabilitySource.enabled,
              ),
            ),
            (
              icon: Icons.settings_outlined,
              title: '帳號與設定',
              subtitle: '登入、關於、授權資訊',
              onTap: () => showSettings(context, store),
            ),
          ],
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

typedef _Link = ({
  IconData icon,
  String title,
  String subtitle,
  VoidCallback onTap,
});

/// The page's other destinations: an inset grouped list on iOS, a plain
/// Material list elsewhere.
class _MoreLinks extends StatelessWidget {
  const _MoreLinks({required this.links});
  final List<_Link> links;
  @override
  Widget build(BuildContext context) {
    if (isCupertino) {
      return cu.CupertinoListSection.insetGrouped(
        margin: EdgeInsets.zero,
        children: [
          for (final l in links)
            cu.CupertinoListTile.notched(
              leading: Icon(l.icon, color: brand),
              title: Text(l.title),
              subtitle: Text(l.subtitle),
              trailing: const cu.CupertinoListTileChevron(),
              onTap: l.onTap,
            ),
        ],
      );
    }
    return Column(
      children: [
        for (final l in links)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(l.icon),
            title: Text(l.title),
            subtitle: Text(l.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: l.onTap,
          ),
      ],
    );
  }
}

/// The parking record: a prompt to save one, or — on the inverse surface so
/// it stands out first — how long the bike has been parked and how to get
/// back to it.
class _ParkedCard extends StatelessWidget {
  const _ParkedCard({required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final parked = store.parked;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget header(Color fg, Color quiet) => Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            '我停哪裡',
            style: text.titleLarge?.copyWith(
              color: fg,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text('只存在這台裝置', style: text.bodySmall?.copyWith(color: quiet)),
      ],
    );
    if (parked == null) {
      return Material(
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(colors.onSurface, colors.onSurfaceVariant),
              const SizedBox(height: 8),
              const Text('停好車後，記錄位置、樓層或區域與備註。'),
              const SizedBox(height: 16),
              AdaptiveButton(
                label: '記錄停車',
                icon: Icons.add_location_alt_outlined,
                onPressed: () => showParkingForm(context, store),
              ),
            ],
          ),
        ),
      );
    }
    final fg = colors.onInverseSurface;
    final quiet = fg.withValues(alpha: .72);
    return Material(
      color: colors.inverseSurface,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(fg, quiet),
            const SizedBox(height: 12),
            Text('已停車', style: text.bodyMedium?.copyWith(color: quiet)),
            Text(
              parkedDuration(DateTime.now().difference(parked.at)),
              key: const ValueKey('parked-duration'),
              style: text.headlineMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            for (final (label, value) in [
              ('停車時間', _time(parked.at)),
              if (parked.floor.isNotEmpty) ('樓層或區域', parked.floor),
              if (parked.note.isNotEmpty) ('備註', parked.note),
              if (parked.remindAt case final remind?) ('提醒', _time(remind)),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(label, style: TextStyle(color: quiet)),
                    ),
                    Expanded(
                      child: Text(value, style: TextStyle(color: fg)),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _CardButton(
                  label: '導航回車旁',
                  icon: Icons.navigation_outlined,
                  filled: true,
                  onPressed: () => runAction(
                    context,
                    () => navigateTo(parked.lat, parked.lng),
                  ),
                ),
                _CardButton(
                  label: '已取車',
                  onPressed: () => runAction(context, store.clearParking),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _time(DateTime at) => at.toLocal().toString().substring(0, 16);
}

/// A button on the inverse surface: the filled one takes the light colour,
/// the other an outline in it.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.filled = false,
  });
  final String label;
  final VoidCallback onPressed;
  final IconData? icon;
  final bool filled;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final light = colors.onInverseSurface;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) ...[
          Icon(icon, size: 20),
          const SizedBox(width: 6),
        ],
        Text(label),
      ],
    );
    final minSize = Size(48, isCupertino ? 44 : 48);
    if (isCupertino) {
      return cu.CupertinoButton(
        minimumSize: minSize,
        color: filled ? light : null,
        foregroundColor: filled ? colors.inverseSurface : light,
        borderRadius: BorderRadius.circular(24),
        onPressed: onPressed,
        child: child,
      );
    }
    return filled
        ? FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: light,
              foregroundColor: colors.inverseSurface,
              minimumSize: minSize,
            ),
            onPressed: onPressed,
            child: child,
          )
        : OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: light,
              side: BorderSide(color: light.withValues(alpha: .6)),
              minimumSize: minSize,
            ),
            onPressed: onPressed,
            child: child,
          );
  }
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

import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_store.dart';
import '../../domain/favorites_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../auth/profile_avatar.dart';
import '../favorites/favorite_card.dart';
import '../map/map_legend.dart';
import '../report/report_sheet.dart';

/// Favorites shown here, nearest first; the rest are one tap away on the
/// favorites page (canvas v157 P4).
const _favoritePreview = 2;

/// Where the bike is first (needed right away), then favorites, then the
/// rules. Each appears once: favorites have one section, not a list and a
/// separate shortcut.
class ParkingPage extends ConsumerWidget {
  const ParkingPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final favorites = favoritesByDistance(store);
    final user = store.client?.auth.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    return MapPanel(
      title: '個人中心',
      trailing: IconButton(
        key: const ValueKey('account-avatar'),
        tooltip: accountSettingsLabel,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        onPressed: () => showSettings(context, store),
        icon: ProfileAvatar(user: signedIn ? user : null, size: 44),
      ),
      children: [
        _ParkedCard(store: store),
        const SizedBox(height: 24),
        Padding(
          padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 0, 0, 8),
          child: Text(
            favoritesTitle,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: isCupertino ? colors.onSurfaceVariant : colors.primary,
            ),
          ),
        ),
        if (favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              children: [
                Icon(Icons.bookmark_outline, size: 32, color: colors.primary),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text('$favoritesEmptyTitle。$favoritesEmptyBody'),
                ),
              ],
            ),
          )
        else ...[
          _FavoritePreview(
            store: store,
            entries: favorites.take(_favoritePreview).toList(),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _TextLink(
              key: const ValueKey('all-favorites'),
              label: showAllFavorites(favorites.length),
              onPressed: () => context.go('/favorites'),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _MoreLinks(
          links: [
            (
              icon: Icons.menu_book_outlined,
              title: '停車規則',
              subtitle: rulesLinkSubtitle(store.vehicle),
              onTap: () => context.go('/rules'),
            ),
            (
              icon: Icons.help_outline,
              title: '地圖怎麼看',
              subtitle: '標記顏色、空位數字與小圖示',
              onTap: () => openMapLegend(context, fromMap: false),
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

/// The nearest favourites as cards: one inset group on iOS (P4-ios), a
/// plain list on Android (P4-android).
class _FavoritePreview extends StatelessWidget {
  const _FavoritePreview({required this.store, required this.entries});
  final AppStore store;
  final List<FavoriteEntry> entries;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cards = [
      for (final (i, e) in entries.indexed) ...[
        if (i > 0 && isCupertino)
          Divider(height: 1, indent: 16, color: colors.outlineVariant),
        FavoriteCard(
          key: ValueKey('favorite-${e.spot.id}'),
          store: store,
          entry: e,
          padding: isCupertino
              ? const EdgeInsets.fromLTRB(16, 12, 16, 12)
              : const EdgeInsets.symmetric(vertical: 10),
        ),
      ],
    ];
    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: cards,
    );
    if (!isCupertino) return list;
    return Material(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: list,
    );
  }
}

/// A text link at least a touch target tall.
class _TextLink extends StatelessWidget {
  const _TextLink({super.key, required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final child = Text(label);
    if (isCupertino) {
      return cu.CupertinoButton(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        onPressed: onPressed,
        child: child,
      );
    }
    return TextButton(
      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: onPressed,
      child: child,
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

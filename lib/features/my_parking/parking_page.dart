import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../map/spot_sheet.dart';
import '../report/report_sheet.dart';

class ParkingPage extends ConsumerWidget {
  const ParkingPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider), parked = store.parked;
    final colors = Theme.of(context).colorScheme;
    return MapPanel(
      title: '個人中心',
      trailing: IconButton.filledTonal(
        tooltip: '設定與登入',
        onPressed: () => showSettings(context, store),
        icon: const Icon(Icons.person_outline),
      ),
      children: [
        Text(
          '已儲存的停車點',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '收藏你常去的地方，下次更快找到車位。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        if (store.favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              children: [
                Icon(Icons.bookmark_outline, size: 36, color: colors.primary),
                const SizedBox(width: 16),
                const Expanded(child: Text('還沒有收藏。找到停車點後，\n在詳情中按「收藏」即可儲存。')),
              ],
            ),
          ),
        for (final spot in store.favorites.take(3))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                Icons.local_parking,
                color: colors.onPrimaryContainer,
                size: 28,
              ),
            ),
            title: Text(
              spot.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${spot.city} · ${spot.spaceType.label}'),
            trailing: IconButton(
              tooltip: '取消收藏',
              icon: const Icon(Icons.bookmark),
              onPressed: () =>
                  runAction(context, () => store.toggleFavorite(spot)),
            ),
            onTap: () => showSpot(context, store, spot),
          ),
        const SizedBox(height: 16),
        TextButton(
          style: TextButton.styleFrom(
            backgroundColor: colors.surfaceContainerHigh,
            minimumSize: const Size(double.infinity, 52),
          ),
          onPressed: () => context.go('/favorites'),
          child: Text('查看全部收藏（${store.favorites.length}） ›'),
        ),
        const SizedBox(height: 32),
        Text(
          '你的停車工具',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bookmark_outline),
          title: const Text('我的收藏'),
          subtitle: Text('${store.favorites.length} 個停車點'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/favorites'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('停車規則'),
          subtitle: const Text('各縣市 × 普通機車／大型重機'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.go('/rules'),
        ),
        const Divider(height: 40),
        Text('記住我停哪裡', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 12),
        const Text('位置與備註只保存在這台裝置。'),
        const SizedBox(height: 24),
        if (parked == null) ...[
          const Icon(Icons.two_wheeler, size: 80),
          const SizedBox(height: 24),
          const Text('停好車後，記錄位置、樓層與備註。'),
          const SizedBox(height: 24),
          AdaptiveButton(
            label: '記錄停車',
            icon: Icons.add_location_alt_outlined,
            onPressed: () => showParkingForm(context, store),
          ),
        ] else ...[
          Text(
            '已停車 ${DateTime.now().difference(parked.at).inMinutes} 分鐘',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          Text('停車時間：${parked.at.toLocal().toString().substring(0, 16)}'),
          const SizedBox(height: 8),
          Text('樓層：${parked.floor.isEmpty ? '未填寫' : parked.floor}'),
          const SizedBox(height: 8),
          Text('備註：${parked.note.isEmpty ? '未填寫' : parked.note}'),
          const SizedBox(height: 8),
          Text(
            '${parked.lat.toStringAsFixed(5)}, ${parked.lng.toStringAsFixed(5)}',
          ),
          if (parked.remindAt != null)
            Text(
              '提醒時間：${parked.remindAt!.toLocal().toString().substring(0, 16)}',
            ),
          const SizedBox(height: 28),
          AdaptiveButton(
            label: '導航回車旁',
            icon: Icons.navigation_outlined,
            onPressed: () =>
                runAction(context, () => navigateTo(parked.lat, parked.lng)),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => runAction(context, store.clearParking),
            child: const Text('已取車，清除紀錄'),
          ),
        ],
      ],
    );
  }
}

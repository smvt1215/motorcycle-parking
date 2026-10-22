import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/map_panel.dart';
import '../map/spot_sheet.dart';
import '../report/report_sheet.dart';

class ContributePage extends ConsumerWidget {
  const ContributePage({super.key});

  void _pickSpot(BuildContext context, AppStore store, String title) {
    final spots = store.spots;
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          SheetTitle(title),
          const SizedBox(height: 8),
          const Text('選擇目前地圖範圍內的停車點，再依現場狀況補充資訊。'),
          const SizedBox(height: 16),
          if (spots.isEmpty) const Text('目前範圍尚無停車點，請移動地圖或新增回報。'),
          for (final spot in spots)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.local_parking_outlined),
              title: Text(spot.name),
              subtitle: Text('${spot.city} · ${spot.spaceType.label}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(ctx);
                showSpot(context, store, spot);
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
    final displayName =
        user?.userMetadata?['full_name'] as String? ??
        user?.userMetadata?['name'] as String? ??
        '一起讓停車資訊更準確';
    return MapPanel(
      title: '貢獻',
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colors.surfaceContainerLow,
                colors.primaryContainer.withValues(alpha: .55),
              ],
            ),
          ),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: colors.primaryContainer,
              child: Icon(
                Icons.person_outline,
                color: colors.onPrimaryContainer,
              ),
            ),
            title: Text(
              displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(
              store.demo
                  ? '範例模式 · 可試用回報流程'
                  : user == null || user.isAnonymous
                  ? '登入後可新增點位與提出修改建議'
                  : '分享現場資訊，幫助下一位騎士',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showSettings(context, store),
          ),
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ContributionAction(
              label: '新增停車點',
              icon: Icons.add_location_alt_outlined,
              onTap: () => showReport(
                context,
                store,
                store.mapLat,
                store.mapLng,
                mapCenter: true,
              ),
            ),
            _ContributionAction(
              label: '修改資訊',
              icon: Icons.fact_check_outlined,
              onTap: () => _pickSpot(context, store, '修改停車資訊'),
            ),
            _ContributionAction(
              label: '檢舉錯誤',
              icon: Icons.flag_outlined,
              onTap: () => _pickSpot(context, store, '檢舉停車資訊錯誤'),
            ),
          ],
        ),
        const SizedBox(height: 36),
        Text(
          '目前地圖範圍',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          '選擇停車點，提出修改建議或回報點位已不存在。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        if (store.spots.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('還沒有停車資料。回到探索移動地圖，或新增你找到的停車點。'),
          ),
        for (final spot in store.spots.take(8))
          ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 6),
            leading: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(Icons.local_parking, size: 28),
            ),
            title: Text(
              spot.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${spot.city} · ${store.eligible(spot).label}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => showSpot(context, store, spot),
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

class _ContributionAction extends StatelessWidget {
  const _ContributionAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      children: [
        IconButton.filledTonal(
          tooltip: label,
          onPressed: onTap,
          icon: Icon(icon, size: 28),
          style: IconButton.styleFrom(minimumSize: const Size(60, 60)),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );
}

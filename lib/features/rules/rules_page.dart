import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';

class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});
  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage> {
  String city = '臺北市';
  @override
  Widget build(BuildContext context) {
    final store = ref.watch(storeProvider);
    final rule = store.rules
        .where((r) => r.city == city && r.vehicle == store.vehicle)
        .firstOrNull;
    return ContentPage(
      children: [
        Text('停之前，先看規則', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text('各縣市的開放範圍與費率不同，請再確認現場公告。'),
        const SizedBox(height: 24),
        VehicleSelector(value: store.vehicle, onChanged: store.setVehicle),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          initialValue: city,
          decoration: const InputDecoration(
            labelText: '縣市',
            border: OutlineInputBorder(),
          ),
          items: store.rules
              .map((r) => r.city)
              .toSet()
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          onChanged: (c) {
            if (c != null) setState(() => city = c);
          },
        ),
        const SizedBox(height: 24),
        if (rule != null) ...[
          Text(
            '${rule.city} · ${store.vehicle.label}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: rule.allowedSpaceTypes
                .map(
                  (t) => Chip(
                    avatar: const Icon(Icons.check_circle_outline, size: 18),
                    label: Text(t.label),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 16),
          Text(rule.feeNote, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(rule.exceptions),
          const SizedBox(height: 16),
          Text(
            '規則生效／核對日期：${rule.effectiveDate.toIso8601String().substring(0, 10)} · 版本 ${rule.version}',
          ),
          TextButton.icon(
            onPressed: () => runAction(context, () async {
              if (!await launchUrl(
                Uri.parse(rule.sourceUrl),
                mode: LaunchMode.externalApplication,
              )) {
                throw StateError('無法開啟官方來源');
              }
            }),
            icon: const Icon(Icons.open_in_new),
            label: const Text('查看官方來源'),
          ),
        ],
        const Divider(height: 40),
        const Text('本指南僅供參考，不取代現場標誌、標線與管理單位公告。社群回報與剩餘格數可能有延遲，請確認車身完整位於允許的格線內。'),
      ],
    );
  }
}

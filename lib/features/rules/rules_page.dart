import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../domain/eligibility.dart';
import '../../domain/parking_decision.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/map_legend.dart';
import '../map/space_type_sheet.dart';

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
          const SizedBox(height: 12),
          for (final (look, types) in ruleGroups(rule, store.vehicle))
            _RuleGroup(look: look, types: types, rule: rule),
          const SizedBox(height: 8),
          Text(rule.exceptions),
          const SizedBox(height: 16),
          _RuleField(label: '收費', value: rule.feeNote),
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

/// Space types grouped as the map judges them: each type is run through
/// [eligibility] as a verified spot in the rule's city, so this page and the
/// markers never disagree.
List<(MarkerLook, List<SpaceType>)> ruleGroups(
  CityRule rule,
  VehicleType vehicle,
) {
  final groups = <MarkerLook, List<SpaceType>>{};
  for (final type in SpaceType.values) {
    final spot = ParkingSpot(
      id: 'rule',
      name: 'rule',
      lat: 0,
      lng: 0,
      city: rule.city,
      // A kind open in named districts is shown as it is there; its chip
      // names them.
      district: rule.districtSpaceTypes[ruleSpaceType(type)]?.first ?? '',
      spaceType: type,
      condition: typicalCondition(type),
      status: TrustStatus.confirmed,
      // A lot's own data decides; the rule alone never opens it.
      source: 'official',
    );
    final look = markerLook(eligibility(spot, vehicle, rule));
    (groups[look] ??= []).add(type);
  }
  return groups.entries.map((e) => (e.key, e.value)).toList()
    ..sort((a, b) => a.$1.$1.index - b.$1.$1.index);
}

class _RuleGroup extends StatelessWidget {
  const _RuleGroup({
    required this.look,
    required this.types,
    required this.rule,
  });
  final MarkerLook look;
  final List<SpaceType> types;
  final CityRule rule;
  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final label = Eligibility(look.$1, '', restriction: look.$2).label;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: SizedBox.square(
                  dimension: 26,
                  child: SpotMarker(look: look, size: 22),
                ),
              ),
              const SizedBox(width: 8),
              Text(label, style: text.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final type in types)
                Container(
                  padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ExcludeSemantics(
                        child: GroundMarking(type: type, size: 28),
                      ),
                      const SizedBox(width: 8),
                      Text(switch (rule.districtSpaceTypes[ruleSpaceType(
                        type,
                      )]) {
                        final districts? =>
                          '${type.label}（僅${districts.join('、')}）',
                        null => type.label,
                      }, style: text.bodyMedium),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RuleField extends StatelessWidget {
  const _RuleField({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 48,
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(child: Text(value)),
    ],
  );
}

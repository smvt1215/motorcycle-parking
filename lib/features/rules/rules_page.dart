import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/app_store.dart';
import '../../domain/eligibility.dart';
import '../../domain/rules_display.dart';
import '../../models/parking.dart';
import '../../models/zone_entries.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/map_legend.dart' show unverifiedColor;
import '../map/space_type_sheet.dart';

/// 停車規則 (P7): one row per bay kind, each with the verdict the map
/// gives it for the chosen city and vehicle.
class RulesPage extends ConsumerStatefulWidget {
  const RulesPage({super.key});
  @override
  ConsumerState<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends ConsumerState<RulesPage> {
  String city = '臺北市';

  Future<void> _pickCity(List<String> cities) => showAdaptiveSheet<void>(
    context,
    (ctx) => ContentPage(
      children: [
        SheetTitle('縣市'),
        const SizedBox(height: 8),
        for (final c in cities)
          ListTile(
            minTileHeight: 48,
            title: Text(c),
            selected: c == city,
            trailing: c == city ? const Icon(Icons.check) : null,
            onTap: () {
              setState(() => city = c);
              Navigator.pop(ctx);
            },
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final cities = store.rules.map((r) => r.city).toSet().toList();
    final rule = store.rules
        .where((r) => r.city == city && r.vehicle == store.vehicle)
        .firstOrNull;
    final quiet = text.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
      fontSize: 13,
    );
    return ContentPage(
      children: [
        Text(rulesIntro, style: text.bodyLarge),
        const SizedBox(height: 16),
        if (isCupertino) ...[
          Text('縣市', style: quiet),
          const SizedBox(height: 4),
          Semantics(
            button: true,
            label: '縣市：$city',
            excludeSemantics: true,
            onTap: () => _pickCity(cities),
            child: Material(
              color: colors.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const ValueKey('rules-city'),
                onTap: () => _pickCity(cities),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          city,
                          style: text.titleMedium?.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ),
                      Icon(Icons.unfold_more, color: colors.primary),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ] else
          DropdownButtonFormField<String>(
            key: const ValueKey('rules-city'),
            initialValue: city,
            decoration: const InputDecoration(
              labelText: '縣市',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final c in cities)
                DropdownMenuItem(value: c, child: Text(c)),
            ],
            onChanged: (c) {
              if (c != null) setState(() => city = c);
            },
          ),
        const SizedBox(height: 16),
        VehicleSelector(value: store.vehicle, onChanged: store.setVehicle),
        const SizedBox(height: 20),
        if (rule != null) ...[
          const _SectionHeader('哪些格位能停'),
          _Group(
            children: [
              for (final row in ruleRows(rule, store.vehicle))
                _RuleRowTile(row),
            ],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 6, 16, 0),
            child: Text(ruleCheckedLine(rule), style: quiet),
          ),
          const SizedBox(height: 20),
          _Group(
            children: [
              _LinkTile(
                icon: Icons.payments_outlined,
                title: '收費',
                subtitle: rule.feeNote,
              ),
              _LinkTile(
                icon: Icons.open_in_new,
                title: '查看官方來源',
                onTap: () => runAction(context, () async {
                  if (!await launchUrl(
                    Uri.parse(rule.sourceUrl),
                    mode: LaunchMode.externalApplication,
                  )) {
                    throw StateError('無法開啟官方來源');
                  }
                }),
              ),
            ],
          ),
        ] else
          Text(noRuleText(city, store.vehicle), style: quiet),
        const SizedBox(height: 20),
        Text(rulesDisclaimer, style: quiet),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);
  final String title;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 0, 16, 6),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: isCupertino ? colors.onSurfaceVariant : colors.primary,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

/// iOS inset grouped list; a plain list on Android.
class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!isCupertino) return Column(children: children);
    return Material(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (i, child) in children.indexed) ...[
            if (i > 0)
              Divider(height: 1, indent: 16, color: colors.outlineVariant),
            child,
          ],
        ],
      ),
    );
  }
}

Color rulePillColor(EligibilityStatus status) => switch (status) {
  EligibilityStatus.allowed => allowedColor,
  EligibilityStatus.conditional => conditionalColor,
  EligibilityStatus.unverified => unverifiedColor,
  EligibilityStatus.notAllowed => deniedColor,
};

/// The ground marking each kind is painted with.
Widget bayKindMarking(BayKind kind, {double size = 44}) => switch (kind) {
  BayKind.motorcycle => GroundMarking(
    type: SpaceType.freeMotorcycle,
    size: size,
  ),
  BayKind.scooterHeavy => GroundMarking(type: null, shared: true, size: size),
  BayKind.heavy => GroundMarking(type: SpaceType.heavyOnly, size: size),
  BayKind.carMotorcycle => GroundMarking(
    type: SpaceType.flexShared,
    size: size,
  ),
  BayKind.car => GroundMarking(type: SpaceType.car, size: size),
  BayKind.disabled => GroundMarking(
    type: SpaceType.disabledMotorcycle,
    size: size,
  ),
  BayKind.ev => GroundMarking(type: SpaceType.evMotorcycle, size: size),
};

class _RuleRowTile extends StatelessWidget {
  const _RuleRowTile(this.row);
  final RuleRow row;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return MergeSemantics(
      child: Padding(
        key: ValueKey('rule-${row.kind.wire}'),
        padding: EdgeInsets.symmetric(
          horizontal: isCupertino ? 16 : 0,
          vertical: 10,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(child: bayKindMarking(row.kind)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(row.label, style: text.titleMedium),
                      if (row.detail.isNotEmpty)
                        Text(
                          row.detail,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  constraints: const BoxConstraints(minWidth: 64),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: rulePillColor(row.status),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    row.pill,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (row.note.isNotEmpty)
              Padding(
                key: ValueKey('rule-note-${row.kind.wire}'),
                // Under the name, past the 44 px marking and its gap.
                padding: const EdgeInsetsDirectional.only(start: 56, top: 6),
                child: Text(
                  row.note,
                  style: text.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 48,
      contentPadding: EdgeInsets.symmetric(horizontal: isCupertino ? 16 : 0),
      leading: Icon(icon, color: colors.primary),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: isCupertino && onTap != null
          ? Icon(Icons.chevron_right, color: colors.onSurfaceVariant)
          : null,
      onTap: onTap,
    );
  }
}

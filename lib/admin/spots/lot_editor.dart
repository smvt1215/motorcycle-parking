import 'package:material_ui/material_ui.dart';

import '../../models/fee.dart';
import '../../models/fee_plan.dart' show projectZoneFee;
import '../../models/parking_condition.dart';
import '../../ui/fee_editor.dart';
import '../../ui/option_pill.dart';
import '../admin_theme.dart';
import '../review/review_page.dart' show ChangeBand;
import 'lot_models.dart';
import 'spots_controller.dart';

/// A lot's fee plans (canvas AdminSpotForm 計費規則): each plan's name and
/// the sentence riders read, an edit button, and which plan the whole lot's
/// fee uses. Plans are edited in a dialog; one still in use cannot be
/// deleted (decision 51).
class LotPlansSection extends StatelessWidget {
  const LotPlansSection({super.key, required this.spots, this.error});
  final SpotsController spots;
  final String? error;

  Future<void> _edit(BuildContext context, Json? plan) async {
    final id = plan?['id'] as String?;
    final result = await showPlanDialog(
      context,
      name: plan?['name'] as String? ?? '',
      fee: plan == null ? const Fee() : Fee.fromJson(plan['fee']),
      inUse: id == null
          ? null
          : planInUse(
              id,
              spots.draft['fee_plan'],
              spots.draft['parking_zones'],
            ),
      others: [
        for (final p in spots.plans)
          if (p['id'] != id) p['name'] as String? ?? '',
      ],
    );
    if (result == null) return;
    if (result.delete) {
      spots.deletePlan(id!);
    } else if (id == null) {
      spots.addPlan(
        result.name.isEmpty ? planNameOf(result.fee) : result.name,
        result.fee,
      );
    } else {
      spots.setPlan(id, result.name, result.fee);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    final plans = spots.plans;
    final top = spots.draft['fee_plan'];
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          key: const ValueKey('lot-plans'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Heading(
              '計費規則',
              changed: spots.changed('fee_plans'),
              action: OutlinedButton.icon(
                key: const ValueKey('add-plan'),
                onPressed: plans.length >= 12
                    ? null
                    : () => _edit(context, null),
                icon: const Icon(Icons.add),
                label: const Text('新增規則'),
              ),
            ),
            const SizedBox(height: 4),
            Text('同價的格位共用一條規則；改一條規則，用它的分區都會跟著改。規則名稱只有管理員看得到。', style: muted),
            const SizedBox(height: 8),
            if (plans.isEmpty)
              Text('還沒有計費規則。', style: muted)
            else
              for (final p in plans)
                _PlanRow(
                  key: ValueKey('plan-${p['id']}'),
                  plan: p,
                  onEdit: () => _edit(context, p),
                ),
            if (error case final message?) ...[
              const SizedBox(height: 6),
              Text(message, style: TextStyle(color: colors.error)),
            ],
            const SizedBox(height: 16),
            _PlanPicker(
              key: const ValueKey('top-plan'),
              label: '全場費率套用',
              plans: plans,
              value: top as String?,
              changed: spots.changed('fee_plan'),
              onChanged: spots.setTopPlan,
              help: '沒有分區費率的車種，App 顯示全場費率；不套用則只顯示各分區的費率。',
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text, {required this.changed, this.action});
  final String text;
  final bool changed;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 12,
    runSpacing: 8,
    children: [
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            header: true,
            child: Text(
              text,
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (changed) const ChangeBand('已修改'),
        ],
      ),
      ?action,
    ],
  );
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({super.key, required this.plan, required this.onEdit});
  final Json plan;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fee = Fee.fromJson(plan['fee']);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan['name'] as String? ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  fee.isEmpty ? '未確認' : fee.summary,
                  style: TextStyle(
                    color: colors.onSurfaceVariant,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            key: ValueKey('edit-plan-${plan['id']}'),
            onPressed: onEdit,
            child: const Text('編輯'),
          ),
        ],
      ),
    );
  }
}

/// Which plan a zone, or the whole lot, uses.
class _PlanPicker extends StatelessWidget {
  const _PlanPicker({
    super.key,
    required this.label,
    required this.plans,
    required this.value,
    required this.onChanged,
    this.changed = false,
    this.help,
  });
  final String label;
  final List<Json> plans;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool changed;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final known = planById(plans, value) != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String?>(
          // Follows the draft: initialValue alone keeps a stale choice.
          key: ValueKey('$label-$value-${plans.length}'),
          initialValue: known ? value : null,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            helperText: help,
            helperMaxLines: 3,
            suffixIcon: changed
                ? const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: ChangeBand('已修改'),
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(),
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('不套用（未確認）')),
            for (final p in plans)
              DropdownMenuItem(
                value: p['id'] as String,
                child: Text(
                  p['name'] as String? ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }
}

typedef PlanEdit = ({String name, Fee fee, bool delete});

/// Edits one plan: its name and its fee with the shared FeeEditor. Full
/// screen below 600 px so the editor has the width it needs. [inUse] says
/// why it cannot be deleted; null for a plan nothing uses, and a new plan
/// has no delete at all ([others] are the other plans' names).
Future<PlanEdit?> showPlanDialog(
  BuildContext context, {
  required String name,
  required Fee fee,
  required String? inUse,
  required List<String> others,
}) => showDialog<PlanEdit>(
  context: context,
  builder: (context) => _PlanDialog(
    name: name,
    fee: fee,
    inUse: inUse,
    others: others,
    creating: name.isEmpty && fee.isEmpty,
  ),
);

class _PlanDialog extends StatefulWidget {
  const _PlanDialog({
    required this.name,
    required this.fee,
    required this.inUse,
    required this.others,
    required this.creating,
  });
  final String name;
  final Fee fee;
  final String? inUse;
  final List<String> others;
  final bool creating;

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  late final name = TextEditingController(text: widget.name);
  late Fee fee = widget.fee;
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _save() {
    final typed = name.text.trim();
    final problem =
        planFeeProblem(fee) ??
        (typed.length > 20
            ? '規則名稱請在 20 個字以內'
            : widget.others.contains(typed.isEmpty ? planNameOf(fee) : typed)
            ? '已有同名的規則，請換一個名稱'
            : null);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    Navigator.pop<PlanEdit>(context, (
      name: typed.isEmpty ? planNameOf(fee) : typed,
      fee: fee,
      delete: false,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final full = MediaQuery.sizeOf(context).width < 600;
    final body = ListView(
      shrinkWrap: !full,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      children: [
        TextField(
          key: const ValueKey('plan-name'),
          controller: name,
          maxLength: 20,
          decoration: InputDecoration(
            labelText: '規則名稱',
            helperText: '只有管理員看得到；空白時依車種與收費方式命名（例：機車計時）。',
            helperMaxLines: 2,
            hintText: fee.isEmpty ? '例：機車計時' : planNameOf(fee),
          ),
        ),
        const SizedBox(height: 12),
        FeeEditor(
          value: fee,
          onChanged: (v) => setState(() {
            fee = v;
            error = null;
          }),
        ),
        if (error case final message?) ...[
          const SizedBox(height: 8),
          Text(
            message,
            key: const ValueKey('plan-error'),
            style: TextStyle(color: colors.error),
          ),
        ],
        if (!widget.creating) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('delete-plan'),
                style: OutlinedButton.styleFrom(foregroundColor: colors.error),
                onPressed: widget.inUse != null
                    ? null
                    : () => Navigator.pop<PlanEdit>(context, (
                        name: widget.name,
                        fee: widget.fee,
                        delete: true,
                      )),
                icon: const Icon(Icons.delete_outline),
                label: const Text('刪除規則'),
              ),
              if (widget.inUse case final why?)
                Text(
                  why,
                  key: const ValueKey('plan-in-use'),
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
            ],
          ),
        ],
      ],
    );
    final actions = [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('save-plan'),
        onPressed: _save,
        child: Text(widget.creating ? '新增規則' : '完成'),
      ),
    ];
    final title = Text(widget.creating ? '新增計費規則' : '編輯計費規則');
    if (full) {
      return Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: title,
            leading: IconButton(
              tooltip: '取消',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          body: body,
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [actions[0], const SizedBox(width: 8), actions[1]],
              ),
            ),
          ),
        ),
      );
    }
    return AlertDialog(
      title: title,
      contentPadding: EdgeInsets.zero,
      content: SizedBox(width: 760, child: body),
      actions: actions,
    );
  }
}

/// A lot's zones as area cards (canvas AdminSpotForm 區域與格位): zones
/// with the same name and area are one card, one row per bay, each bay
/// picking its plan.
class LotAreasSection extends StatelessWidget {
  const LotAreasSection({super.key, required this.spots, this.error});
  final SpotsController spots;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    final zones = spots.zones;
    final cards = areaCards(zones);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          key: const ValueKey('lot-areas'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Heading(
              '區域與格位',
              changed: spots.changed('parking_zones'),
              action: OutlinedButton.icon(
                key: const ValueKey('add-area'),
                onPressed: spots.addZone,
                icon: const Icon(Icons.add),
                label: const Text('新增區域'),
              ),
            ),
            const SizedBox(height: 4),
            Text('同一區域有幾種格位，就加幾種格位；每種格位選它用的計費規則。', style: muted),
            SwitchListTile(
              key: const ValueKey('zones-complete'),
              contentPadding: EdgeInsets.zero,
              value: spots.draft['zones_complete'] == true,
              onChanged: (v) => spots.set('zones_complete', v),
              title: const Text('分區資料已涵蓋全場'),
              subtitle: Text('開啟後，App 會把沒列出的區域當成不開放；不確定就保持關閉。', style: muted),
            ),
            if (cards.isEmpty) Text('還沒有區域。', style: muted),
            for (final (i, card) in cards.indexed)
              _AreaCard(
                // A renamed card is the same card, so key by position; start
                // over when zones come or go, as the cards shift then.
                key: ValueKey('area-$i-${spots.formSeq}-${zones.length}'),
                index: i,
                card: card,
                spots: spots,
              ),
            if (error case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                key: const ValueKey('zones-error'),
                style: TextStyle(color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

const _areaLabels = <(String?, String)>[
  (null, '未確認'),
  ('motorcycle', '機車區'),
  ('car', '汽車區'),
  ('heavy', '重機專區'),
  ('mixed', '汽機車混合區'),
];

class _AreaCard extends StatefulWidget {
  const _AreaCard({
    super.key,
    required this.index,
    required this.card,
    required this.spots,
  });
  final int index;
  final AreaCard card;
  final SpotsController spots;

  @override
  State<_AreaCard> createState() => _AreaCardState();
}

class _AreaCardState extends State<_AreaCard> {
  late final name = TextEditingController(text: widget.card.name);
  late final url = TextEditingController();
  late final from = TextEditingController();
  late final to = TextEditingController();

  @override
  void initState() {
    super.initState();
    final basis = cardBasis(widget.card, widget.spots.zones);
    url.text = basis?.sourceUrl ?? '';
    from.text = basis?.effectiveDate ?? '';
    to.text = basis?.expiresOn ?? '';
  }

  @override
  void dispose() {
    for (final c in [name, url, from, to]) {
      c.dispose();
    }
    super.dispose();
  }

  void _basis() {
    final link = url.text.trim();
    widget.spots.setCard(
      widget.card,
      basis: link.isEmpty
          ? null
          : <String, dynamic>{
              'source_url': link,
              if (from.text.trim().isNotEmpty)
                'effective_date': from.text.trim(),
              if (to.text.trim().isNotEmpty) 'expires_on': to.text.trim(),
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final card = widget.card;
    final spots = widget.spots;
    final zones = spots.zones;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 480;
          final nameField = TextField(
            key: ValueKey('area-name-${widget.index}'),
            controller: name,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: '區域名稱',
              counterText: '',
            ),
            onChanged: (v) => spots.setCard(card, name: v),
          );
          final areaField = DropdownButtonFormField<String?>(
            key: ValueKey('area-kind-${widget.index}'),
            initialValue: card.area,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '區域'),
            items: [
              for (final (value, label) in _areaLabels)
                DropdownMenuItem(value: value, child: Text(label)),
            ],
            onChanged: (v) => spots.setCard(card, area: v),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: nameField),
                    const SizedBox(width: 12),
                    Expanded(flex: 2, child: areaField),
                  ],
                )
              else ...[
                nameField,
                const SizedBox(height: 8),
                areaField,
              ],
              const SizedBox(height: 12),
              Text(
                '依據',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
              ),
              TextField(
                key: ValueKey('area-url-${widget.index}'),
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '公告網址（選填）',
                  hintText: 'https://',
                ),
                onChanged: (_) => _basis(),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  for (final (c, label, key) in [
                    (from, '生效日（選填）', 'from'),
                    (to, '到期日（選填）', 'to'),
                  ])
                    SizedBox(
                      width: wide ? (box.maxWidth - 12) / 2 : box.maxWidth,
                      child: TextField(
                        key: ValueKey('area-$key-${widget.index}'),
                        controller: c,
                        enabled: url.text.trim().isNotEmpty,
                        keyboardType: TextInputType.datetime,
                        decoration: InputDecoration(
                          labelText: label,
                          hintText: 'YYYY-MM-DD',
                        ),
                        onChanged: (_) => _basis(),
                      ),
                    ),
                ],
              ),
              for (final i in card.indexes)
                _BayRow(
                  key: ValueKey('bay-$i'),
                  index: i,
                  zone: zones[i],
                  spots: spots,
                  removable: true,
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  TextButton.icon(
                    key: ValueKey('add-bay-${widget.index}'),
                    onPressed: () =>
                        spots.addZone(like: zones[card.indexes.first]),
                    icon: const Icon(Icons.add),
                    label: const Text('加一種格位'),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Both vehicles unconfirmed is no `allow` at all: the contract refuses an
/// empty one.
ZoneAllow? _allow(bool? scooter, bool? heavy) =>
    scooter == null && heavy == null
    ? null
    : ZoneAllow(scooter: scooter, heavy: heavy);

const _bayLabels = <(Bay?, String)>[
  (Bay.motorcycle, '機車格'),
  (Bay.heavy, '重機格'),
  (Bay.car, '汽車格'),
  (null, '未確認'),
];

class _BayRow extends StatelessWidget {
  const _BayRow({
    super.key,
    required this.index,
    required this.zone,
    required this.spots,
    required this.removable,
  });
  final int index;
  final Json zone;
  final SpotsController spots;
  final bool removable;

  void _set(ParkingCondition c) =>
      spots.setZone(index, zoneWithCondition(zone, c));

  ParkingCondition _with(
    ParkingCondition c, {
    Bay? Function()? bay,
    BayUse? Function()? use,
    ShareKind? Function()? share,
    Charge? Function()? charge,
    ZoneAllow? Function()? allow,
  }) => ParkingCondition(
    bay: bay == null ? c.bay : bay(),
    use: use == null ? c.use : use(),
    share: share == null ? c.share : share(),
    charge: charge == null ? c.charge : charge(),
    limits: c.limits,
    schedule: c.schedule,
    basis: c.basis,
    allow: allow == null ? c.allow : allow(),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    final c = zoneCondition(zone);
    final problem = zone.containsKey('condition') ? zoneProblem(zone) : null;
    final shareKind = switch (c.bay) {
      Bay.motorcycle => ShareKind.scooterHeavy,
      Bay.car => ShareKind.carMotorcycle,
      _ => null,
    };
    // What the app reads (parking_decision.dart _lot()): the zone's own
    // rate, or the whole lot's when no zone has one.
    final top = spots.draft['fee'];
    final lotWide =
        zone['fee'] is! Map &&
        top is Fee &&
        !top.isEmpty &&
        !spots.zones.any((z) => z['fee'] is Map);
    final rates = zone['fee'] is Map
        ? Fee.fromJson(projectZoneFee(zone['fee'] as Map, zone))
        : lotWide
        ? top
        : null;
    final other = [
      for (final l in c.limits)
        switch (l.kind) {
          LimitKind.timeLimit =>
            l.maxMinutes == null ? '限時' : '限停 ${l.maxMinutes} 分鐘',
          LimitKind.evOnly => '限電動機車',
          LimitKind.specialVehicle => '限身障特製機車',
        },
      if (c.schedule.isNotEmpty) '共用時段 ${c.schedule.length} 段',
    ];
    Widget vehicle(
      String label,
      bool? value,
      ValueChanged<bool?> onPick, {
      Set<bool?> disabled = const {},
    }) => VehicleTriState(
      label: label,
      value: value,
      keyPrefix: 'bay-$index-$label',
      onChanged: onPick,
      disabled: disabled,
    );
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    _bayLabels.firstWhere((b) => b.$1 == c.bay).$2,
                    if (c.share == ShareKind.scooterHeavy) '普大共用',
                    if (c.share == ShareKind.carMotorcycle) '汽機共用',
                    switch (c.charge) {
                      Charge.toll => '收費',
                      Charge.free => '免費',
                      null => '收費未確認',
                    },
                  ].join(' ・ '),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (removable)
                IconButton(
                  key: ValueKey('remove-bay-$index'),
                  tooltip: '刪除這種格位',
                  onPressed: () => spots.removeZone(index),
                  icon: const Icon(Icons.delete_outline),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('格位', style: muted),
                OptionPills<Bay?>(
                  values: _bayLabels,
                  selected: c.bay,
                  keyOf: (v) => 'bay-$index-${v?.name ?? 'unknown'}',
                  onSelect: (bay) => _set(
                    _with(
                      c,
                      bay: () => bay,
                      // A share names its bay; another bay drops it.
                      use: () => c.use == BayUse.share ? BayUse.usual : c.use,
                      share: () => null,
                      allow: () => bay == Bay.heavy && c.allow != null
                          ? ZoneAllow(scooter: false, heavy: c.allow!.heavy)
                          : c.allow,
                    ),
                  ),
                ),
                if (shareKind != null) ...[
                  const SizedBox(height: 4),
                  Text('用途', style: muted),
                  OptionPills<bool?>(
                    values: [
                      (false, '一般'),
                      (
                        true,
                        shareKind == ShareKind.scooterHeavy ? '普大共用' : '汽機共用',
                      ),
                      (null, '未確認'),
                    ],
                    selected: c.use == null ? null : c.use == BayUse.share,
                    keyOf: (v) => 'bay-$index-share-$v',
                    onSelect: (shared) => _set(
                      _with(
                        c,
                        use: () => shared == null
                            ? null
                            : shared
                            ? BayUse.share
                            : BayUse.usual,
                        share: () => shared == true ? shareKind : null,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text('收費格還是免費格', style: muted),
                OptionPills<Charge?>(
                  values: const [
                    (Charge.toll, '收費'),
                    (Charge.free, '免費'),
                    (null, '未確認'),
                  ],
                  selected: c.charge,
                  keyOf: (v) => 'bay-$index-charge-${v?.name ?? 'unknown'}',
                  onSelect: (charge) => _set(_with(c, charge: () => charge)),
                ),
                const SizedBox(height: 4),
                Text('可停車種', style: muted),
                Wrap(
                  spacing: 24,
                  runSpacing: 4,
                  children: [
                    vehicle(
                      '普通機車',
                      c.allow?.scooter,
                      (v) => _set(
                        _with(c, allow: () => _allow(v, c.allow?.heavy)),
                      ),
                      // The contract refuses scooters in a heavy bay; the
                      // choice would leave a condition nothing can read.
                      disabled: c.bay == Bay.heavy ? const {true} : const {},
                    ),
                    vehicle(
                      '大型重機',
                      c.allow?.heavy,
                      (v) => _set(
                        _with(c, allow: () => _allow(c.allow?.scooter, v)),
                      ),
                    ),
                  ],
                ),
                if (other.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('其他條件（照原樣保留）：${other.join('、')}', style: muted),
                ],
                const SizedBox(height: 12),
                _PlanPicker(
                  key: ValueKey('zone-plan-$index'),
                  label: '計費規則',
                  plans: spots.plans,
                  value: zone['fee_plan'] as String?,
                  onChanged: (id) =>
                      spots.setZone(index, zoneWithPlan(zone, id, spots.plans)),
                ),
                const SizedBox(height: 6),
                Text(
                  rates == null || rates.isEmpty
                      ? 'App 顯示：費率未確認'
                      : lotWide
                      ? 'App 顯示全場費率：${rates.summary}'
                      : 'App 顯示：${rates.summary}',
                  key: ValueKey('zone-rates-$index'),
                  style: muted,
                ),
                if (problem case final message?) ...[
                  const SizedBox(height: 6),
                  Text(
                    message,
                    key: ValueKey('bay-problem-$index'),
                    style: TextStyle(color: colors.error),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The posted fee as it was imported (`fee_source_text`, design §5.5):
/// read-only, for comparing with the structured fee. The app never shows it.
class FeeSourceText extends StatelessWidget {
  const FeeSourceText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          key: const ValueKey('fee-source-text'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '原始公告文字（匯入，唯讀）',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                border: Border(
                  left: BorderSide(color: AdminColors.yellow, width: 3),
                ),
              ),
              child: SelectableText('「$text」'),
            ),
            const SizedBox(height: 4),
            Text(
              '只在管理站顯示，App 不顯示。改費率時這段文字會清空。',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

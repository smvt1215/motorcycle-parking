import 'package:material_ui/material_ui.dart';

import '../../models/fee.dart';
import '../spots/lot_models.dart';
import 'review_models.dart';

/// What applying a fee to a shared plan changes (canvas AdminSharedPlan).
enum SharedPlanScope { onlyHere, plan }

typedef SharedPlanChoice = ({SharedPlanScope scope, String name});

/// Asks whether a suggested fee changes only the spot's whole fee (a plan
/// of its own, the default) or the shared plan every listed zone uses.
/// Null when cancelled.
Future<SharedPlanChoice?> pickSharedPlanScope(
  BuildContext context, {
  required Json plan,
  required List<String> zones,
  required Fee fee,
  required List<Json> plans,
}) => showDialog<SharedPlanChoice>(
  context: context,
  builder: (context) =>
      _SharedPlanDialog(plan: plan, zones: zones, fee: fee, plans: plans),
);

class _SharedPlanDialog extends StatefulWidget {
  const _SharedPlanDialog({
    required this.plan,
    required this.zones,
    required this.fee,
    required this.plans,
  });
  final Json plan;
  final List<String> zones;
  final Fee fee;
  final List<Json> plans;

  @override
  State<_SharedPlanDialog> createState() => _SharedPlanDialogState();
}

class _SharedPlanDialogState extends State<_SharedPlanDialog> {
  late final full = widget.plans.length >= 12;
  late SharedPlanScope scope = full
      ? SharedPlanScope.plan
      : SharedPlanScope.onlyHere;
  late final name = TextEditingController(
    text: uniquePlanName(planNameOf(widget.fee), widget.plans),
  );
  String? error;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _confirm() {
    final typed = name.text.trim();
    if (scope == SharedPlanScope.onlyHere) {
      final problem = typed.isEmpty
          ? '請填新規則的名稱'
          : typed.length > 20
          ? '規則名稱請在 20 個字以內'
          : widget.plans.any((p) => p['name'] == typed)
          ? '已有同名的規則，請換一個名稱'
          : null;
      if (problem != null) {
        setState(() => error = problem);
        return;
      }
    }
    Navigator.pop<SharedPlanChoice>(context, (scope: scope, name: typed));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 14);
    final planName = widget.plan['name'] as String? ?? '';
    final uses = widget.zones.length + 1;
    final old = Fee.fromJson(widget.plan['fee']).summary;
    final next = widget.fee.summary;
    return AlertDialog(
      title: Text('「$planName」有 $uses 處在用'),
      scrollable: true,
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('這則建議把全場費率改成：$next'),
            const SizedBox(height: 12),
            Text('使用這條規則的地方', style: muted),
            const SizedBox(height: 4),
            Text('・全場費率（這則建議）'),
            for (final z in widget.zones) Text('・$z'),
            const SizedBox(height: 16),
            Text('要改哪裡', style: muted),
            RadioGroup<SharedPlanScope>(
              groupValue: scope,
              onChanged: (v) => setState(() {
                scope = v ?? scope;
                error = null;
              }),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RadioListTile<SharedPlanScope>(
                    key: const ValueKey('scope-only-here'),
                    value: SharedPlanScope.onlyHere,
                    enabled: !full,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('只改全場費率'),
                    subtitle: Text(
                      full
                          ? '計費規則已有 12 條，無法另開；請改規則，或先到點位表單整理規則。'
                          : '另開一條規則給全場費率，其他 ${widget.zones.length} 個分區維持$old。',
                    ),
                  ),
                  if (scope == SharedPlanScope.onlyHere)
                    Padding(
                      padding: const EdgeInsets.only(left: 16, bottom: 8),
                      child: TextField(
                        key: const ValueKey('new-plan-name'),
                        controller: name,
                        maxLength: 20,
                        decoration: InputDecoration(
                          labelText: '新規則名稱',
                          errorText: error,
                        ),
                      ),
                    ),
                  RadioListTile<SharedPlanScope>(
                    key: const ValueKey('scope-plan'),
                    value: SharedPlanScope.plan,
                    contentPadding: EdgeInsets.zero,
                    title: Text('改「$planName」這條規則'),
                    subtitle: Text('$uses 處都會變成$next。'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-scope'),
          onPressed: _confirm,
          child: Text(
            scope == SharedPlanScope.onlyHere
                ? '套用到全場費率'
                : '套用到「$planName」的 $uses 處',
          ),
        ),
      ],
    );
  }
}

/// [patch] (as wired) for [choice].
Map<String, dynamic> applySharedPlanChoice(
  Map<String, dynamic> patch,
  ReviewSpot spot,
  SharedPlanChoice choice,
) => choice.scope == SharedPlanScope.onlyHere
    ? ownPlanPatch(patch, spot, choice.name)
    : editedPlanPatch(patch, spot);

import 'package:material_ui/material_ui.dart';

import '../admin_theme.dart';
import 'review_models.dart';

/// Asks why a report is rejected: a bottom sheet on phones, a dialog on
/// wider screens. Returns null when the admin backs out.
Future<ResolutionKind?> pickRejectReason(
  BuildContext context, {
  required bool compact,
}) {
  if (compact) {
    return showModalBottomSheet<ResolutionKind>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => const RejectReasonPicker(),
    );
  }
  return showDialog<ResolutionKind>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: const RejectReasonPicker(),
      ),
    ),
  );
}

/// The reasons as a radio list; "駁回這筆回報" stays off until one is chosen.
class RejectReasonPicker extends StatefulWidget {
  const RejectReasonPicker({super.key});

  @override
  State<RejectReasonPicker> createState() => _RejectReasonPickerState();
}

class _RejectReasonPickerState extends State<RejectReasonPicker> {
  ResolutionKind? _kind;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
          child: Semantics(
            header: true,
            child: Text(
              '駁回原因',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            '選最接近的一項，點位不會改動。回報者只會看到這個原因的固定說明；處理說明只給管理員看。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: RadioGroup<ResolutionKind>(
              groupValue: _kind,
              onChanged: (k) => setState(() => _kind = k),
              child: Column(
                children: [
                  for (final k in ResolutionKind.values)
                    RadioListTile<ResolutionKind>(
                      key: ValueKey('reject-${k.name}'),
                      value: k,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      title: Text(
                        k.label,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(k.description),
                    ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('reject-confirm'),
                onPressed: _kind == null
                    ? null
                    : () => Navigator.pop(context, _kind),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                ),
                child: const Text('駁回這筆回報'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Risk class as a painted curb line: white, yellow or red, with the level
/// also in the bar icon and the words, so colour is never the only cue.
class RiskTag extends StatelessWidget {
  const RiskTag(this.risk, {super.key});
  final ReviewRisk risk;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final line = switch (risk) {
      ReviewRisk.low => colors.outline,
      ReviewRisk.medium => AdminColors.yellow,
      ReviewRisk.high => colors.error,
    };
    final icon = switch (risk) {
      ReviewRisk.low => Icons.signal_cellular_alt_1_bar,
      ReviewRisk.medium => Icons.signal_cellular_alt_2_bar,
      ReviewRisk.high => Icons.signal_cellular_alt,
    };
    return Semantics(
      label: risk.label,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: line, width: 4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: colors.onSurface),
            const SizedBox(width: 4),
            Text(
              risk.label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: risk == ReviewRisk.high
                    ? FontWeight.w700
                    : FontWeight.w500,
                color: colors.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

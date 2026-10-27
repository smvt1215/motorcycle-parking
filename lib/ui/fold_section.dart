import 'package:material_ui/material_ui.dart';

/// One part of a long form that folds (C6 canvas AppPatterns, pattern 5;
/// AppForm): only one is open at a time. Folded, it is one button with the
/// title and what is filled in, or 還沒填; open, a bordered card with the
/// fields. The fields stay mounted while folded, so they keep what was
/// typed and the form still checks them.
class FoldSection extends StatelessWidget {
  const FoldSection({
    super.key,
    required this.title,
    required this.summary,
    required this.open,
    required this.onToggle,
    required this.child,
    this.hint,
    this.problem = false,
  });
  final String title;

  /// What is filled in; null shows 還沒填.
  final String? summary;

  /// Under the title while open, in place of the summary.
  final String? hint;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  /// A field inside needs fixing: the folded summary says so in red.
  final bool problem;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shown = problem ? '有欄位要修正' : summary ?? '還沒填';
    final sub = open ? hint : shown;
    final header = Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        key: ValueKey('fold-$title'),
        onTap: onToggle,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: open ? 48 : 64),
          child: Padding(
            padding: open
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (sub != null)
                        Text(
                          sub,
                          style: TextStyle(
                            fontSize: 13,
                            color: !open && problem
                                ? colors.error
                                : colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  open ? Icons.expand_less : Icons.expand_more,
                  color: colors.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          border: Border.all(
            color: open
                ? colors.primary
                : problem
                ? colors.error
                : colors.outlineVariant,
            width: open ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: open ? const EdgeInsets.all(14) : EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              Visibility(
                visible: open,
                maintainState: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

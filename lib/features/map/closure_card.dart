import 'package:material_ui/material_ui.dart';

import '../../models/closure.dart';

/// A spot's temporary closure in its detail (closure canvas
/// ClosureDetail): before its date, 施工中／暫時封閉，暫時不能停 with the
/// reopening date or 恢復時間未知; past it, 原定…恢復 and whether the rider
/// can confirm — 已經可以停 or 還是不能停.
class ClosureCard extends StatelessWidget {
  const ClosureCard({
    super.key,
    required this.closure,
    required this.now,
    this.onReopened,
    this.onStillClosed,
  });
  final SpotClosure closure;
  final DateTime now;

  /// The rider says the spot can be parked at again; null hides the choice.
  final VoidCallback? onReopened;

  /// The rider says it still cannot: opens the 這裡已經不能停車 report.
  final VoidCallback? onStillClosed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final expired = closure.stateOn(now) == ClosureState.expired;
    final until = closure.until;
    final since = closureDate(closure.since);
    final basis = closure.basis.isEmpty ? '' : '・${closure.basis}';
    final (icon, title, line, foot) = expired
        ? (
            Icons.help_outline,
            until == null
                ? '${closure.reason.label}的回報已超過 $closureDefaultDays 天'
                : '原定 ${closureDayLabel(until)}恢復',
            '現場是否已恢復，還沒有人確認',
            null,
          )
        : (
            closure.reason == ClosureReason.works
                ? Icons.construction
                : Icons.lock_outline,
            '${closure.reason.label}，暫時不能停',
            until == null ? '恢復時間未知' : '預計 ${closureDayLabel(until)}恢復',
            '回報於 $since$basis',
          );
    final tone = expired ? const Color(0xff865500) : const Color(0xff59646c);
    final fill = expired
        ? (Theme.of(context).brightness == Brightness.dark
              ? const Color(0xff3a2f1c)
              : const Color(0xfffdf3e3))
        : colors.surfaceContainerHighest;
    return Semantics(
      container: true,
      label: expired ? '恢復待確認' : '暫時無法停車',
      child: Column(
        key: const ValueKey('closure-card'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tone,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: Colors.white),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(line, style: text.bodyMedium),
                      if (foot != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          foot,
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (expired && (onReopened != null || onStillClosed != null)) ...[
            const SizedBox(height: 12),
            Text('你在現場嗎？', style: text.bodyMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('closure-reopened'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      side: BorderSide(color: colors.primary),
                    ),
                    onPressed: onReopened,
                    child: const Text('已經可以停'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    key: const ValueKey('closure-still'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: onStillClosed,
                    child: const Text('還是不能停'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

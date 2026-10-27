import 'package:material_ui/material_ui.dart';

import '../../models/closure.dart';
import '../../ui/option_pill.dart';
import '../review/review_page.dart' show ChangeBand;

/// 暫時無法停車 in the admin spot form (C6 canvas ClosureAdmin, #116): the
/// cause, the reopening date (optional; without one it ends 7 days after
/// it began) and what it rests on, tagged 生效中 or 待確認 once its date
/// has passed; a lapsed one can be extended or marked reopened.
class ClosureSection extends StatelessWidget {
  const ClosureSection({
    super.key,
    required this.value,
    required this.onChanged,
    required this.now,
    this.changed = false,
    this.stored,
    this.framed = true,
  });

  /// False inside the form's folding section, which gives the title and
  /// the border.
  final bool framed;

  /// The closure as edited, as JSON; null for none.
  final Map<String, dynamic>? value;
  final ValueChanged<Map<String, dynamic>?> onChanged;
  final DateTime now;
  final bool changed;

  /// The stored closure's state as the server judged it.
  final String? stored;

  Future<DateTime?> _pick(BuildContext context, SpotClosure c) {
    final today = taiwanToday(now);
    final first = c.since.isAfter(today) ? c.since : today;
    return showDatePicker(
      context: context,
      initialDate: c.until != null && !c.until!.isBefore(first)
          ? c.until!
          : first,
      firstDate: c.since,
      lastDate: today.add(const Duration(days: 730)),
      helpText: '預計恢復日期',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    final closure = SpotClosure.fromJson(value, state: changed ? null : stored);
    final state = closure?.stateOn(now);
    Widget tag(String text, Color fill, Color ink) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
    void set(SpotClosure? c) => onChanged(c?.toJson());
    return Padding(
      padding: EdgeInsets.only(top: framed ? 24 : 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Container(
          key: const ValueKey('closure-section'),
          padding: framed ? const EdgeInsets.all(14) : EdgeInsets.zero,
          decoration: framed
              ? BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (framed)
                    Semantics(
                      header: true,
                      child: Text(
                        '暫時無法停車',
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                  if (state == ClosureState.active)
                    tag('生效中', const Color(0xff2a2e33), Colors.white),
                  if (state == ClosureState.expired)
                    tag(
                      '待確認',
                      const Color(0xffe3ae00),
                      const Color(0xff2a2e33),
                    ),
                  if (changed) const ChangeBand('已修改'),
                ],
              ),
              const SizedBox(height: 8),
              Text('原因', style: muted),
              OptionPills<ClosureReason?>(
                values: const [
                  (null, '沒有'),
                  (ClosureReason.works, '施工中'),
                  (ClosureReason.closed, '暫時封閉'),
                ],
                selected: closure?.reason,
                keyOf: (r) => 'closure-${r?.name ?? 'none'}',
                onSelect: (r) => set(
                  r == null
                      ? null
                      : closure?.copyWith(reason: r) ??
                            SpotClosure(
                              reason: r,
                              since: taiwanToday(now),
                              basis: '管理員設定',
                            ),
                ),
              ),
              if (closure != null) ...[
                const SizedBox(height: 12),
                Text('預計恢復日期（選填）', style: muted),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const ValueKey('closure-until'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          alignment: Alignment.centerLeft,
                        ),
                        onPressed: () async {
                          final d = await _pick(context, closure);
                          if (d != null) set(closure.copyWith(until: () => d));
                        },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text(
                          closure.until == null
                              ? '沒有日期'
                              : '${closureDate(closure.until!).replaceAll('-', '/')}'
                                    '（${const ['一', '二', '三', '四', '五', '六', '日'][closure.until!.weekday - 1]}）',
                        ),
                      ),
                    ),
                    if (closure.until != null)
                      IconButton(
                        key: const ValueKey('closure-clear-until'),
                        tooltip: '清除日期',
                        onPressed: () =>
                            set(closure.copyWith(until: () => null)),
                        icon: const Icon(Icons.close),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '過了 ${closureDayLabel(closure.endsOn)}，App 會恢復顯示這個點位，並請車友確認現場。'
                  '${closure.until == null ? '沒填日期時，${closureDate(closure.since)} 起 $closureDefaultDays 天後到期。' : ''}',
                  key: const ValueKey('closure-explain'),
                  style: const TextStyle(fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '依據：${closure.basis.isEmpty ? '未提供' : closure.basis}（${closureDate(closure.since)} 起）',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                if (state == ClosureState.expired) ...[
                  const SizedBox(height: 12),
                  Text(
                    '${closure.reason.label}，原定 ${closureDayLabel(closure.endsOn)}恢復。App 已恢復顯示，還沒有車友確認。',
                    style: const TextStyle(fontSize: 14, height: 1.5),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('closure-extend'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () async {
                            final d = await _pick(context, closure);
                            if (d != null) {
                              set(closure.copyWith(until: () => d));
                            }
                          },
                          child: const Text('延長到…'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          key: const ValueKey('closure-reopen'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () => set(null),
                          child: const Text('標記已恢復'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

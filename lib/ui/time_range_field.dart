import 'package:cupertino_ui/cupertino_ui.dart' as cu;

import 'adaptive/adaptive.dart';

/// A range as [TimeRangeField] reports it: both times, or [allDay].
typedef TimeRange = ({String? from, String? to, bool allDay});

/// 開始 – 結束 and 全天 (S5, F1). All day goes without times, as the contract
/// reads it; the end before the start is the next day and says so.
///
/// With [labelled] the fields carry 開始 and 結束 above them. With
/// [inlineWheel] iOS turns the wheel inside the form under the fields (F1's
/// board) instead of the shared bottom panel; [help] then sits in the panel,
/// and elsewhere under the fields.
class TimeRangeField extends StatefulWidget {
  const TimeRangeField({
    super.key,
    required this.from,
    required this.to,
    required this.allDay,
    required this.onChanged,
    this.labelled = false,
    this.inlineWheel = false,
    this.help,
    this.keyPrefix = 'time',
  });
  final String? from, to;
  final bool allDay;
  final ValueChanged<TimeRange> onChanged;
  final bool labelled, inlineWheel;
  final String? help;
  final String keyPrefix;

  @override
  State<TimeRangeField> createState() => _TimeRangeFieldState();
}

class _TimeRangeFieldState extends State<TimeRangeField> {
  /// The field the inline wheel sets: true for 開始, false for 結束.
  bool? wheel;

  bool get inline => widget.inlineWheel && isCupertino;

  void _emit({String? from, String? to, bool? allDay}) => widget.onChanged((
    from: from ?? widget.from,
    to: to ?? widget.to,
    allDay: allDay ?? widget.allDay,
  ));

  Widget _field(bool start) {
    final label = start ? '開始時間' : '結束時間';
    final value = widget.allDay ? null : (start ? widget.from : widget.to);
    final key = ValueKey('${widget.keyPrefix}-${start ? 'from' : 'to'}');
    if (!inline) {
      return AdaptiveTimeField(
        key: key,
        label: label,
        value: value,
        enabled: !widget.allDay,
        onChanged: (v) => start ? _emit(from: v) : _emit(to: v),
      );
    }
    return _WheelField(
      key: key,
      label: label,
      value: value,
      enabled: !widget.allDay,
      active: wheel == start,
      onTap: () => setState(() => wheel = wheel == start ? null : start),
    );
  }

  Widget _allDay(ColorScheme colors) {
    final on = widget.allDay;
    return Semantics(
      button: true,
      toggled: on,
      label: '全天',
      excludeSemantics: true,
      child: Material(
        color: on ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: on ? brand : colors.outlineVariant,
            width: on ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('${widget.keyPrefix}-all-day'),
          onTap: () {
            setState(() => wheel = null);
            _emit(allDay: !on);
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: isCupertino ? 44 : 48,
              minWidth: 56,
            ),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  '全天',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: on ? FontWeight.w700 : FontWeight.w400,
                    color: on ? colors.onPrimaryContainer : colors.onSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _labelled(String label, Widget field, ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        label,
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      field,
    ],
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final from = widget.from, to = widget.to;
    final overnight =
        !widget.allDay && from != null && to != null && to.compareTo(from) < 0;
    final muted = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final start = _field(true), end = _field(false);
    final fields = widget.labelled
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _labelled('開始', start, colors)),
              const SizedBox(width: 8),
              Expanded(
                child: _labelled(overnight ? '結束（隔日）' : '結束', end, colors),
              ),
            ],
          )
        : Row(
            children: [
              Expanded(child: start),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: ExcludeSemantics(child: Text('–')),
              ),
              Expanded(child: end),
            ],
          );
    final panel = wheel;
    return LayoutBuilder(
      builder: (context, box) {
        final roomy =
            !widget.labelled &&
            box.maxWidth >= 280 &&
            MediaQuery.textScalerOf(context).scale(16) <= 20;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (roomy)
              Row(
                children: [
                  Expanded(child: fields),
                  const SizedBox(width: 8),
                  _allDay(colors),
                ],
              )
            else ...[
              fields,
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _allDay(colors),
              ),
            ],
            if (overnight && !widget.labelled) ...[
              const SizedBox(height: 4),
              Text('結束早於開始：到隔日 $to', style: muted),
            ],
            if (panel != null && inline)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _WheelPanel(
                  key: ValueKey('${widget.keyPrefix}-wheel-$panel'),
                  title: panel ? '開始時間' : '結束時間',
                  value: (panel ? from : to) ?? (panel ? '08:00' : '20:00'),
                  help: widget.help,
                  onChanged: (v) => panel ? _emit(from: v) : _emit(to: v),
                  onDone: () => setState(() => wheel = null),
                ),
              )
            else if (widget.help case final help? when !inline) ...[
              const SizedBox(height: 4),
              Text(help, style: muted),
            ],
          ],
        );
      },
    );
  }
}

/// The time box of F1 on iOS: as [AdaptiveTimeField], and it opens the wheel
/// under the fields.
class _WheelField extends StatelessWidget {
  const _WheelField({
    super.key,
    required this.label,
    required this.value,
    required this.enabled,
    required this.active,
    required this.onTap,
  });
  final String label;
  final String? value;
  final bool enabled, active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fg = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: .38);
    return Semantics(
      button: true,
      enabled: enabled,
      expanded: active,
      label: label,
      value: value ?? '未設定',
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Material(
        color: colors.surfaceContainerHighest,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: active
              ? const BorderSide(color: brand, width: 1.5)
              : BorderSide.none,
        ),
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value ?? '--:--',
                      style: TextStyle(
                        fontSize: 16,
                        color: fg,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.schedule, size: 18, color: fg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The wheel inside the form (F1, iOS): 24-hour, every minute.
class _WheelPanel extends StatelessWidget {
  const _WheelPanel({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    required this.onDone,
    this.help,
  });
  final String title, value;
  final String? help;
  final ValueChanged<String> onChanged;
  final VoidCallback onDone;

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parts = value.split(':');
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: brand),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                cu.CupertinoButton(
                  key: const ValueKey('time-wheel-done'),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(44, 44),
                  onPressed: onDone,
                  child: Text(
                    '確定',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: colors.primary,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(
              height: 150,
              child: cu.CupertinoDatePicker(
                key: const ValueKey('time-wheel'),
                mode: cu.CupertinoDatePickerMode.time,
                use24hFormat: true,
                initialDateTime: DateTime(
                  2000,
                  1,
                  1,
                  int.parse(parts[0]),
                  int.parse(parts[1]),
                ),
                onDateTimeChanged: (t) => onChanged(_hhmm(t)),
              ),
            ),
            if (help != null) ...[
              const SizedBox(height: 6),
              Text(
                help!,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

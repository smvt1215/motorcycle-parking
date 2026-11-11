// Shared form pieces for the #190 sheets (N1, S2, S4, S5, F1, F2): the top
// bar, the pinned send bar, the info note, the time field and the stepper.
// Each follows HIG on iOS and Material 3 Expressive elsewhere; touch areas
// are at least 44 on iOS and 48 on Android.
import 'package:cupertino_ui/cupertino_ui.dart' as cu;

import '../../domain/form_display.dart';
import 'adaptive.dart';

/// What the top bar's leading button does: close the whole form (cancel
/// while nothing has gone, close once something has, S6), or step back to
/// the screen before it.
enum FormHeaderLeading { cancel, close, back }

/// A form's top bar. iOS: a 「取消」 or 「關閉」 text button or 「‹ 返回」 on the left
/// and the title centred with an optional small subtitle. Android: a close
/// or arrow_back icon button (48) and the title on the left.
///
/// [onLeading] defaults to popping the current route.
class FormHeader extends StatelessWidget {
  const FormHeader({
    super.key,
    required this.title,
    this.subtitle,
    required this.leading,
    this.onLeading,
  });
  final String title;
  final String? subtitle;
  final FormHeaderLeading leading;
  final VoidCallback? onLeading;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final onTap = onLeading ?? () => Navigator.maybePop(context);
    final cupertino = isCupertino;
    final heading = Semantics(
      header: true,
      child: Column(
        crossAxisAlignment: cupertino
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Text(
            title,
            textAlign: cupertino ? TextAlign.center : TextAlign.start,
            style: cupertino
                ? TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  )
                : TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w400,
                    color: colors.onSurface,
                  ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              textAlign: cupertino ? TextAlign.center : TextAlign.start,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
    if (!cupertino) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
        child: Row(
          children: [
            IconButton(
              key: const ValueKey('form-header-leading'),
              tooltip: leading == FormHeaderLeading.back ? formBack : formClose,
              onPressed: onTap,
              icon: Icon(
                leading == FormHeaderLeading.back
                    ? Icons.arrow_back
                    : Icons.close,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: heading),
          ],
        ),
      );
    }
    final button = _CupertinoLeading(leading: leading, onPressed: onTap);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.outlineVariant, width: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            button,
            const SizedBox(width: 8),
            Expanded(child: heading),
            const SizedBox(width: 8),
            // An unseen twin of the button keeps the title truly centred.
            ExcludeSemantics(
              child: IgnorePointer(
                child: Visibility(
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: _CupertinoLeading(leading: leading, onPressed: null),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CupertinoLeading extends StatelessWidget {
  const _CupertinoLeading({required this.leading, required this.onPressed});
  final FormHeaderLeading leading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final back = leading == FormHeaderLeading.back;
    final word = leading == FormHeaderLeading.close ? formClose : formCancel;
    return Semantics(
      button: true,
      label: back ? formBack : word,
      excludeSemantics: true,
      onTap: onPressed,
      child: cu.CupertinoButton(
        key: onPressed == null ? null : const ValueKey('form-header-leading'),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(44, 44),
        onPressed: onPressed,
        child: back
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chevron_left, size: 30, color: color),
                  Text(formBack, style: TextStyle(fontSize: 17, color: color)),
                ],
              )
            : Text(word, style: TextStyle(fontSize: 16, color: color)),
      ),
    );
  }
}

/// The send button pinned to a form's bottom edge, with an optional small
/// [note] under it (「管理員審核後才會更新地圖」). While [sending] it reads
/// 「送出中…」 and cannot be pressed; a null [onPressed] also disables it.
/// [above] sits over the button inside the bar: why the last send failed
/// (S6b), which stays in view however far the form is scrolled.
class SubmitBar extends StatelessWidget {
  const SubmitBar({
    super.key,
    required this.label,
    required this.onPressed,
    this.note,
    this.above,
    this.sending = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final String? note;
  final Widget? above;
  final bool sending;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (above case final above?) ...[
                above,
                const SizedBox(height: 8),
              ],
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 52),
                // Cupertino buttons do not report enabled state themselves.
                child: Semantics(
                  enabled: !sending && onPressed != null,
                  child: AdaptiveButton(
                    key: const ValueKey('submit-bar-button'),
                    label: sending ? formSending : label,
                    onPressed: sending ? null : onPressed,
                  ),
                ),
              ),
              if (note != null) ...[
                const SizedBox(height: 6),
                Text(
                  note!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// How a [FormInfoNote] is painted.
enum FormNoteTone {
  /// A plain fact or hint, on a grey panel.
  info,

  /// Worth checking: the map's conditional amber.
  warning,

  /// Something to fix before sending; also announced when it appears.
  error,
}

/// An explanation panel inside a form: an icon (so the state never rests on
/// colour alone) and text on a tinted background.
class FormInfoNote extends StatelessWidget {
  const FormInfoNote({
    super.key,
    required this.icon,
    required this.text,
    this.tone = FormNoteTone.info,
  });
  final IconData icon;
  final String text;
  final FormNoteTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    // Same foregrounds as LocationNote, so notes read alike across forms.
    final color = switch (tone) {
      FormNoteTone.info => colors.onSurfaceVariant,
      // Lightened in dark mode to keep AA contrast on the dark surface.
      FormNoteTone.warning => dark ? const Color(0xffe9c27a) : conditionalColor,
      FormNoteTone.error => colors.error,
    };
    final background = tone == FormNoteTone.info
        ? colors.surfaceContainerLow
        : Color.alphaBlend(
            color.withValues(alpha: dark ? 0.16 : 0.10),
            colors.surface,
          );
    return Semantics(
      liveRegion: tone == FormNoteTone.error,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(fontSize: 13, height: 1.5, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A time box that shows `HH:mm` (or 「--:--」) and opens
/// [showAdaptiveTimePicker] when tapped. [label] (「開始時間」) is what a
/// screen reader says and the picker's title. Fills the width it is given.
class AdaptiveTimeField extends StatelessWidget {
  const AdaptiveTimeField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });
  final String label;

  /// The time as `HH:mm`, or null when not set yet.
  final String? value;
  final ValueChanged<String> onChanged;
  final bool enabled;

  Future<void> _pick(BuildContext context) async {
    final picked = await showAdaptiveTimePicker(
      context,
      title: label,
      initial: value,
    );
    if (picked != null && picked != value) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cupertino = isCupertino;
    final fg = enabled
        ? colors.onSurface
        : colors.onSurface.withValues(alpha: 0.38);
    final radius = BorderRadius.circular(cupertino ? 10 : 4);
    final decoration = cupertino
        ? BoxDecoration(
            color: colors.surfaceContainerHighest,
            borderRadius: radius,
          )
        : BoxDecoration(
            color: colors.surface,
            borderRadius: radius,
            border: Border.all(
              color: enabled
                  ? colors.outline
                  : colors.onSurface.withValues(alpha: 0.12),
            ),
          );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      value: value ?? timeUnset,
      excludeSemantics: true,
      onTap: enabled ? () => _pick(context) : null,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? () => _pick(context) : null,
          child: Ink(
            decoration: decoration,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: cupertino ? 44 : 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        value ?? timePlaceholder,
                        style: TextStyle(
                          fontSize: 16,
                          color: fg,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.schedule,
                      size: 18,
                      color: enabled ? colors.onSurfaceVariant : fg,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final _hhmm = RegExp(r'^([01]\d|2[0-3]):([0-5]\d)$');

String _format(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

/// Asks for a time and returns it as `HH:mm`, or null when cancelled.
/// iOS: a wheel (24-hour, every minute) in a bottom panel with 「取消」 and
/// 「確定」. Android: the Material 3 time picker dialog opened in input
/// mode (hour and minute boxes, 24-hour), with the dial a tap away.
/// An [initial] that is not `HH:mm` starts at 00:00.
Future<String?> showAdaptiveTimePicker(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  final match = _hhmm.firstMatch(initial ?? '');
  final hour = match == null ? 0 : int.parse(match[1]!);
  final minute = match == null ? 0 : int.parse(match[2]!);
  if (isCupertino) {
    return cu.showCupertinoModalPopup<String>(
      context: context,
      builder: (_) =>
          _CupertinoTimeSheet(title: title, hour: hour, minute: minute),
    );
  }
  // Material's picker, not M3ETimePicker: material_3_expressive 1.2.0's
  // input mode rewrites the hour box while it rebuilds, so typing 「9」
  // fails a framework assertion and moves the cursor.
  final picked = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: hour, minute: minute),
    initialEntryMode: TimePickerEntryMode.input,
    helpText: title,
    cancelText: timePickerCancel,
    confirmText: timePickerConfirm,
    errorInvalidText: timePickerInvalid,
    hourLabelText: timePickerHour,
    minuteLabelText: timePickerMinute,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
      child: child!,
    ),
  );
  return picked == null ? null : _format(picked.hour, picked.minute);
}

class _CupertinoTimeSheet extends StatefulWidget {
  const _CupertinoTimeSheet({
    required this.title,
    required this.hour,
    required this.minute,
  });
  final String title;
  final int hour, minute;

  @override
  State<_CupertinoTimeSheet> createState() => _CupertinoTimeSheetState();
}

class _CupertinoTimeSheetState extends State<_CupertinoTimeSheet> {
  late var _time = DateTime(2000, 1, 1, widget.hour, widget.minute);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = cu.CupertinoColors.systemBackground.resolveFrom(context);
    return Material(
      color: background,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  cu.CupertinoButton(
                    key: const ValueKey('time-picker-cancel'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 44),
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      timePickerCancel,
                      style: TextStyle(fontSize: 14, color: colors.primary),
                    ),
                  ),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        widget.title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                  cu.CupertinoButton(
                    key: const ValueKey('time-picker-confirm'),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(44, 44),
                    onPressed: () => Navigator.pop(
                      context,
                      _format(_time.hour, _time.minute),
                    ),
                    child: Text(
                      timePickerConfirm,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 216,
              child: cu.CupertinoDatePicker(
                key: const ValueKey('time-picker-wheel'),
                mode: cu.CupertinoDatePickerMode.time,
                use24hFormat: true,
                initialDateTime: _time,
                onDateTimeChanged: (t) => setState(() => _time = t),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// − value ＋ for a small whole number, such as 每次限停 in 30-minute steps.
/// Each button is a 44 (iOS) / 48 (Android) circle and is disabled at its
/// end of the range. A screen reader hears [label] and `format(value)`,
/// and can raise or lower the value with the increase / decrease actions.
/// [label] is not drawn: the form shows its own question above.
class AdaptiveStepper extends StatelessWidget {
  const AdaptiveStepper({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    required this.format,
    required this.onChanged,
  }) : assert(min <= max),
       assert(step > 0);
  final String label;
  final int value;
  final int min, max;
  final int step;
  final String Function(int) format;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final lower = value - step < min ? null : value - step;
    final higher = value + step > max ? null : value + step;
    final down = lower == null ? null : () => onChanged(lower);
    final up = higher == null ? null : () => onChanged(higher);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(
          key: const ValueKey('stepper-decrease'),
          icon: Icons.remove,
          label: stepperDecrease(label),
          onPressed: down,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Semantics(
            label: label,
            value: format(value),
            increasedValue: higher == null ? null : format(higher),
            decreasedValue: lower == null ? null : format(lower),
            onIncrease: up,
            onDecrease: down,
            excludeSemantics: true,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 72),
              child: Text(
                format(value),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        _StepButton(
          key: const ValueKey('stepper-increase'),
          icon: Icons.add,
          label: stepperIncrease(label),
          onPressed: up,
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (!isCupertino) {
      return IconButton.outlined(
        tooltip: label,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 48, height: 48),
        icon: Icon(icon, size: 20),
      );
    }
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox.square(
        dimension: 44,
        child: cu.CupertinoButton(
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: onPressed,
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surface,
              border: Border.all(
                color: enabled
                    ? colors.outlineVariant
                    : colors.onSurface.withValues(alpha: 0.12),
                width: 1.5,
              ),
            ),
            child: SizedBox.square(
              dimension: 44,
              child: Icon(
                icon,
                size: 20,
                color: enabled
                    ? colors.onSurface
                    : colors.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

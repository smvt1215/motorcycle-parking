import 'package:material_ui/material_ui.dart';

import '../models/parking.dart';

/// A pill choice shared by the app's forms and the admin site (closure
/// canvas, decision 41): selecting one changes only its fill, its outline
/// and the outline's weight — no check mark and no bolder text — so it
/// keeps its width and the row never jumps. 40 px tall inside a 48 px
/// target.
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.tooltip,
  });
  final String label;
  final bool selected;

  /// Null when the choice is not available now.
  final VoidCallback? onTap;

  /// A longer name for screen readers, when [label] is short.
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    // The outline thickens inside the pill, so it is the same size either
    // way.
    // Thinner than 2 px, which only the fee board preview draws.
    final border = selected ? 1.5 : 1.0;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: tooltip,
      excludeSemantics: tooltip != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected ? colors.primaryContainer : colors.surface,
                border: Border.all(
                  color: selected ? colors.primary : colors.outlineVariant,
                  width: border,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Padding(
                  // A DecoratedBox paints its border over the child, so the
                  // padding stays the same either way.
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  // As wide as its label; long labels wrap.
                  child: Align(
                    widthFactor: 1,
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? colors.onPrimaryContainer
                            : enabled
                            ? colors.onSurface
                            : colors.onSurface.withValues(alpha: .38),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of [OptionPill]s for one choice; [values] pairs each value with its
/// label. Wraps on narrow screens.
class OptionPills<T> extends StatelessWidget {
  const OptionPills({
    super.key,
    required this.values,
    required this.selected,
    required this.onSelect,
    this.keyOf,
    this.disabled = const {},
  });
  final List<(T, String)> values;
  final T selected;
  final ValueChanged<T>? onSelect;

  /// The widget key of each pill, for tests.
  final String Function(T)? keyOf;
  final Set<T> disabled;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      for (final (value, text) in values)
        OptionPill(
          key: keyOf == null ? null : ValueKey(keyOf!(value)),
          label: text,
          selected: value == selected,
          onTap: onSelect == null || disabled.contains(value)
              ? null
              : () => onSelect!(value),
        ),
    ],
  );
}

/// A vehicle's three states on one row (C6 canvas AppPatterns, pattern 4):
/// 未確認／可停／不可停 as joined segments, the label beside them. Each
/// segment is a 48 px target.
class VehicleTriState extends StatelessWidget {
  const VehicleTriState({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.keyPrefix,
    this.disabled = const {},
  });
  final String label;
  final bool? value;
  final ValueChanged<bool?>? onChanged;

  /// States shown but not available now.
  final Set<bool?> disabled;

  /// Prefix of each segment's widget key, for tests.
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) => VehicleSegments<bool?>(
    label: label,
    value: value,
    options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
    onChanged: onChanged,
    keyPrefix: keyPrefix,
    disabled: disabled,
  );
}

/// A vehicle's eligibility as a form states it (#201): 可停、不可停, or
/// 官方未標示 where the official data (for a lot, its operator's notice too)
/// does not say. Null is none picked yet, which a form never sends.
class EligibilityChoice extends StatelessWidget {
  const EligibilityChoice({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.notStated = true,
    this.keyPrefix,
  });
  final String label;
  final Eligible? value;
  final ValueChanged<Eligible>? onChanged;

  /// Whether 官方未標示 is offered: a street bay a rider reports is 可停 or
  /// 不可停 only.
  final bool notStated;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) => VehicleSegments<Eligible?>(
    label: label,
    value: value,
    options: [
      for (final e in Eligible.values)
        if (notStated || e != Eligible.notStated) (e, e.label),
    ],
    onChanged: onChanged == null ? null : (v) => onChanged!(v!),
    keyPrefix: keyPrefix,
  );
}

/// [options] as joined segments on one row, [label] beside them; the one
/// equal to [value] is selected (none when no option is).
class VehicleSegments<T> extends StatelessWidget {
  const VehicleSegments({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.keyPrefix,
    this.disabled = const {},
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final Set<T> disabled;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
        Semantics(
          label: label,
          container: true,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (i, (v, text)) in options.indexed) ...[
                  if (i > 0)
                    SizedBox(
                      width: 1,
                      height: 48,
                      child: ColoredBox(color: colors.outlineVariant),
                    ),
                  // Narrow screens: segments share the row and their labels
                  // wrap rather than overflow.
                  Flexible(
                    child: Semantics(
                      button: true,
                      selected: v == value,
                      enabled: !disabled.contains(v),
                      child: InkWell(
                        key: keyPrefix == null
                            ? null
                            : ValueKey('$keyPrefix-${v is Enum ? v.name : v}'),
                        onTap: onChanged == null || disabled.contains(v)
                            ? null
                            : () => onChanged!(v),
                        child: Container(
                          constraints: const BoxConstraints(
                            minHeight: 48,
                            minWidth: 64,
                          ),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          color: v == value ? colors.primaryContainer : null,
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: v == value
                                  ? colors.onPrimaryContainer
                                  : disabled.contains(v)
                                  ? colors.onSurface.withValues(alpha: .38)
                                  : colors.onSurface,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One choice of several that may all apply (C6 canvas AppPatterns,
/// pattern 3): a check box and its label on a row the whole of which is a
/// 48 px target. What a tick asks next goes indented under it, by the
/// caller.
class OptionCheck extends StatelessWidget {
  const OptionCheck({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });
  final String label;
  final bool value;

  /// Null when the choice is not available now.
  final ValueChanged<bool>? onChanged;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    return MergeSemantics(
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Checkbox(
                value: value,
                onChanged: enabled ? (v) => onChanged!(v ?? false) : null,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 15,
                          color: enabled
                              ? colors.onSurface
                              : colors.onSurface.withValues(alpha: .38),
                        ),
                      ),
                      if (subtitle case final subtitle?)
                        Text(
                          subtitle,
                          style: TextStyle(
                            fontSize: 13,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

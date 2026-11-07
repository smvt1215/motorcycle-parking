// Pieces only the report forms use (#190 N1, S1, S1b, S2, S3, S3b, S4): the
// grouped entry list, the dashed add row, the bay grid, the vehicle choice,
// the disabled photo button, the change summary and the remove button. The
// pieces every form shares are in lib/ui/adaptive/form_components.dart.
import 'dart:ui' show PathMetric;

import '../../models/parking.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/vehicle_marks.dart';
import '../map/space_type_sheet.dart';
import 'entry_drafts.dart';

/// iOS rows are 44 tall at least, Android's 48.
double get _touch => isCupertino ? 44 : 48;

/// How an [EntryTag] is painted.
enum EntryTagTone { neutral, ok, conditional, denied, unknown, fee }

/// A short label on an [EntryRow]: 普機 可停、重機 不能停.
class EntryTag extends StatelessWidget {
  const EntryTag(this.text, {super.key, this.tone = EntryTagTone.neutral});
  final String text;
  final EntryTagTone tone;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final colors = Theme.of(context).colorScheme;
    final (Color back, Color ink) = dark
        ? switch (tone) {
            EntryTagTone.ok => (
              const Color(0xff1d3a2e),
              const Color(0xff9fd8bb),
            ),
            EntryTagTone.conditional => (
              const Color(0xff3f3019),
              const Color(0xffe9c27a),
            ),
            EntryTagTone.fee => (colors.onSurface, colors.surface),
            _ => (colors.surfaceContainerHigh, colors.onSurfaceVariant),
          }
        : switch (tone) {
            EntryTagTone.ok => (const Color(0xffe7f1ec), allowedColor),
            EntryTagTone.conditional => (
              const Color(0xfffbf0dd),
              const Color(0xff6b4400),
            ),
            EntryTagTone.fee => (const Color(0xff16313a), Colors.white),
            EntryTagTone.unknown => (
              Colors.transparent,
              const Color(0xff59646c),
            ),
            _ => (const Color(0xfff3f5f6), const Color(0xff59646c)),
          };
    final label = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(text, style: TextStyle(fontSize: 12.5, color: ink)),
    );
    final radius = BorderRadius.circular(12);
    return tone == EntryTagTone.unknown
        ? CustomPaint(
            painter: _DashedBorder(color: ink, radius: 12),
            child: label,
          )
        : DecoratedBox(
            decoration: BoxDecoration(color: back, borderRadius: radius),
            child: label,
          );
  }
}

/// A row that opens a sub-page: an icon or marking, the title with a line
/// under it, tags, what it holds now, and a chevron. Without [onTap] it only
/// shows.
class EntryRow extends StatelessWidget {
  const EntryRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.value,
    this.tags = const [],
    this.destructive = false,
    this.problem,
    this.onTap,
  });
  final Widget? leading;
  final String title;
  final String? subtitle, value;
  final List<EntryTag> tags;
  final bool destructive;

  /// What must be fixed here (C1), under the title in the error colour.
  final String? problem;
  final VoidCallback? onTap;

  Widget _value(TextStyle style) => Text(
    value!,
    textAlign: TextAlign.end,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: style,
  );

  Widget _column(TextStyle muted, ColorScheme colors) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: destructive ? colors.error : colors.onSurface,
        ),
      ),
      if (subtitle != null) ...[
        const SizedBox(height: 2),
        Text(subtitle!, style: muted),
      ],
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: tags),
      ],
      if (problem != null) ...[
        const SizedBox(height: 4),
        Text(problem!, style: TextStyle(fontSize: 13, color: colors.error)),
      ],
    ],
  );

  /// A short title hugs its text and leaves the row to the value, which is
  /// often a whole sentence of rates.
  Widget _titleAndValue(TextStyle muted, ColorScheme colors) => LayoutBuilder(
    builder: (context, box) => Row(
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box.maxWidth * .55),
          child: _column(muted, colors),
        ),
        const SizedBox(width: 8),
        Expanded(child: _value(muted)),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final enabled = onTap != null;
    return Semantics(
      button: enabled,
      enabled: enabled,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: _touch + 12),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              children: [
                if (leading != null) ...[
                  ExcludeSemantics(child: leading!),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: value != null && subtitle == null && tags.isEmpty
                      ? _titleAndValue(muted, colors)
                      : Row(
                          children: [
                            Expanded(flex: 3, child: _column(muted, colors)),
                            if (value != null) ...[
                              const SizedBox(width: 8),
                              Expanded(flex: 2, child: _value(muted)),
                            ],
                          ],
                        ),
                ),
                if (enabled)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.chevron_right,
                      size: 22,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [rows] in one outlined card, with an optional small heading above and a
/// line below; rows are parted by hairlines.
class EntrySection extends StatelessWidget {
  const EntrySection({super.key, this.header, required this.rows, this.footer});
  final String? header;
  final List<Widget> rows;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              header: true,
              child: Text(
                header!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        Material(
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, row) in rows.indexed) ...[
                if (i > 0) Divider(height: 1, color: colors.outlineVariant),
                row,
              ],
            ],
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              footer!,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final PathMetric metric in outline.computeMetrics()) {
      for (var at = 0.0; at < metric.length; at += 8) {
        canvas.drawPath(metric.extractPath(at, at + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.radius != radius;
}

/// A dashed row that adds something: ＋ 新增一區.
class AddEntryButton extends StatelessWidget {
  const AddEntryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = onPressed == null
        ? colors.onSurface.withValues(alpha: .38)
        : colors.primary;
    return Semantics(
      button: true,
      enabled: onPressed != null,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: CustomPaint(
          painter: _DashedBorder(color: colors.outline, radius: 14),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: _touch),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 20, color: color),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(label, style: TextStyle(color: color)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The seven bay kinds as a 3-column grid (S2, S4): the marking over its
/// name, one selected. At large text sizes it falls back to the list.
class BayKindGrid extends StatelessWidget {
  const BayKindGrid({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel = '格位類型',
  });
  final SpaceKind? value;
  final ValueChanged<SpaceKind> onChanged;
  final String semanticLabel;

  static const kinds = [
    SpaceKind.motorcycle,
    SpaceKind.scooterHeavy,
    SpaceKind.heavy,
    SpaceKind.carMotorcycle,
    SpaceKind.car,
    SpaceKind.disabled,
    SpaceKind.ev,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (MediaQuery.textScalerOf(context).scale(16) > 24) {
      return SpaceKindList(
        value: value,
        keyPrefix: 'bay',
        kinds: kinds,
        onChanged: onChanged,
      );
    }
    Widget tile(SpaceKind kind) {
      final selected = kind == value;
      return Semantics(
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        label: kind.label,
        excludeSemantics: true,
        child: Material(
          color: colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? brand : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('bay-${kind.name}'),
            onTap: () => onChanged(kind),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 92),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GroundMarking(
                      type: kind.markingType,
                      shared: kind == SpaceKind.scooterHeavy,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      kind.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: semanticLabel,
      container: true,
      child: Column(
        children: [
          for (var i = 0; i < kinds.length; i += 3)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var j = i; j < i + 3; j++) ...[
                      if (j > i) const SizedBox(width: 8),
                      Expanded(
                        child: j < kinds.length
                            ? tile(kinds[j])
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Who may park: the class's plates and name over one row of choices. iOS
/// fills the selected segment with its verdict's colour; Android marks it
/// with a check, as an M3 segmented button does.
class EligibilitySegments extends StatelessWidget {
  const EligibilitySegments({
    super.key,
    required this.vehicle,
    required this.value,
    required this.onChanged,
    this.notStated = true,
    this.error,
    this.keyPrefix,
  });
  final VehicleType vehicle;
  final Eligible? value;
  final ValueChanged<Eligible> onChanged;

  /// Whether 官方未標示 is offered: a lot's; a street bay is 可停 or 不可停.
  final bool notStated;
  final String? error;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final cupertino = isCupertino;
    Color? fill(Eligible e) => switch (e) {
      Eligible.allowed when cupertino => allowedColor,
      Eligible.notAllowed when cupertino => deniedColor,
      _ => cupertino ? colors.surfaceContainerHighest : colors.primaryContainer,
    };
    Color ink(Eligible e, bool selected) => !selected
        ? colors.onSurface
        : cupertino && e != Eligible.notStated
        ? Colors.white
        : cupertino
        ? colors.onSurface
        : colors.onPrimaryContainer;
    final options = [
      for (final e in Eligible.values)
        if (notStated || e != Eligible.notStated) e,
    ];
    final radius = BorderRadius.circular(cupertino ? 10 : 24);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            ExcludeSemantics(child: SmallPlateStack(plates: platesOf(vehicle))),
            const SizedBox(width: 6),
            Expanded(child: Text(vehicle.label)),
          ],
        ),
        const SizedBox(height: 6),
        Semantics(
          label: '${vehicle.label}能不能停',
          container: true,
          child: Container(
            padding: EdgeInsets.all(cupertino ? 2 : 0),
            decoration: BoxDecoration(
              color: cupertino ? colors.surfaceContainerHigh : null,
              border: cupertino ? null : Border.all(color: colors.outline),
              borderRadius: radius,
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, e) in options.indexed) ...[
                      if (i > 0 && !cupertino)
                        VerticalDivider(width: 1, color: colors.outline),
                      Expanded(
                        child: Semantics(
                          button: true,
                          inMutuallyExclusiveGroup: true,
                          selected: e == value,
                          child: Material(
                            color: e == value ? fill(e) : Colors.transparent,
                            child: InkWell(
                              key: keyPrefix == null
                                  ? null
                                  : ValueKey('$keyPrefix-${e.name}'),
                              onTap: () => onChanged(e),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: _touch),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 6,
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      if (!cupertino && e == value) ...[
                                        Icon(
                                          Icons.check,
                                          size: 16,
                                          color: ink(e, true),
                                        ),
                                        const SizedBox(width: 4),
                                      ],
                                      Flexible(
                                        child: Text(
                                          e.label,
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: e == value
                                                ? FontWeight.w700
                                                : FontWeight.w400,
                                            color: ink(e, e == value),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
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
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error!,
              style: TextStyle(fontSize: 13, color: colors.error),
            ),
          ),
      ],
    );
  }
}

/// 你要改的內容 for one entry: its name, then each value struck through and
/// its new one.
class ChangeSummary extends StatelessWidget {
  const ChangeSummary({super.key, this.title, required this.lines});
  final String? title;
  final List<ChangeLine> lines;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                title!,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Semantics(
                label: '${line.label}從${line.from}改成${line.to}',
                excludeSemantics: true,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: '${line.label}　'),
                      TextSpan(
                        text: line.from,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                      const TextSpan(text: '　→　'),
                      TextSpan(
                        text: line.to,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A red outlined button with what pressing it means under it.
class RemoveEntryButton extends StatelessWidget {
  const RemoveEntryButton({
    super.key,
    required this.label,
    this.note,
    required this.onPressed,
    this.icon = Icons.block,
  });
  final String label;
  final String? note;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: Size(48, _touch),
            foregroundColor: colors.error,
            side: BorderSide(color: colors.error),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(isCupertino ? 12 : 24),
            ),
          ),
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              note!,
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

/// 路外停車場 or 路邊格位 as two cards (N1); neither until the rider picks.
class SpotKindCards extends StatelessWidget {
  const SpotKindCards({
    super.key,
    required this.offStreet,
    required this.onChanged,
    this.error,
  });
  final bool? offStreet;
  final ValueChanged<bool> onChanged;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget card(bool lot, IconData icon, String title, String detail) {
      final selected = offStreet == lot;
      return Semantics(
        button: true,
        inMutuallyExclusiveGroup: true,
        selected: selected,
        child: Material(
          color: colors.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
              color: selected
                  ? brand
                  : error != null
                  ? colors.error
                  : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            key: ValueKey('spot-kind-${lot ? 'lot' : 'street'}'),
            onTap: () => onChanged(lot),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 96),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 28),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      detail,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: '停車點種類',
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: card(true, Icons.local_parking, '路外停車場', '地下、立體、平面'),
                ),
                const SizedBox(width: 8),
                Expanded(child: card(false, Icons.add_road, '路邊格位', '馬路旁的格位')),
              ],
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error!,
                style: TextStyle(fontSize: 13, color: colors.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small field title with an optional aside: 哪些車種可停？ 改這一區時….
class FormLabel extends StatelessWidget {
  const FormLabel(this.title, {super.key, this.aside});
  final String title;
  final String? aside;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (aside != null)
            TextSpan(
              text: '　$aside',
              style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

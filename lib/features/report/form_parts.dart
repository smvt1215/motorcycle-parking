// Pieces only the report forms use (#190 N1, S1, S1b, S2, S3, S3b, S4): the
// grouped entry list, the dashed add row, the bay grid, the vehicle choice,
// the disabled photo button, the change summary and the remove button. The
// pieces every form shares are in lib/ui/adaptive/form_components.dart.
import 'dart:ui' show PathMetric;

import '../../models/parking.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/vehicle_marks.dart';
import '../../ui/text_wrap.dart';
import '../map/space_type_sheet.dart';
import 'entry_drafts.dart';
import 'entry_pages.dart' show SendProblem;

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
    this.quote,
    this.sentTag,
    this.onTap,
  });

  /// A suggestion for this row went while the list was open (S6): the
  /// mark under the title, 「已送出，審核中」 or 範例模式's. The value
  /// beside it is still the map's, which changes only after review.
  final String? sentTag;

  bool get sent => sentTag != null;

  /// A stored text with what it is: (這區寫, the text). At most two lines
  /// on screen; a screen reader hears all of it.
  final (String, String)? quote;
  final Widget? leading;
  final String title;
  final String? subtitle, value;
  final List<EntryTag> tags;
  final bool destructive;

  /// What must be fixed here (C1), under the title in the error colour.
  final String? problem;
  final VoidCallback? onTap;

  // Neither the title nor the value ends on one lone character (#467).
  Widget _value(TextStyle style) => NoOrphanText(
    value!,
    textAlign: TextAlign.end,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: style,
  );

  /// [stacked] puts the value under the title, for large text (S6d ②).
  Widget _column(
    TextStyle muted,
    ColorScheme colors, {
    bool stacked = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      NoOrphanText(
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
      if (stacked && value != null) ...[
        const SizedBox(height: 2),
        Text(value!, style: muted),
      ],
      if (sentTag case final tag?) ...[const SizedBox(height: 5), SentTag(tag)],
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 4, children: tags),
      ],
      if (quote case (final label, final text)?) ...[
        const SizedBox(height: 2),
        Semantics(
          label: '$label，$text',
          excludeSemantics: true,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '$label：', style: muted),
                TextSpan(
                  text: text,
                  style: TextStyle(fontSize: 13, color: colors.onSurface),
                ),
              ],
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
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
    // A sent row in large text reads title, value, mark from top to bottom,
    // so the mark is never squeezed beside a long value (S6d ②).
    final stacked = sent && MediaQuery.textScalerOf(context).scale(16) > 20;
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
                  child: stacked
                      ? _column(muted, colors, stacked: true)
                      : value != null && subtitle == null && tags.isEmpty
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

/// The tints of 審核中 (P9's plate), light and dark (S6d ①): what was sent
/// waits for review, so never the green of 可停.
(Color, Color) reviewingTint(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? (const Color(0xff16343c), const Color(0xff9fe0ec))
    : (const Color(0xffe3f0f2), const Color(0xff0f4e5c));

/// 「✓ 已送出，審核中」 on a row whose suggestion went (S6); [text] is
/// 範例模式's wording where nothing was really sent.
class SentTag extends StatelessWidget {
  const SentTag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final (back, ink) = reviewingTint(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: back,
        borderRadius: BorderRadius.circular(isCupertino ? 6 : 8),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check, size: 14, color: ink),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.35,
                  color: ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The confirmation at the top of the list once a suggestion went (S6):
/// what was sent and that the map waits for review. Announced when it
/// appears or changes.
class SentBanner extends StatelessWidget {
  const SentBanner({super.key, required this.title, required this.body});
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final (back, ink) = reviewingTint(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: back,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(Icons.check_circle, size: 24, color: ink),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      body,
                      style: TextStyle(fontSize: 13, height: 1.5, color: ink),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Why the suggestion did not go, fixed above the send button (S6b ②③)
/// and announced: a title, what to do next, and an icon that tells no
/// network from other failures without relying on colour.
class SendProblemNote extends StatelessWidget {
  const SendProblemNote(this.problem, {super.key, required this.button});
  final SendProblem problem;

  /// The send button's label, as the note names it.
  final String button;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    // P9's 未採納 tint in light; in dark the theme's error on its own wash,
    // as FormInfoNote paints an error.
    final ink = dark ? colors.error : const Color(0xff7a1f2e);
    final back = dark
        ? Color.alphaBlend(colors.error.withValues(alpha: .16), colors.surface)
        : const Color(0xfffbecee);
    return Semantics(
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        key: const ValueKey('send-problem'),
        decoration: BoxDecoration(
          color: back,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  problem.offline ? Icons.wifi_off : Icons.error_outline,
                  key: ValueKey(
                    problem.offline ? 'send-offline' : 'send-failed',
                  ),
                  size: 22,
                  color: ink,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      problem.title,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.4,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      problem.body(button),
                      style: TextStyle(fontSize: 13, height: 1.5, color: ink),
                    ),
                  ],
                ),
              ),
            ],
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

/// [child] in a dashed card: a list's 全區 or 整條路 row (Z1, F0's 全場費率).
class EntryDashedCard extends StatelessWidget {
  const EntryDashedCard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _DashedBorder(
      color: Theme.of(context).colorScheme.outline,
      radius: 16,
    ),
    child: ClipRRect(borderRadius: BorderRadius.circular(16), child: child),
  );
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
    // A label column keeps wrapped lines under the change; large text needs
    // the width more.
    final wide = MediaQuery.textScalerOf(context).scale(16) <= 20;
    TextSpan change(ChangeLine line) => TextSpan(
      children: [
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
    );
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
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 64, child: Text(line.label)),
                          Expanded(child: Text.rich(change(line))),
                        ],
                      )
                    : Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: '${line.label}　'),
                            change(line),
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

/// The notice link a suggestion carries (F1c), with its own [Form] so a page
/// checks it alone. Above 你要改的內容, and only with it.
class SuggestionLink extends StatelessWidget {
  const SuggestionLink({
    super.key,
    required this.form,
    required this.controller,
    required this.field,
  });
  final GlobalKey<FormState> form;
  final TextEditingController controller;

  /// The field itself, built by the form that owns it.
  final Widget field;

  /// False, with the error shown and the field in view, when the link
  /// cannot go.
  static bool check(GlobalKey<FormState> form) {
    if (form.currentState?.validate() ?? true) return true;
    final at = form.currentContext;
    if (at != null) {
      Scrollable.ensureVisible(
        at,
        alignment: .2,
        duration: const Duration(milliseconds: 250),
      );
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Form(key: form, child: field),
  );
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

/// One rule of S5 or a card that folds the same way: its icon, title and
/// summary in a row of 60 at least, and [child] while [open]. Long summaries
/// wrap; the title does not (C17).
class RuleFoldCard extends StatelessWidget {
  const RuleFoldCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.summary,
    this.badge,
    this.badgeColor,
    required this.open,
    required this.onToggle,
    required this.child,
  });
  final IconData icon;
  final Color iconColor;
  final String title, summary;

  /// 修改中, 將移除; a new spot shows none (C14).
  final String? badge;
  final Color? badgeColor;
  final bool open;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: open ? brand : colors.outlineVariant,
          width: open ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 60),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
                  child: Row(
                    children: [
                      ExcludeSemantics(child: Icon(icon, color: iconColor)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              summary,
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (badge != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          badge!,
                          style: TextStyle(
                            fontSize: 13,
                            color: badgeColor ?? colors.primary,
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      Icon(
                        open ? Icons.expand_less : Icons.expand_more,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (open) ...[
            Divider(height: 1, color: colors.outlineVariant),
            Padding(padding: const EdgeInsets.all(12), child: child),
          ],
        ],
      ),
    );
  }
}

/// A tile that is on or off: a day, a preset, an entry a rule covers.
class ChoiceTile extends StatelessWidget {
  const ChoiceTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.exclusive = false,
    this.tooltip,
    this.radius = 10,
  });
  final String label;
  final bool selected, exclusive;
  final VoidCallback onTap;
  final String? tooltip;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = BorderRadius.circular(radius);
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: exclusive,
      selected: exclusive ? selected : null,
      toggled: exclusive ? null : selected,
      label: tooltip ?? label,
      excludeSemantics: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: shape,
          side: BorderSide(
            color: selected ? brand : colors.outlineVariant,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: _touch, minWidth: _touch),
            child: Center(
              widthFactor: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurface,
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

/// 管哪幾區 and 管哪幾段: everything, or some entries. From everything, a tap
/// on one entry leaves that one; picking the last one is everything again.
class ScopeChips extends StatelessWidget {
  const ScopeChips({
    super.key,
    required this.allLabel,
    required this.items,
    required this.all,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });
  final String allLabel;

  /// Each entry with its chip: B1 機車區・一般機車格.
  final List<(Object, String)> items;
  final bool all;
  final Set<Object> value;
  final void Function(bool all, Set<Object> value) onChanged;
  final String semanticLabel;

  void _toggle(Object id) {
    final next = all ? {id} : {...value};
    if (!all) next.contains(id) ? next.remove(id) : next.add(id);
    // Every entry named is everything, a spot of one entry too.
    if (next.length == items.length) return onChanged(true, const {});
    onChanged(false, next);
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    container: true,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceTile(
          key: const ValueKey('rule-scope-all'),
          label: allLabel,
          selected: all,
          radius: 22,
          onTap: () => onChanged(!all, const {}),
        ),
        for (final (i, (id, text)) in items.indexed)
          ChoiceTile(
            key: ValueKey('rule-scope-$i'),
            label: text,
            selected: !all && value.contains(id),
            radius: 22,
            onTap: () => _toggle(id),
          ),
      ],
    ),
  );
}

const _weekNames = '一二三四五六日';
const _weekWires = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

/// 哪幾天 (S5): 每天、平日、假日, or weekdays picked one by one. [days] is
/// the contract's: `all`, `weekday`, `holiday` or a list of weekdays.
class DaysPicker extends StatelessWidget {
  const DaysPicker({super.key, required this.days, required this.onChanged});
  final Object days;
  final ValueChanged<Object> onChanged;

  void _toggle(String day) {
    final now = days is List ? days as List<String> : const <String>[];
    final next = now.contains(day)
        ? [...now.where((d) => d != day)]
        : [
            for (final d in _weekWires)
              if (d == day || now.contains(d)) d,
          ];
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const gap = 4.0;
    final picked = days is List ? days as List<String> : const <String>[];
    Widget preset(String wire, String label) => ChoiceTile(
      key: ValueKey('rule-days-$wire'),
      label: label,
      selected: days == wire,
      exclusive: true,
      onTap: () => onChanged(wire),
    );
    Widget day(int i) => ChoiceTile(
      key: ValueKey('rule-day-$i'),
      label: _weekNames[i],
      tooltip: '週${_weekNames[i]}',
      selected: picked.contains(_weekWires[i]),
      onTap: () => _toggle(_weekWires[i]),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: '常用天數',
          container: true,
          child: Row(
            children: [
              Expanded(child: preset('all', '每天')),
              const SizedBox(width: 8),
              Expanded(child: preset('weekday', '平日')),
              const SizedBox(width: 8),
              Expanded(child: preset('holiday', '假日')),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '或自選星期',
          style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Semantics(
          label: '自選星期',
          container: true,
          child: LayoutBuilder(
            // The tiles keep their height; on a 390 phone seven fit at 44 wide.
            builder: (context, box) => box.maxWidth < 44 * 7 + gap * 6
                ? Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (var i = 0; i < 7; i++)
                        SizedBox(width: _touch, child: day(i)),
                    ],
                  )
                : Row(
                    children: [
                      for (var i = 0; i < 7; i++) ...[
                        if (i > 0) const SizedBox(width: gap),
                        Expanded(child: day(i)),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

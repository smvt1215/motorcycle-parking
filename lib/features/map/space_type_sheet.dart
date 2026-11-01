import 'dart:math' as math;

import '../../models/parking.dart';
import '../../domain/map_filter_display.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import 'map_legend.dart';

/// Filters the map by bay kind (#188, design canvas P1): any number of the
/// seven bay kinds and the lot, none picked being 全部格位. Each option
/// shows its ground marking and how many spots of that kind the current
/// map view holds; a pick applies at once and the sheet stays open.
Future<void> showSpaceTypeSheet(
  BuildContext context, {
  required Set<SpaceKind> value,
  required Map<SpaceKind?, int> counts,
  required ValueChanged<Set<SpaceKind>> onChanged,
}) {
  var picked = value;
  return showAdaptiveSheet<void>(
    context,
    (ctx) => StatefulBuilder(
      builder: (ctx, setState) => _SpaceKindSheet(
        value: picked,
        counts: counts,
        onChanged: (kinds) {
          setState(() => picked = kinds);
          onChanged(kinds);
        },
      ),
    ),
  );
}

class _SpaceKindSheet extends StatelessWidget {
  const _SpaceKindSheet({
    required this.value,
    required this.counts,
    required this.onChanged,
  });
  final Set<SpaceKind> value;
  final Map<SpaceKind?, int> counts;
  final ValueChanged<Set<SpaceKind>> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = _MultiPalette.of(context);
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.fromLTRB(0, isCupertino ? 16 : 0, 0, 34),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        spaceKindSheetTitle,
                        style: text.headlineSmall?.copyWith(
                          fontSize: 22,
                          fontWeight: isCupertino
                              ? FontWeight.w700
                              : FontWeight.w400,
                          color: palette.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        spaceKindSheetLead,
                        style: TextStyle(
                          fontSize: isCupertino ? 13 : 14,
                          height: 1.45,
                          color: palette.lead,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _CloseButton(palette: palette),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SpaceKindMultiList(
            value: value,
            counts: counts,
            onChanged: onChanged,
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              spaceKindSummary(value),
              key: const ValueKey('space-summary'),
              style: TextStyle(fontSize: 12, color: palette.lead),
            ),
          ),
        ],
      ),
    );
  }
}

/// The sheet's close button: a grey 44pt circle on iOS (P1-ios), a 48dp
/// icon button on Android, so the sheet never needs a drag to close.
class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.palette});
  final _MultiPalette palette;

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.pop(context);
    if (!isCupertino) {
      return IconButton(
        tooltip: '關閉',
        onPressed: close,
        style: IconButton.styleFrom(minimumSize: const Size.square(48)),
        icon: const Icon(Icons.close),
      );
    }
    return Semantics(
      button: true,
      label: '關閉',
      onTap: close,
      excludeSemantics: true,
      child: Tooltip(
        message: '關閉',
        child: Material(
          color: palette.closeFill,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: close,
            child: SizedBox.square(
              dimension: 44,
              child: Icon(Icons.close, size: 20, color: palette.closeInk),
            ),
          ),
        ),
      ),
    );
  }
}

/// The colours of P1: the board's own in the light theme, the scheme's in
/// the dark one.
class _MultiPalette {
  const _MultiPalette({
    required this.ink,
    required this.lead,
    required this.accent,
    required this.band,
    required this.card,
    required this.divider,
    required this.pickedRow,
    required this.allTile,
    required this.boxEdge,
    required this.closeFill,
    required this.closeInk,
  });

  factory _MultiPalette.of(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (colors.brightness == Brightness.dark) {
      return _MultiPalette(
        ink: colors.onSurface,
        lead: colors.onSurfaceVariant,
        accent: colors.primary,
        band: colors.surfaceContainerLow,
        card: colors.surfaceContainerHigh,
        divider: colors.outlineVariant,
        pickedRow: colors.primaryContainer,
        allTile: colors.secondaryContainer,
        boxEdge: colors.onSurfaceVariant,
        closeFill: colors.surfaceContainerHighest,
        closeInk: colors.onSurface,
      );
    }
    return const _MultiPalette(
      ink: Color(0xff16313a),
      lead: Color(0xff59646c),
      accent: Color(0xff176273),
      band: Color(0xfff2f2f7),
      card: Colors.white,
      divider: Color(0xffe5e5ea),
      pickedRow: Color(0xffddeff3),
      allTile: Color(0xffe3f0f2),
      boxEdge: Color(0xff3e4a50),
      closeFill: Color(0x1f767680),
      closeInk: Color(0xff3c3c43),
    );
  }
  final Color ink, lead, accent, band, card, divider, pickedRow, allTile;
  final Color boxEdge, closeFill, closeInk;
}

/// The multiple-choice list of the map filter (P1): 全部格位, then the
/// seven bay kinds and the lot in [SpaceKind] order, each a checkbox.
/// Picking 全部格位 clears [value]; unpicking the last kind returns to it.
/// The single-choice [SpaceKindList] stays for the forms and the admin
/// site. iOS draws an inset grouped list with trailing checkmarks, Android
/// full-width rows with a tinted pick and a leading-edge checkbox.
class SpaceKindMultiList extends StatelessWidget {
  const SpaceKindMultiList({
    super.key,
    required this.value,
    required this.onChanged,
    this.counts,
  });

  /// The picked kinds; empty is 全部格位.
  final Set<SpaceKind> value;
  final ValueChanged<Set<SpaceKind>> onChanged;

  /// Spots of each kind in the map view, null for all; null shows none.
  final Map<SpaceKind?, int>? counts;

  @override
  Widget build(BuildContext context) {
    final palette = _MultiPalette.of(context);
    final rows = <Widget>[
      _SpaceKindCheckRow(
        key: const ValueKey('space-multi-all'),
        kind: null,
        count: counts?[null],
        checked: value.isEmpty,
        palette: palette,
        divider: false,
        onTap: () => onChanged(const {}),
      ),
      for (final kind in SpaceKind.values)
        _SpaceKindCheckRow(
          key: ValueKey('space-multi-${kind.name}'),
          kind: kind,
          count: counts?[kind],
          checked: value.contains(kind),
          palette: palette,
          divider: true,
          onTap: () => onChanged(
            value.contains(kind)
                ? ({...value}..remove(kind))
                : {...value, kind},
          ),
        ),
    ];
    final group = Semantics(
      container: true,
      explicitChildNodes: true,
      label: spaceKindGroupLabel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
    if (!isCupertino) return group;
    return ColoredBox(
      color: palette.band,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(color: palette.card, child: group),
        ),
      ),
    );
  }
}

class _SpaceKindCheckRow extends StatelessWidget {
  const _SpaceKindCheckRow({
    super.key,
    required this.kind,
    required this.count,
    required this.checked,
    required this.palette,
    required this.divider,
    required this.onTap,
  });

  /// Null is 全部格位.
  final SpaceKind? kind;
  final int? count;
  final bool checked;
  final _MultiPalette palette;

  /// The iOS hairline above the row.
  final bool divider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final kind = this.kind;
    final label = kind?.label ?? allSpaceKindsLabel;
    final count = this.count;
    final cupertino = isCupertino;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ExcludeSemantics(
              child: kind == null
                  ? Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: palette.allTile,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(Icons.apps, size: 24, color: palette.accent),
                    )
                  : GroundMarking(
                      type: kind.markingType,
                      shared: kind == SpaceKind.scooterHeavy,
                      size: 44,
                      radius: 6,
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: cupertino ? 17 : 16,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    kind?.detail ?? allSpaceKindsDetail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: palette.lead),
                  ),
                ],
              ),
            ),
            if (count != null) ...[
              const SizedBox(width: 14),
              Text(
                '$count',
                style: TextStyle(
                  fontFamily: 'Outfit',
                  fontSize: 15,
                  color: palette.lead,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
            const SizedBox(width: 14),
            SizedBox.square(
              dimension: 24,
              child: Center(
                child: cupertino
                    ? Visibility.maintain(
                        visible: checked,
                        child: Icon(
                          Icons.check,
                          size: 22,
                          color: palette.accent,
                        ),
                      )
                    : _CheckBox(checked: checked, palette: palette),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      checked: checked,
      label: spaceKindRowLabel(label, count),
      // The child's tap is excluded with its semantics; screen readers
      // need it here.
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: cupertino
            ? palette.card
            : checked
            ? palette.pickedRow
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: cupertino && divider
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: palette.divider, width: .5),
                    ),
                  ),
                  child: row,
                )
              : row,
        ),
      ),
    );
  }
}

/// Android's 18dp checkbox: filled with a white check when picked, an
/// outline otherwise.
class _CheckBox extends StatelessWidget {
  const _CheckBox({required this.checked, required this.palette});
  final bool checked;
  final _MultiPalette palette;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      color: checked ? palette.accent : Colors.transparent,
      borderRadius: BorderRadius.circular(2),
      border: Border.all(
        color: checked ? palette.accent : palette.boxEdge,
        width: 2,
      ),
    ),
    child: checked
        ? Icon(
            Icons.check,
            size: 14,
            color: Theme.of(context).colorScheme.brightness == Brightness.dark
                ? Theme.of(context).colorScheme.onPrimary
                : Colors.white,
          )
        : null,
  );
}

/// The seven bay kinds and the lot (#188, design canvas S4, P1), in
/// [SpaceKind] order. [followUp] goes indented under the picked kind: what
/// the form asks about it next.
class SpaceKindList extends StatelessWidget {
  const SpaceKindList({
    super.key,
    required this.value,
    required this.onChanged,
    this.counts,
    this.followUp,
    this.keyPrefix = 'space',
    this.reveal = 0,
  });
  final SpaceKind? value;
  final ValueChanged<SpaceKind> onChanged;

  /// Spots of each kind in the map view (the filter); null shows none.
  final Map<SpaceKind?, int>? counts;
  final Widget? followUp;

  /// Prefix of each row's widget key, for tests.
  final String keyPrefix;

  /// Bumped by a form whose check failed; the list shows every kind, so
  /// the pick's follow-up is always in view.
  final int reveal;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final kind in SpaceKind.values) ...[
        SpaceKindOption(
          targetKey: ValueKey('$keyPrefix-${kind.name}'),
          kind: kind,
          count: counts?[kind],
          selected: kind == value,
          onTap: () => onChanged(kind),
        ),
        if (kind == value && followUp != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 16, bottom: 8),
            child: followUp,
          ),
      ],
    ],
  );
}

/// One bay kind: its ground marking, its name and one sentence; the whole
/// row is the target, and a pick changes only its fill and outline. Null
/// [kind] is 全部格位 (the filter).
class SpaceKindOption extends StatelessWidget {
  const SpaceKindOption({
    super.key,
    required this.kind,
    required this.selected,
    required this.onTap,
    this.count,
    this.targetKey,
  });
  final SpaceKind? kind;

  /// The key of the row's tap target, for tests.
  final Key? targetKey;
  final bool selected;
  final VoidCallback onTap;

  /// Spots of this kind in the map view; null shows none.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final label = kind?.label ?? '全部格位';
    final count = this.count;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        button: true,
        selected: selected,
        inMutuallyExclusiveGroup: true,
        label: count == null ? label : '$label，目前範圍 $count 個',
        // The child's tap is excluded with its semantics; screen readers
        // need it here.
        onTap: onTap,
        excludeSemantics: true,
        child: Material(
          color: selected ? colors.primaryContainer : colors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: selected ? colors.primary : colors.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key:
                targetKey ??
                (kind == null ? const ValueKey('space-all') : null),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 60),
              child: Padding(
                // The thicker outline sits inside, so the row keeps its size.
                padding: EdgeInsets.symmetric(
                  horizontal: selected ? 11 : 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: GroundMarking(
                        type: kind?.markingType,
                        shared: kind == SpaceKind.scooterHeavy,
                        size: 40,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: text.titleSmall?.copyWith(
                              fontSize: 15,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: selected
                                  ? colors.onPrimaryContainer
                                  : colors.onSurface,
                            ),
                          ),
                          Text(
                            kind?.detail ?? '顯示所有類型的停車點',
                            style: text.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '$count',
                        style: text.titleSmall?.copyWith(
                          color: count == 0 ? colors.outline : colors.onSurface,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
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

/// A patch of asphalt with the type's painted marking: white motorcycle
/// boxes (with a meter when paid), a yellow heavy-bike box, a wide car
/// bay, or a lot's P sign. "All" tiles the four street markings.
class GroundMarking extends StatelessWidget {
  const GroundMarking({
    super.key,
    required this.type,
    this.size = 44,
    this.shared = false,
    this.radius = 10,
  });

  /// Null with [shared] unset tiles the four street markings (全部).
  final SpaceType? type;
  final double size;

  /// 普大共用機車格: plain motorcycle bays with the heavy-bike badge's
  /// fallback glyph (two_wheeler).
  final bool shared;

  /// The patch's corner radius; P1 draws 6.
  final double radius;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CustomPaint(painter: _MarkingPainter(type, shared: shared)),
    ),
  );
}

class _MarkingPainter extends CustomPainter {
  _MarkingPainter(this.type, {this.shared = false});
  final SpaceType? type;
  final bool shared;

  static const asphalt = Color(0xff3d4247);
  static const white = Color(0xfff2f2ee);
  static const yellow = Color(0xfff2c200);
  static const disabledBlue = Color(0xff2f6fd6);
  static const evGreen = Color(0xff3fb56b);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = asphalt);
    if (shared) {
      _paintType(canvas, size, SpaceType.freeMotorcycle);
      // The heavy-only badge's fallback glyph (two_wheeler, not the
      // licensed silhouette) over the plain bays.
      _paintGlyph(
        canvas,
        size,
        spaceBadgeIcon(SpaceBadge.heavyOnly)!,
        yellow,
        .34,
      );
      return;
    }
    final type = this.type;
    if (type == null) {
      // Four quarters, one per street marking.
      final half = size / 2;
      for (final (i, quarter) in const [
        SpaceType.paidMotorcycle,
        SpaceType.heavyOnly,
        SpaceType.car,
        SpaceType.offStreet,
      ].indexed) {
        canvas.save();
        canvas.translate((i % 2) * half.width, (i ~/ 2) * half.height);
        _paintType(canvas, half, quarter, scale: .5);
        canvas.restore();
      }
      return;
    }
    _paintType(canvas, size, type);
  }

  void _paintType(
    Canvas canvas,
    Size size,
    SpaceType type, {
    double scale = 1,
  }) {
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, 2.4 * scale);
    final w = size.width, h = size.height;
    switch (type) {
      case SpaceType.paidMotorcycle || SpaceType.freeMotorcycle:
        line.color = white;
        // Two narrow bays side by side.
        canvas.drawRect(Rect.fromLTWH(w * .18, h * .2, w * .28, h * .6), line);
        canvas.drawRect(Rect.fromLTWH(w * .46, h * .2, w * .28, h * .6), line);
        if (type == SpaceType.paidMotorcycle) {
          // The meter at the kerb.
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(w * .8, h * .3, w * .1, h * .24),
              Radius.circular(2 * scale),
            ),
            Paint()..color = white,
          );
        }
      case SpaceType.heavyOnly:
        line.color = yellow;
        canvas.drawRect(
          Rect.fromLTWH(w * .22, h * .16, w * .56, h * .68),
          line,
        );
        // The heavy-only badge's fallback glyph (two_wheeler), painted in
        // the bay.
        _paintGlyph(
          canvas,
          size,
          spaceBadgeIcon(SpaceBadge.heavyOnly)!,
          yellow,
          .42,
        );
      case SpaceType.car:
        line.color = white;
        canvas.drawRect(Rect.fromLTWH(w * .1, h * .26, w * .8, h * .48), line);
        // The car of the map's car badge.
        _paintGlyph(canvas, size, spaceBadgeIcon(SpaceBadge.car)!, white, .42);
      case SpaceType.disabledMotorcycle:
        line.color = disabledBlue;
        canvas.drawRect(
          Rect.fromLTWH(w * .22, h * .16, w * .56, h * .68),
          line,
        );
        _paintGlyph(canvas, size, Icons.accessible, white, .44);
      case SpaceType.timedMotorcycle:
        line.color = white;
        canvas.drawRect(
          Rect.fromLTWH(w * .22, h * .16, w * .56, h * .68),
          line,
        );
        canvas.drawRect(
          Rect.fromLTWH(w * .3, h * .26, w * .4, h * .48),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, 1.8 * scale)
            ..color = yellow,
        );
        _paintGlyph(canvas, size, Icons.schedule, yellow, .3);
      case SpaceType.flexShared:
        // A car bay whose left half is split into motorcycle bays.
        line.color = white;
        canvas.drawRect(Rect.fromLTWH(w * .1, h * .26, w * .8, h * .48), line);
        for (final x in [w * .26, w * .42]) {
          canvas.drawLine(Offset(x, h * .26), Offset(x, h * .74), line);
        }
        _paintGlyph(
          canvas,
          // Centred on the car half (a canvas twice as wide as that half).
          Size(w * 1.36, h),
          spaceBadgeIcon(SpaceBadge.car)!,
          white,
          .3,
        );
      case SpaceType.evMotorcycle:
        line.color = evGreen;
        canvas.drawRect(
          Rect.fromLTWH(w * .22, h * .16, w * .56, h * .68),
          line,
        );
        _paintGlyph(canvas, size, Icons.bolt, evGreen, .46);
      case SpaceType.offStreet:
        final sign = RRect.fromRectAndRadius(
          Rect.fromLTWH(w * .2, h * .2, w * .6, h * .6),
          Radius.circular(4 * scale),
        );
        canvas.drawRRect(sign, Paint()..color = const Color(0xff1f5fbf));
        final painter = TextPainter(
          text: TextSpan(
            text: 'P',
            style: TextStyle(
              color: white,
              fontFamily: 'Outfit',
              fontSize: 20 * scale,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        painter.paint(
          canvas,
          Offset((w - painter.width) / 2, (h - painter.height) / 2),
        );
        painter.dispose();
    }
  }

  /// [icon] centred in the bay at [fraction] of its height.
  void _paintGlyph(
    Canvas canvas,
    Size size,
    IconData icon,
    Color color,
    double fraction,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          color: color,
          fontSize: size.height * fraction,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        (size.height - painter.height) / 2,
      ),
    );
    painter.dispose();
  }

  @override
  bool shouldRepaint(_MarkingPainter old) =>
      old.type != type || old.shared != shared;
}

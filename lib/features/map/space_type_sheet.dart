import 'dart:math' as math;

import '../../models/parking.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import 'map_legend.dart';

/// Filters the map by bay kind with the same grouped list the report forms
/// use (C6 canvas AppPatterns, pattern 1). Each option shows its ground
/// marking and how many spots of that kind the current map view holds.
Future<void> showSpaceTypeSheet(
  BuildContext context, {
  required SpaceKind? value,
  required Map<SpaceKind?, int> counts,
  Map<SpaceKindGroup, int> groupCounts = const {},
  required ValueChanged<SpaceKind?> onChanged,
}) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle('格位類型'),
      const SizedBox(height: 4),
      Text(
        '只顯示選定類型的停車點，數字為目前地圖範圍內的數量。',
        style: Theme.of(ctx).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      SpaceKindOption(
        kind: null,
        count: counts[null] ?? 0,
        selected: value == null,
        onTap: () {
          onChanged(null);
          Navigator.pop(ctx);
        },
      ),
      SpaceKindList(
        value: value,
        counts: counts,
        groupCounts: groupCounts,
        onChanged: (option) {
          onChanged(option);
          Navigator.pop(ctx);
        },
      ),
    ],
  ),
);

/// The bay kinds in their four groups (C6 canvas AppPatterns, pattern 1;
/// AppForm): each group folds, and only the one holding the pick, or the
/// one the rider opened, shows its kinds. [followUp] goes indented under
/// the picked kind: what the form asks about it next.
class SpaceKindList extends StatefulWidget {
  const SpaceKindList({
    super.key,
    required this.value,
    required this.onChanged,
    this.counts,
    this.groupCounts = const {},
    this.followUp,
    this.keyPrefix = 'space',
    this.reveal = 0,
  });
  final SpaceKind? value;
  final ValueChanged<SpaceKind> onChanged;

  /// Spots of each kind in the map view (the filter); null shows none.
  final Map<SpaceKind?, int>? counts;

  /// Distinct spots of each group in the map view, shown while it is
  /// folded: a 普大共用 bay is also a toll or free one, so the kinds' counts
  /// do not add up to it.
  final Map<SpaceKindGroup, int> groupCounts;
  final Widget? followUp;

  /// Prefix of each row's widget key, for tests.
  final String keyPrefix;

  /// Bumped by a form whose check failed: the group holding the pick opens
  /// again, so its follow-up's errors show.
  final int reveal;

  @override
  State<SpaceKindList> createState() => _SpaceKindListState();
}

class _SpaceKindListState extends State<SpaceKindList> {
  late SpaceKindGroup? open = widget.value?.group;

  @override
  void didUpdateWidget(covariant SpaceKindList old) {
    super.didUpdateWidget(old);
    if ((widget.value != old.value || widget.reveal != old.reveal) &&
        widget.value != null) {
      open = widget.value!.group;
    }
  }

  Widget _option(SpaceKind kind) => SpaceKindOption(
    targetKey: ValueKey('${widget.keyPrefix}-${kind.name}'),
    kind: kind,
    count: widget.counts?[kind],
    selected: kind == widget.value,
    onTap: () => widget.onChanged(kind),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final counts = widget.counts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final group in SpaceKindGroup.values) ...[
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.outlineVariant)),
            ),
            child: Semantics(
              button: true,
              expanded: open == group,
              child: InkWell(
                key: ValueKey('${widget.keyPrefix}-group-${group.name}'),
                onTap: () =>
                    setState(() => open = open == group ? null : group),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            group.label,
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (open != group)
                          Flexible(
                            child: Text(
                              counts == null
                                  ? group.hint
                                  : '${widget.groupCounts[group] ?? 0}',
                              textAlign: TextAlign.end,
                              style: text.bodyMedium?.copyWith(
                                color: colors.onSurfaceVariant,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                        const SizedBox(width: 8),
                        Icon(
                          open == group ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          for (final kind in group.kinds)
            if (kind == widget.value)
              // The pick and its follow-up stay mounted while the group is
              // folded, so a form still checks their fields.
              Visibility(
                visible: open == group,
                maintainState: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _option(kind),
                    if (widget.followUp != null)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 16,
                          bottom: 8,
                        ),
                        child: widget.followUp,
                      ),
                  ],
                ),
              )
            else if (open == group)
              _option(kind),
        ],
      ],
    );
  }
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
                        type: kind?.type,
                        shared: kind == SpaceKind.sharedMotorcycle,
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
  });

  /// Null with [shared] unset tiles the four street markings (全部).
  final SpaceType? type;
  final double size;

  /// 普大共用機車格: plain motorcycle bays with the heavy-bike helmet.
  final bool shared;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(10),
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
      // The helmet of the heavy-only badge over the plain bays.
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
        // The helmet of the map's heavy-only badge, painted in the bay.
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

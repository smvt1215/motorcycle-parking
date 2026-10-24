import 'dart:math' as math;

import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'map_legend.dart';

/// Filters the map by space type. Each option shows its ground marking and
/// how many spots of that type the current map view holds.
Future<void> showSpaceTypeSheet(
  BuildContext context, {
  required SpaceType? value,
  required Map<SpaceType?, int> counts,
  required ValueChanged<SpaceType?> onChanged,
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
      for (final option in <SpaceType?>[null, ...SpaceType.values])
        SpaceTypeOption(
          type: option,
          count: counts[option] ?? 0,
          selected: option == value,
          onTap: () {
            onChanged(option);
            Navigator.pop(ctx);
          },
        ),
    ],
  ),
);

String _detail(SpaceType? type) => switch (type) {
  null => '顯示所有類型的停車點',
  SpaceType.paidMotorcycle => '路邊白線機車格，依公告時段收費',
  SpaceType.freeMotorcycle => '不收費的路邊或巷弄機車格',
  SpaceType.heavyOnly => '標示大型重機專用的格位',
  SpaceType.car => '依規定可停放機車的汽車格',
  SpaceType.offStreet => '停車場內的機車或重機區',
};

class SpaceTypeOption extends StatelessWidget {
  const SpaceTypeOption({
    super.key,
    required this.type,
    required this.count,
    required this.selected,
    required this.onTap,
  });
  final SpaceType? type;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final label = type?.label ?? '全部格位';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label，目前範圍 $count 個',
        excludeSemantics: true,
        child: Material(
          color: selected ? colors.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('space-${type?.name ?? 'all'}'),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              child: Row(
                children: [
                  ExcludeSemantics(child: GroundMarking(type: type)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: text.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          _detail(type),
                          style: text.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$count',
                    style: text.titleSmall?.copyWith(
                      color: count == 0 ? colors.outline : colors.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox.square(
                    dimension: 24,
                    child: selected
                        ? Icon(Icons.check, color: colors.primary)
                        : null,
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

/// A patch of asphalt with the type's painted marking: white motorcycle
/// boxes (with a meter when paid), a yellow heavy-bike box, a wide car
/// bay, or a lot's P sign. "All" tiles the four street markings.
class GroundMarking extends StatelessWidget {
  const GroundMarking({super.key, required this.type, this.size = 44});
  final SpaceType? type;
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: CustomPaint(painter: _MarkingPainter(type)),
    ),
  );
}

class _MarkingPainter extends CustomPainter {
  _MarkingPainter(this.type);
  final SpaceType? type;

  static const asphalt = Color(0xff3d4247);
  static const white = Color(0xfff2f2ee);
  static const yellow = Color(0xfff2c200);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = asphalt);
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
  bool shouldRepaint(_MarkingPainter old) => old.type != type;
}

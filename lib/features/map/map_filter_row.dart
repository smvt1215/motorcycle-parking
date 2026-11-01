import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/vehicle_marks.dart' show platesOf;
import 'beta_tag.dart';

/// The filter chip's height: 44pt on iOS, 48dp on Android (Main boards).
double get filterChipHeight => isCupertino ? 44 : 48;

/// One chip of the explore map's filter row (design canvas Main, Main-
/// android): a pill outlined on white, filled dark when [selected]. The
/// vehicle chip leads with its class's plates.
class MapFilterChip extends StatelessWidget {
  const MapFilterChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.toggle = true,
    this.vehicle,
    this.beta = false,
  });
  final String label;
  final VoidCallback onTap;

  /// Filled dark (aria-pressed true on the boards).
  final bool selected;

  /// Read as a toggle; the vehicle and space chips open a sheet instead.
  final bool toggle;

  /// The class whose plates lead the chip.
  final VehicleType? vehicle;

  /// A Beta tag after the label (A13): the filter reads counts still in
  /// Beta.
  final bool beta;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final fill = selected
        ? (dark ? colors.inverseSurface : const Color(0xff16313a))
        : (dark ? colors.surfaceContainerHigh : Colors.white);
    final ink = selected
        ? (dark ? colors.onInverseSurface : Colors.white)
        : (dark ? colors.onSurface : const Color(0xff16313a));
    final edge = selected
        ? BorderSide.none
        : BorderSide(
            color: dark ? colors.outlineVariant : const Color(0xffc9d3d6),
          );
    final vehicle = this.vehicle;
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: Semantics(
        button: true,
        toggled: toggle ? selected : null,
        child: Material(
          color: fill,
          shape: StadiumBorder(side: edge),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: filterChipHeight),
              child: Padding(
                // The Beta chip is 13/9 (Main board), so the three
                // leading chips stay in view on a phone.
                padding: EdgeInsetsDirectional.only(
                  start: vehicle != null
                      ? 8
                      : beta
                      ? 13
                      : 14,
                  end: beta ? 9 : 14,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (vehicle != null) ...[
                      ExcludeSemantics(
                        child: ChipPlates(
                          vehicle: vehicle,
                          backEdge: selected ? Colors.white : ink,
                          frontEdge: const Color(0xff16313a),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(label, style: TextStyle(fontSize: 14, color: ink)),
                    if (beta) ...[
                      const SizedBox(width: 6),
                      BetaTag(color: selected ? ink : null),
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

/// The vehicle chip's plates (Main): the back plate 25×17 at the top left,
/// the front one offset (7, 5), in the class's plate colours.
class ChipPlates extends StatelessWidget {
  const ChipPlates({
    super.key,
    required this.vehicle,
    required this.backEdge,
    required this.frontEdge,
  });
  final VehicleType vehicle;
  final Color backEdge, frontEdge;

  @override
  Widget build(BuildContext context) {
    final plates = platesOf(vehicle);
    return SizedBox(
      width: 32,
      height: 22,
      child: Stack(
        children: [
          for (final (i, (fill, _)) in plates.indexed)
            Positioned(
              left: i * 7.0,
              top: i * 5.0,
              child: Container(
                width: 25,
                height: 17,
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: i < plates.length - 1 ? backEdge : frontEdge,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

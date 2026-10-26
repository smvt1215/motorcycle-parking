import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';

/// Picks the vehicle the map judges spots for. Riders know their class by
/// plate colour, so each choice shows its plates.
Future<void> showVehicleSheet(
  BuildContext context, {
  required VehicleType value,
  required ValueChanged<VehicleType> onChanged,
}) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle('選擇車種'),
      const SizedBox(height: 4),
      Text(
        '地圖上的可停判斷會依車種更新。',
        style: Theme.of(ctx).textTheme.bodyMedium
            ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 20),
      for (final vehicle in VehicleType.values) ...[
        VehicleChoice(
          vehicle: vehicle,
          selected: vehicle == value,
          onTap: () {
            onChanged(vehicle);
            Navigator.pop(ctx);
          },
        ),
        const SizedBox(height: 12),
      ],
    ],
  ),
);

/// Plate colours per class (Taiwan): green up to 50cc and white up to 250cc
/// for ordinary scooters; red up to 550cc and yellow above for heavy bikes.
List<(Color, Color)> platesOf(VehicleType vehicle) => switch (vehicle) {
  VehicleType.scooter => const [
    (Color(0xff2e7d4f), Colors.white),
    (Colors.white, Color(0xff1c1c1c)),
  ],
  VehicleType.heavy => const [
    (Color(0xffc62828), Colors.white),
    (Color(0xfff2c200), Color(0xff1c1c1c)),
  ],
};

String _plates(VehicleType vehicle) => switch (vehicle) {
  VehicleType.scooter => '綠牌・白牌，250cc 以下',
  VehicleType.heavy => '紅牌・黃牌，250cc 以上',
};

String _effect(VehicleType vehicle) => switch (vehicle) {
  VehicleType.scooter => '可停一般機車格；重機專用格不可停',
  VehicleType.heavy => '可停重機專用格與汽車格；機車格依各縣市開放規則',
};

class VehicleChoice extends StatelessWidget {
  const VehicleChoice({
    super.key,
    required this.vehicle,
    required this.selected,
    required this.onTap,
  });
  final VehicleType vehicle;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: '${vehicle.label}，${_plates(vehicle)}',
      // The child's tap is excluded with its semantics; screen readers need it here.
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('vehicle-${vehicle.name}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                PlateStack(plates: platesOf(vehicle)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        vehicle.label,
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(_plates(vehicle), style: text.bodySmall),
                      const SizedBox(height: 6),
                      Text(
                        _effect(vehicle),
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  color: selected ? colors.primary : colors.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The class's two plate colours, overlapping like bikes parked in a row.
class PlateStack extends StatelessWidget {
  const PlateStack({super.key, required this.plates});
  final List<(Color, Color)> plates;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 64,
    height: 50,
    child: Stack(
      children: [
        for (final (i, (fill, ink)) in plates.indexed)
          Positioned(
            left: i * 14.0,
            top: i * 12.0,
            child: Container(
              width: 50,
              height: 32,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0xff1c1c1c), width: 1.5),
              ),
              alignment: Alignment.center,
              // An abstract number line on the front plate: it reads as a
              // plate without inventing a registration.
              child: i < plates.length - 1
                  ? null
                  : Container(
                      width: 28,
                      height: 5,
                      decoration: BoxDecoration(
                        color: ink,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
            ),
          ),
      ],
    ),
  );
}

/// [PlateStack] at banner size (25×17): the back plate top-left, the front
/// one offset (7, 5) with its number line, both 18×12. Used beside the
/// details' verdict, where one colour alone would name half the class.
class SmallPlateStack extends StatelessWidget {
  const SmallPlateStack({super.key, required this.plates});
  final List<(Color, Color)> plates;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 25,
    height: 17,
    child: Stack(
      children: [
        for (final (i, (fill, ink)) in plates.indexed)
          Positioned(
            left: i * 7.0,
            top: i * 5.0,
            child: Container(
              width: 18,
              height: 12,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(2.5),
                border: Border.all(color: const Color(0xff16313a)),
              ),
              child: i < plates.length - 1
                  ? null
                  : Container(width: 9, height: 2, color: ink),
            ),
          ),
      ],
    ),
  );
}

import 'package:material_ui/material_ui.dart';

import '../models/parking.dart' show VehicleType;

// Vehicle marks shared by the app and the admin site: the class's plate
// colours, and the car beside them on fee boards.

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

/// [PlateStack] at banner size (25×17): the back plate top-left, the front
/// one offset (7, 5) with its number line, both 18×12. Used beside the
/// details' verdict, where one colour alone would name half the class.
class SmallPlateStack extends StatelessWidget {
  const SmallPlateStack({super.key, required this.plates, this.edge});
  final List<(Color, Color)> plates;

  /// The outline; by default ink on light surfaces and the foreground
  /// colour on dark ones. A white fee board passes its ink.
  final Color? edge;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Ink on light surfaces; the foreground colour on dark ones, where the
    // ink outline would vanish.
    final edge =
        this.edge ??
        (theme.brightness == Brightness.dark
            ? theme.colorScheme.onSurface
            : const Color(0xff16313a));
    return SizedBox(
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
                  border: Border.all(color: edge),
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
}

/// The vehicles a fee is written for, in the order fee boards and the fee
/// editor list them; [wire] is the key in `fee`.
enum FeeVehicle {
  scooter('scooter', '普通機車'),
  heavy('heavy', '大型重機'),
  car('car', '汽車');

  const FeeVehicle(this.wire, this.label);
  final String wire, label;

  /// The fee vehicle a rider's class reads first.
  static FeeVehicle of(VehicleType vehicle) => switch (vehicle) {
    VehicleType.scooter => scooter,
    VehicleType.heavy => heavy,
  };
}

/// A fee vehicle's mark (25 wide): its class's plates, or a car.
class VehicleMark extends StatelessWidget {
  const VehicleMark(this.vehicle, {super.key, this.color});
  final FeeVehicle vehicle;

  /// The outline and the car's colour; see [SmallPlateStack.edge].
  final Color? color;

  @override
  Widget build(BuildContext context) => switch (vehicle) {
    FeeVehicle.scooter => SmallPlateStack(
      plates: platesOf(VehicleType.scooter),
      edge: color,
    ),
    FeeVehicle.heavy => SmallPlateStack(
      plates: platesOf(VehicleType.heavy),
      edge: color,
    ),
    FeeVehicle.car => SizedBox(
      width: 25,
      height: 20,
      child: Icon(
        Icons.directions_car_outlined,
        size: 22,
        color: color ?? IconTheme.of(context).color,
      ),
    ),
  };
}

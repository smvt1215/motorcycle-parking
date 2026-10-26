import 'package:flutter_map/flutter_map.dart';
import 'package:material_ui/material_ui.dart';

/// OpenStreetMap tiles for the preview map, recoloured in dark mode; spot
/// markers above them keep their own colours.
class OsmTiles extends StatelessWidget {
  const OsmTiles({super.key, required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) => ColorFiltered(
    colorFilter: ColorFilter.matrix(
      dark
          ? const [
              -.72,
              0,
              0,
              0,
              210,
              0,
              -.64,
              0,
              0,
              224,
              0,
              0,
              -.5,
              0,
              238,
              0,
              0,
              0,
              1,
              0,
            ]
          : const [1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0],
    ),
    child: TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'tw.motopark.motorcycle_parking',
    ),
  );
}

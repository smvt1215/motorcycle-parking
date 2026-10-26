import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:material_ui/material_ui.dart';

import '../core/address_search.dart';
import '../core/geo.dart';
import '../domain/location_check.dart';
import '../features/map/maps_sdk.dart';
import 'address_search_field.dart';

/// What the map part of [LocationPicker] shows and reports.
class LocationMapView {
  const LocationMapView({
    required this.lat,
    required this.lng,
    required this.onMove,
    this.originLat,
    this.originLng,
  });
  final double lat, lng;
  final double? originLat, originLng;

  /// The marker was dragged, or the map tapped, to a new position.
  final void Function(double lat, double lng) onMove;
}

typedef LocationMapBuilder = Widget Function(BuildContext, LocationMapView);

/// Picks a position by dragging a marker; shared by the admin site and the
/// app (docs/ADMIN_WEB.md「位置選擇」). The caller owns the position: it
/// passes [lat] and [lng] back in after [onChanged]. With [search], a
/// house number, road or intersection search sits above the map; GPS and
/// the lifted touch marker are added by their callers.
class LocationPicker extends StatelessWidget {
  const LocationPicker({
    super.key,
    required this.lat,
    required this.lng,
    required this.onChanged,
    this.originLat,
    this.originLng,
    this.nudgeButtons = false,
    this.height = 320,
    this.mapBuilder,
    this.search,
    this.onAddressPicked,
    this.fills = const {},
  });

  final double lat, lng;

  /// Where the spot was before this edit; null for a new spot.
  final double? originLat, originLng;
  final void Function(double lat, double lng) onChanged;

  /// One-metre north/south/west/east buttons (admin site).
  final bool nudgeButtons;
  final double height;

  /// Tests swap the Google map for a placeholder.
  final LocationMapBuilder? mapBuilder;

  /// The `geocode` search; null hides the search field.
  final AddressSearcher? search;

  /// After a search result moved the marker ([onChanged] runs first), the
  /// caller fills [AddressCandidate.field] with its label.
  final void Function(AddressCandidate)? onAddressPicked;

  /// The fields [onAddressPicked] fills, see [AddressSearchField.fills].
  final Map<String, String> fills;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final moved = originLat == null || originLng == null
        ? null
        : distanceMeters(originLat!, originLng!, lat, lng);
    final view = LocationMapView(
      lat: lat,
      lng: lng,
      originLat: originLat,
      originLng: originLng,
      onMove: onChanged,
    );
    void step({int north = 0, int east = 0}) {
      final (a, b) = nudge(lat, lng, north: north, east: east);
      onChanged(a, b);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (search case final search?) ...[
          AddressSearchField(
            search: search,
            lat: lat,
            lng: lng,
            fills: fills,
            onPicked: (c) {
              onChanged(c.lat, c.lng);
              onAddressPicked?.call(c);
            },
          ),
          const SizedBox(height: 12),
        ],
        Semantics(
          label: '位置地圖：拖曳標記選擇位置，拖曳地圖空白處可平移',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              height: height,
              child: (mapBuilder ?? googleLocationMap)(context, view),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
              style: const TextStyle(
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            if (moved != null)
              Text(
                moved < 0.5
                    ? '在原位置'
                    : '距原位置 ${moved.toStringAsFixed(moved < 10 ? 1 : 0)} m',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
          ],
        ),
        if (nudgeButtons) ...[
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            children: [
              for (final (label, icon, north, east) in [
                ('往北 1 m', Icons.north, 1, 0),
                ('往南 1 m', Icons.south, -1, 0),
                ('往西 1 m', Icons.west, 0, -1),
                ('往東 1 m', Icons.east, 0, 1),
              ])
                IconButton(
                  tooltip: label,
                  onPressed: () => step(north: north, east: east),
                  icon: Icon(icon),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

Future<void>? _sdk;

Widget googleLocationMap(BuildContext context, LocationMapView view) =>
    _GoogleLocationMap(view: view);

class _GoogleLocationMap extends StatefulWidget {
  const _GoogleLocationMap({required this.view});
  final LocationMapView view;
  @override
  State<_GoogleLocationMap> createState() => _GoogleLocationMapState();
}

class _GoogleLocationMapState extends State<_GoogleLocationMap> {
  late Future<void> ready = _sdk ??= initializeMapsSdk();
  gm.GoogleMapController? _map;

  @override
  void didUpdateWidget(covariant _GoogleLocationMap old) {
    super.didUpdateWidget(old);
    final v = widget.view;
    if (v.lat != old.view.lat || v.lng != old.view.lng) {
      // Follow nudges and lookups; adjusting happens at street level.
      _map?.animateCamera(gm.CameraUpdate.newLatLng(gm.LatLng(v.lat, v.lng)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.view;
    final here = gm.LatLng(v.lat, v.lng);
    return FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: TextButton(
              onPressed: () =>
                  setState(() => ready = _sdk = initializeMapsSdk()),
              child: const Text('地圖無法載入，重新載入'),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return gm.GoogleMap(
          initialCameraPosition: gm.CameraPosition(target: here, zoom: 19),
          onMapCreated: (c) => _map = c,
          onTap: (p) => v.onMove(p.latitude, p.longitude),
          zoomControlsEnabled: true,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          webGestureHandling: gm.WebGestureHandling.greedy,
          circles: {
            gm.Circle(
              circleId: const gm.CircleId('duplicate'),
              center: here,
              radius: duplicateMeters,
              strokeWidth: 1,
              strokeColor: const Color(0xff1f5fa8),
              fillColor: const Color(0x141f5fa8),
            ),
            if (v.originLat != null && v.originLng != null)
              gm.Circle(
                circleId: const gm.CircleId('origin'),
                center: gm.LatLng(v.originLat!, v.originLng!),
                radius: 3,
                strokeWidth: 2,
                strokeColor: const Color(0xff2a2e33),
                fillColor: const Color(0x00000000),
              ),
          },
          markers: {
            gm.Marker(
              markerId: const gm.MarkerId('picked'),
              position: here,
              draggable: true,
              onDragEnd: (p) => v.onMove(p.latitude, p.longitude),
            ),
          },
        );
      },
    );
  }
}

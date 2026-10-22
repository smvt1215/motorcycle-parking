import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as pi;
import 'package:latlong2/latlong.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/features/map/google_parking_map.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

void main() {
  testWidgets('Google 地圖移動後發布正確範圍，忽略較晚返回的舊範圍', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    final updates = <(MapViewport, LatLng)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleParkingMap(
          center: const LatLng(25.03, 121.56),
          spots: const [],
          eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
          interactive: true,
          onSpotTap: (_) {},
          onViewport: (bounds, center) => updates.add((bounds, center)),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    expect(updates, isNotEmpty);
    updates.clear();
    final old = Completer<pi.LatLngBounds>();
    platform.nextBounds = old.future;
    platform.move.add(
      pi.CameraMoveEvent(
        platform.id,
        const pi.CameraPosition(target: pi.LatLng(25.04, 121.57), zoom: 16),
      ),
    );
    platform.idle.add(pi.CameraIdleEvent(platform.id));
    await tester.pump();
    platform.bounds = pi.LatLngBounds(
      southwest: const pi.LatLng(24.14, 120.66),
      northeast: const pi.LatLng(24.16, 120.68),
    );
    platform.move.add(
      pi.CameraMoveEvent(
        platform.id,
        const pi.CameraPosition(target: pi.LatLng(24.15, 120.67), zoom: 16),
      ),
    );
    platform.idle.add(pi.CameraIdleEvent(platform.id));
    await tester.pumpAndSettle();
    expect(updates.single.$1.contains(24.15, 120.67), isTrue);
    expect(updates.single.$2, const LatLng(24.15, 120.67));
    old.complete(
      pi.LatLngBounds(
        southwest: const pi.LatLng(25.03, 121.56),
        northeast: const pi.LatLng(25.05, 121.58),
      ),
    );
    await tester.pumpAndSettle();
    expect(updates, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('目前位置以固定大小的標記顯示，不隨縮放變小', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleParkingMap(
          center: const LatLng(25.03, 121.56),
          location: const LatLng(25.031, 121.561),
          spots: const [],
          eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
          interactive: true,
          onSpotTap: (_) {},
          onViewport: (_, _) {},
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    final dot = map.markers.singleWhere(
      (marker) => marker.markerId.value == 'my-location',
    );
    expect(dot.position, const gm.LatLng(25.031, 121.561));
    expect(dot.clusterManagerId, isNull);
    expect(map.circles, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Google 停車標記可開啟詳情，面板開啟時停用底圖互動且保留相機', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    final spots = (await tester.runAsync(
      () => ParkingRepository(null).inViewport(
        const MapViewport(
          south: 25.01,
          west: 121.54,
          north: 25.06,
          east: 121.59,
        ),
      ),
    ))!.spots;
    ParkingSpot? selected;
    bool interactive = true;
    late StateSetter rebuild;
    final key = GlobalKey<GoogleParkingMapState>();
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return GoogleParkingMap(
              key: key,
              center: const LatLng(25.03, 121.56),
              spots: spots,
              eligibility: (_) =>
                  const Eligibility(EligibilityStatus.conditional, '請確認'),
              interactive: interactive,
              onSpotTap: (spot) => selected = spot,
              onViewport: (_, _) {},
            );
          },
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(map.markers, hasLength(spots.length));
    map.markers.first.onTap!();
    expect(selected?.id, map.markers.first.markerId.value);
    await key.currentState!.moveTo(const LatLng(24.15, 120.67), 17);
    expect(platform.moves, hasLength(1));
    final before = platform.created;
    rebuild(() => interactive = false);
    await tester.pumpAndSettle();
    final paused = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(paused.scrollGesturesEnabled, isFalse);
    expect(paused.markers.every((marker) => marker.onTap == null), isTrue);
    expect(platform.created, before);
    rebuild(() => interactive = true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<gm.GoogleMap>(find.byType(gm.GoogleMap))
          .scrollGesturesEnabled,
      isTrue,
    );
    expect(platform.created, before);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class FakeMapsPlatform extends pi.GoogleMapsFlutterPlatform {
  int id = 0, created = 0;
  final createdIds = <int>{};
  final moves = <pi.CameraUpdate>[];
  final move = StreamController<pi.CameraMoveEvent>.broadcast();
  final idle = StreamController<pi.CameraIdleEvent>.broadcast();
  pi.LatLngBounds bounds = pi.LatLngBounds(
    southwest: const pi.LatLng(25.02, 121.55),
    northeast: const pi.LatLng(25.04, 121.57),
  );
  Future<pi.LatLngBounds>? nextBounds;

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required pi.MapWidgetConfiguration widgetConfiguration,
    pi.MapConfiguration mapConfiguration = const pi.MapConfiguration(),
    pi.MapObjects mapObjects = const pi.MapObjects(),
  }) {
    id = creationId;
    if (createdIds.add(id)) {
      created++;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => onPlatformViewCreated(creationId),
      );
    }
    return const SizedBox.expand();
  }

  @override
  Future<void> init(int mapId) async {}
  @override
  Future<pi.LatLngBounds> getVisibleRegion({required int mapId}) {
    final pending = nextBounds;
    nextBounds = null;
    return pending ?? Future.value(bounds);
  }

  @override
  Future<void> animateCamera(
    pi.CameraUpdate cameraUpdate, {
    required int mapId,
  }) async => moves.add(cameraUpdate);
  @override
  void dispose({required int mapId}) {
    unawaited(move.close());
    unawaited(idle.close());
  }

  @override
  Stream<pi.CameraMoveEvent> onCameraMove({required int mapId}) => move.stream;
  @override
  Stream<pi.CameraIdleEvent> onCameraIdle({required int mapId}) => idle.stream;
  @override
  Stream<pi.CameraMoveStartedEvent> onCameraMoveStarted({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.MarkerTapEvent> onMarkerTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.MarkerDragStartEvent> onMarkerDragStart({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.MarkerDragEvent> onMarkerDrag({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.MarkerDragEndEvent> onMarkerDragEnd({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.InfoWindowTapEvent> onInfoWindowTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.PolylineTapEvent> onPolylineTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.PolygonTapEvent> onPolygonTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.CircleTapEvent> onCircleTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.ClusterTapEvent> onClusterTap({required int mapId}) =>
      const Stream.empty();
  @override
  Stream<pi.MapTapEvent> onTap({required int mapId}) => const Stream.empty();
  @override
  Stream<pi.MapLongPressEvent> onLongPress({required int mapId}) =>
      const Stream.empty();
  @override
  Future<void> updateMarkers(
    pi.MarkerUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updatePolygons(
    pi.PolygonUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updatePolylines(
    pi.PolylineUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateCircles(
    pi.CircleUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateHeatmaps(
    pi.HeatmapUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateClusterManagers(
    pi.ClusterManagerUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateGroundOverlays(
    pi.GroundOverlayUpdates updates, {
    required int mapId,
  }) async {}
  @override
  Future<void> updateTileOverlays({
    required Set<pi.TileOverlay> newTileOverlays,
    required int mapId,
  }) async {}
  @override
  Future<void> updateMapConfiguration(
    pi.MapConfiguration configuration, {
    required int mapId,
  }) async {}
}

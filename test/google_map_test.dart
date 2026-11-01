import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' as gm;
import 'package:google_maps_flutter_platform_interface/google_maps_flutter_platform_interface.dart'
    as pi;
import 'package:latlong2/latlong.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/domain/availability_display.dart';
import 'package:motorcycle_parking/domain/eligibility.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/domain/spot_clusters.dart';
import 'package:motorcycle_parking/features/map/google_parking_map.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

Future<void> pumpMap(WidgetTester tester) async {
  // Image rasterization uses the real engine, even when tests use fake time.
  for (var frame = 0; frame < 100; frame++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    if (find.byType(gm.GoogleMap).evaluate().isNotEmpty) break;
  }
  expect(find.byType(gm.GoogleMap), findsOneWidget);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('數字6群聚圈為56dp，點擊放大，20級展開為六個單點', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    final spots = [
      for (var i = 0; i < 6; i++)
        ParkingSpot(
          id: '$i',
          name: '停車點$i',
          lat: 25.03 + i * .00002,
          lng: 121.56,
          city: '臺北市',
          spaceType: SpaceType.freeMotorcycle,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleParkingMap(
          center: const LatLng(25.03, 121.56),
          spots: spots,
          eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
          interactive: true,
          onSpotTap: (_) {},
          onViewport: (_, _) {},
        ),
      ),
    );
    // Bitmap rasterization completes on the real engine, outside fake time.
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (find.byType(gm.GoogleMap).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    final cluster = map.markers.single;
    expect(cluster.markerId.value, startsWith('cluster:'));
    expect(map.clusterManagers, isEmpty);
    final icon = cluster.icon as gm.BytesMapBitmap;
    expect(icon.width, 56);
    expect(icon.height, 56);
    cluster.onTap!();
    await tester.pump();
    expect(platform.moves, hasLength(1));
    platform.move.add(
      pi.CameraMoveEvent(
        platform.id,
        const pi.CameraPosition(target: pi.LatLng(25.03, 121.56), zoom: 20),
      ),
    );
    platform.idle.add(pi.CameraIdleEvent(platform.id));
    await tester.pumpAndSettle();
    // Spot bitmaps are drawn the first time their look is on screen, on the
    // real engine; each marker appears once its bitmap is ready.
    for (var frame = 0; frame < 50; frame++) {
      final markers = tester
          .widget<gm.GoogleMap>(find.byType(gm.GoogleMap))
          .markers;
      if (markers.length == 6) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    final expanded = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(expanded.markers, hasLength(6));
    expect(
      expanded.markers.any((m) => m.markerId.value.startsWith('cluster:')),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('Google 少於五個鄰近點不聚合，增至五點才顯示藍圈', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    final points = [
      for (var i = 0; i < 5; i++)
        ParkingSpot(
          id: '$i',
          name: '停車點$i',
          lat: 25.03 + i * .00002,
          lng: 121.56,
          city: '臺北市',
          spaceType: SpaceType.freeMotorcycle,
        ),
    ];
    Widget mapWith(int count) => MaterialApp(
      home: GoogleParkingMap(
        center: const LatLng(25.03, 121.56),
        spots: points.take(count).toList(),
        eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
        interactive: true,
        onSpotTap: (_) {},
        onViewport: (_, _) {},
      ),
    );
    await tester.pumpWidget(mapWith(4));
    await pumpMap(tester);
    expect(
      tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap)).markers,
      hasLength(4),
    );
    await tester.pumpWidget(mapWith(5));
    for (var i = 0; i < 50; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (tester
          .widget<gm.GoogleMap>(find.byType(gm.GoogleMap))
          .markers
          .any((m) => m.markerId.value.startsWith('cluster:'))) {
        break;
      }
    }
    final markers = tester
        .widget<gm.GoogleMap>(find.byType(gm.GoogleMap))
        .markers;
    expect(markers, hasLength(1));
    expect(markers.single.markerId.value, startsWith('cluster:'));
    await tester.pumpWidget(mapWith(4));
    await tester.pumpAndSettle();
    expect(
      tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap)).markers,
      hasLength(4),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  addSelectionTests();
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
    await pumpMap(tester);
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
    await pumpMap(tester);
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
    await pumpMap(tester);
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    final single = map.markers.firstWhere(
      (marker) => !marker.markerId.value.startsWith('cluster:'),
    );
    single.onTap!();
    expect(selected?.id, single.markerId.value);
    await key.currentState!.moveTo(const LatLng(24.15, 120.67), 17);
    expect(platform.moves, hasLength(1));
    final before = platform.created;
    rebuild(() => interactive = false);
    await tester.pumpAndSettle();
    final paused = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(paused.scrollGesturesEnabled, isFalse);
    // A modal overlays the same map viewport without shifting its center.
    expect(paused.padding, map.padding);
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

void addSelectionTests() {
  testWidgets('選取的停車點放大、移出叢集，所有標記都不顯示資訊視窗', (tester) async {
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
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleParkingMap(
          center: const LatLng(25.03, 121.56),
          // The selected spot stays drawn even when filtered out.
          spots: spots.skip(1).toList(),
          selected: spots.first,
          eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
          interactive: true,
          onSpotTap: (_) {},
          onMapTap: () => taps++,
          onViewport: (_, _) {},
        ),
      ),
    );
    await pumpMap(tester);
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(
      map.markers,
      hasLength(clusterSpots(spots.skip(1).toList(), 16).length + 1),
    );
    // Its own id: never the clustered marker changed in place.
    expect(
      map.markers.where((m) => m.markerId.value == spots.first.id),
      isEmpty,
    );
    final chosen = map.markers.singleWhere(
      (m) => m.markerId.value == 'selected:${spots.first.id}',
    );
    expect(chosen.clusterManagerId, isNull);
    expect(chosen.zIndexInt, greaterThan(0));
    final others = map.markers.where((m) => m != chosen);
    expect(others.every((m) => m.clusterManagerId == null), isTrue);
    expect(
      map.markers.every((m) => m.infoWindow == gm.InfoWindow.noText),
      isTrue,
    );
    expect(map.padding.bottom, 8);
    map.onTap!(const gm.LatLng(25.03, 121.56));
    expect(taps, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: GoogleParkingMap(
          center: const LatLng(25.03, 121.56),
          spots: spots.skip(1).toList(),
          selected: spots.first,
          eligibility: (_) => const Eligibility(EligibilityStatus.allowed, ''),
          // A modal sheet opened over the details.
          interactive: false,
          onSpotTap: (_) {},
          onViewport: (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap)).padding,
      map.padding,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分頁面板蓋住地圖時不更新範圍，回到地圖立即重新發布', (tester) async {
    final platform = FakeMapsPlatform();
    final previous = pi.GoogleMapsFlutterPlatform.instance;
    pi.GoogleMapsFlutterPlatform.instance = platform;
    addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
    final updates = <MapViewport>[];
    var panel = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return GoogleParkingMap(
              center: const LatLng(25.03, 121.56),
              spots: const [],
              eligibility: (_) =>
                  const Eligibility(EligibilityStatus.allowed, ''),
              interactive: !panel,
              panelVisible: panel,
              onSpotTap: (_) {},
              onViewport: (bounds, _) => updates.add(bounds),
            );
          },
        ),
      ),
    );
    await pumpMap(tester);
    updates.clear();
    final map = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    final mapSize = tester.getSize(find.byType(gm.GoogleMap));
    rebuild(() => panel = true);
    await tester.pumpAndSettle();
    final covered = tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap));
    expect(covered.padding, map.padding);
    expect(tester.getSize(find.byType(gm.GoogleMap)), mapSize);
    expect(platform.moves, isEmpty);
    // While covered, unsolicited camera events must not update the store.
    platform.bounds = pi.LatLngBounds(
      southwest: const pi.LatLng(25.039, 121.55),
      northeast: const pi.LatLng(25.04, 121.57),
    );
    platform.idle.add(pi.CameraIdleEvent(platform.id));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(updates, isEmpty);
    // Back on the map, with no camera move to report it.
    platform.bounds = pi.LatLngBounds(
      southwest: const pi.LatLng(25.02, 121.55),
      northeast: const pi.LatLng(25.04, 121.57),
    );
    final reads = platform.regionPaddings.length;
    rebuild(() => panel = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(updates, isNotEmpty);
    expect(updates.every((bounds) => bounds.south == 25.02), isTrue);
    // Every read uses the same map projection as before opening the panel.
    final back = platform.regionPaddings.skip(reads);
    expect(back, isNotEmpty);
    expect(back.every((padding) => padding == map.padding.bottom), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('剩餘數膠囊（#139）', () {
    const own = AvailabilityCapsule(
      text: '剩 12',
      style: CapsuleStyle.live,
      semantics: '官方即時：剩 12 格',
    );
    const car = AvailabilityCapsule(
      text: '剩 3',
      style: CapsuleStyle.car,
      semantics: '汽車格剩 3 格',
    );
    // At zoom 16 a pixel is about 2.15e-5 of longitude here: a and b sit
    // 30 apart (crowded), c 400 away.
    ParkingSpot at(String id, double dx) => ParkingSpot(
      id: id,
      name: '停車場$id',
      lat: 25.03,
      lng: 121.56 + dx * 2.15e-5,
      city: '臺北市',
      spaceType: SpaceType.offStreet,
    );
    final a = at('a', 0), b = at('b', 30), c = at('c', 400);
    final pills = {
      'a': [own, car],
      'b': [own],
      'c': [own, car],
    };

    Future<Map<String, gm.Marker>> pumpCapsules(
      WidgetTester tester, {
      ParkingSpot? selected,
      Set<String> expected = const {},
    }) async {
      final platform = FakeMapsPlatform();
      final previous = pi.GoogleMapsFlutterPlatform.instance;
      pi.GoogleMapsFlutterPlatform.instance = platform;
      addTearDown(() => pi.GoogleMapsFlutterPlatform.instance = previous);
      await tester.pumpWidget(
        MaterialApp(
          home: GoogleParkingMap(
            center: const LatLng(25.03, 121.56),
            spots: [a, b, c].where((s) => s.id != selected?.id).toList(),
            selected: selected,
            eligibility: (_) =>
                const Eligibility(EligibilityStatus.allowed, ''),
            interactive: true,
            onSpotTap: (_) {},
            onViewport: (_, _) {},
            capsules: (s) => pills[s.id]!,
            primaryCapsules: (s, all) => [all.first],
            excluded: [at('x', -400)],
          ),
        ),
      );
      await pumpMap(tester);
      Map<String, gm.Marker> markers() => {
        for (final m
            in tester.widget<gm.GoogleMap>(find.byType(gm.GoogleMap)).markers)
          m.markerId.value: m,
      };
      // Bitmaps are drawn on the real engine, one look at a time.
      for (var frame = 0; frame < 100; frame++) {
        if (markers().keys.toSet().containsAll(expected)) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      return markers();
    }

    Future<double> widthOf(WidgetTester tester, CapsuleKey key) async =>
        ((await tester.runAsync(() => capsuleIcon(key)))! as gm.BytesMapBitmap)
            .width!;

    testWidgets('擁擠的點只留主要膠囊，遠的照實顯示；膠囊錨在點上、畫在標記下', (tester) async {
      final markers = await pumpCapsules(
        tester,
        expected: {'capsules:a', 'capsules:b', 'capsules:c', 'excluded:x'},
      );
      final one = await widthOf(tester, CapsuleKey([own], selected: false));
      final two = await widthOf(
        tester,
        CapsuleKey([own, car], selected: false),
      );
      expect(two, greaterThan(one));
      double width(String id) =>
          (markers['capsules:$id']!.icon as gm.BytesMapBitmap).width!;
      expect(width('a'), one);
      expect(width('b'), one);
      expect(width('c'), two);
      final pill = markers['capsules:c']!;
      expect(pill.anchor, const Offset(.5, 1));
      expect(pill.zIndexInt, lessThan(markers['c']!.zIndexInt));
      expect(pill.position, markers['c']!.position);
      // The filter's grey dot, under everything.
      expect(markers['excluded:x']!.zIndexInt, lessThan(pill.zIndexInt));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('選取的點顯示整組並浮到最上層，會碰到它的鄰點膠囊隱藏', (tester) async {
      final markers = await pumpCapsules(
        tester,
        selected: a,
        expected: {'selected-capsules:a', 'capsules:c'},
      );
      final chosen = markers['selected-capsules:a']!;
      expect(
        (chosen.icon as gm.BytesMapBitmap).width,
        await widthOf(tester, CapsuleKey([own, car], selected: true)),
      );
      expect(chosen.zIndexInt, greaterThan(markers['selected:a']!.zIndexInt));
      expect(markers.containsKey('capsules:b'), isFalse);
      expect(markers.containsKey('capsules:c'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
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

  /// Bottom padding the native map currently has, and the one each visible
  /// region was read under: a read before the padding update sees the old
  /// layout.
  double padding = 0;
  final regionPaddings = <double>[];

  @override
  Widget buildViewWithConfiguration(
    int creationId,
    PlatformViewCreatedCallback onPlatformViewCreated, {
    required pi.MapWidgetConfiguration widgetConfiguration,
    pi.MapConfiguration mapConfiguration = const pi.MapConfiguration(),
    pi.MapObjects mapObjects = const pi.MapObjects(),
  }) {
    id = creationId;
    padding = mapConfiguration.padding?.bottom ?? padding;
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
    regionPaddings.add(padding);
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
  }) async {
    if (configuration.padding case final value?) padding = value.bottom;
  }
}

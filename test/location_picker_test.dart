import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/geo.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/ui/location_picker.dart';

const _xml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<townVillageItem>
    <ctyCode>A</ctyCode>
    <ctyName>臺北市</ctyName>
    <townCode>A10</townCode>
    <townName>中山區</townName>
</townVillageItem>''';

void main() {
  test('國土測繪中心回應解析縣市與行政區，海上回傳 null', () {
    expect(parseTown(_xml), const Town('臺北市', '中山區'));
    expect(parseTown('<townVillageItem></townVillageItem>'), isNull);
  });

  test('微調一次移動約 1 m', () {
    final (lat, lng) = nudge(25.0581, 121.5226, north: 1);
    expect(distanceMeters(25.0581, 121.5226, lat, lng), closeTo(1, 0.01));
    final (lat2, lng2) = nudge(25.0581, 121.5226, east: -1);
    expect(distanceMeters(25.0581, 121.5226, lat2, lng2), closeTo(1, 0.01));
  });

  test('位置提醒：距離、15 m 同類型重複、跨縣市', () {
    final (lat, lng) = nudge(25.0581, 121.5226, north: 200);
    const near = [
      NearbySpot(
        sourceId: 'self',
        name: '自己',
        spaceType: 'heavyOnly',
        lat: 25.0581,
        lng: 121.5226,
      ),
      NearbySpot(
        sourceId: 'a',
        name: '同類型',
        spaceType: 'heavyOnly',
        lat: 25.05811,
        lng: 121.5226,
      ),
      NearbySpot(
        sourceId: 'b',
        name: '不同類型',
        spaceType: 'car',
        lat: 25.0581,
        lng: 121.5226,
      ),
    ];
    final notes = checkLocation(
      lat: 25.0581,
      lng: 121.5226,
      spaceType: 'heavyOnly',
      selfId: 'self',
      nearby: near,
      originCity: '臺北市',
      newCity: '新北市',
    );
    expect(notes.duplicates.map((d) => d.name), ['同類型']);
    expect(notes.cityChanged, isTrue);
    expect(notes.moved, isNull);
    final moved = checkLocation(
      lat: lat,
      lng: lng,
      originLat: 25.0581,
      originLng: 121.5226,
    );
    expect(moved.far, isTrue);
    expect(moved.moved, closeTo(200, 0.5));
  });

  testWidgets('拖曳回報新位置，顯示距離，微調鈕每次 1 m', (tester) async {
    var at = (25.0581, 121.5226);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => LocationPicker(
              lat: at.$1,
              lng: at.$2,
              originLat: 25.0581,
              originLng: 121.5226,
              nudgeButtons: true,
              mapBuilder: (context, view) => TextButton(
                onPressed: () => view.onMove(view.lat + 0.0001, view.lng),
                child: const Text('拖曳'),
              ),
              onChanged: (lat, lng) => setState(() => at = (lat, lng)),
            ),
          ),
        ),
      ),
    );
    expect(find.text('在原位置'), findsOneWidget);
    await tester.tap(find.text('拖曳'));
    await tester.pump();
    expect(find.text('距原位置 11 m'), findsOneWidget);
    await tester.tap(find.byTooltip('往南 1 m'));
    await tester.pump();
    expect(find.text('距原位置 10 m'), findsOneWidget);
  });

  testWidgets('搜尋地址時清單縮小把選位捲出畫面，選定後「已移到」提示仍在（S1）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var at = (25.0581, 121.5226);
    final picked = Completer<AddressCandidate?>();
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              controller: scroll,
              children: [
                LocationPicker(
                  lat: at.$1,
                  lng: at.$2,
                  mapBuilder: (_, _) => const SizedBox(),
                  onSearch: (_) => picked.future,
                  onChanged: (lat, lng) => setState(() => at = (lat, lng)),
                ),
                const SizedBox(height: 3000),
                const Text('表單底部'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('location-search')));
    await tester.pump();
    // The keyboard shrinks the page and the list scrolls the picker far
    // out of view (and out of the list's cache) while the search is open.
    tester.view.physicalSize = const Size(390, 508);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pumpAndSettle();
    picked.complete(
      const AddressCandidate(
        kind: AddressKind.address,
        label: '臺北市中正區忠孝西路一段49號',
        lat: 25.0478,
        lng: 121.517,
      ),
    );
    await tester.pumpAndSettle();
    expect(at, (25.0478, 121.517));
    // The keyboard closes and the admin scrolls back to the picker.
    tester.view.physicalSize = const Size(390, 844);
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.textContaining('已移到「臺北市中正區忠孝西路一段49號」'), findsOneWidget);
  });

  testWidgets('搜尋結果提示落在畫面外時捲到可見（S2）', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var at = (25.0581, 121.5226);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [
                const SizedBox(height: 780),
                LocationPicker(
                  lat: at.$1,
                  lng: at.$2,
                  mapBuilder: (_, _) => const SizedBox(),
                  onSearch: (_) async => const AddressCandidate(
                    kind: AddressKind.address,
                    label: '臺北市中正區忠孝西路一段49號',
                    lat: 25.0478,
                    lng: 121.517,
                  ),
                  onChanged: (lat, lng) => setState(() => at = (lat, lng)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final note = find.textContaining('已移到「臺北市中正區忠孝西路一段49號」');
    await tester.tap(find.byKey(const ValueKey('location-search')));
    await tester.pumpAndSettle();
    expect(note, findsOneWidget);
    expect(tester.getRect(note).bottom, lessThanOrEqualTo(844));
  });

  testWidgets('矮螢幕模式：小地圖收成「開地圖調整」，全螢幕地圖調整後回到表單', (tester) async {
    var at = (25.0581, 121.5226);
    var collapsed = true;
    late StateSetter outer;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              outer = setState;
              return ListView(
                children: [
                  LocationPicker(
                    lat: at.$1,
                    lng: at.$2,
                    nudgeButtons: true,
                    collapsed: collapsed,
                    mapBuilder: (context, view) => TextButton(
                      onPressed: () => view.onMove(view.lat + 0.0001, view.lng),
                      child: const Text('拖曳'),
                    ),
                    onChanged: (lat, lng) => setState(() => at = (lat, lng)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('拖曳'), findsNothing);
    expect(find.text('開地圖調整'), findsOneWidget);
    expect(find.text('位置：25.0581, 121.5226'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const ValueKey('location-open-map'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('開地圖調整'));
    await tester.pumpAndSettle();
    expect(find.text('調整位置'), findsOneWidget);
    await tester.tap(find.text('拖曳'));
    await tester.pump();
    // Each move reaches the form at once, and the dialog's map follows it.
    expect(at.$1, closeTo(25.0582, 1e-9));
    expect(find.text('25.058200, 121.522600'), findsOneWidget);
    await tester.tap(find.byTooltip('往南 1 m'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('location-map-done')));
    await tester.pumpAndSettle();
    expect(find.text('調整位置'), findsNothing);
    expect(at.$1, lessThan(25.0582));
    // The keyboard closed: the map is back inline.
    outer(() => collapsed = false);
    await tester.pump();
    expect(find.text('拖曳'), findsOneWidget);
    expect(find.text('開地圖調整'), findsNothing);
  });

  testWidgets('矮螢幕模式的全螢幕地圖仍可搜尋地址，結果回到表單並顯示提示', (tester) async {
    var at = (25.0581, 121.5226);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              children: [
                LocationPicker(
                  lat: at.$1,
                  lng: at.$2,
                  collapsed: true,
                  fills: const {'address': '地址'},
                  mapBuilder: (_, _) => const SizedBox(),
                  onSearch: (_) async => const AddressCandidate(
                    kind: AddressKind.address,
                    label: '臺北市中正區忠孝西路一段49號',
                    lat: 25.0478,
                    lng: 121.517,
                  ),
                  onChanged: (lat, lng) => setState(() => at = (lat, lng)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('location-search')), findsNothing);
    await tester.tap(find.text('開地圖調整'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('location-search')));
    await tester.pumpAndSettle();
    expect(at, (25.0478, 121.517));
    expect(find.text('25.047800, 121.517000'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('location-map-done')));
    await tester.pumpAndSettle();
    expect(find.text('位置：25.0478, 121.5170'), findsOneWidget);
    expect(find.textContaining('已移到「臺北市中正區忠孝西路一段49號」，並填入「地址」'), findsOneWidget);
  });

  test('投影：點位到地圖中心的像素位移可以換回同一點', () {
    final (dx, dy) = offsetFromCenter(
      centerLat: 25.0339,
      centerLng: 121.5623,
      zoom: 19,
      lat: 25.0341,
      lng: 121.5620,
    );
    // North is up and west is left on an unrotated map.
    expect(dy, lessThan(0));
    expect(dx, lessThan(0));
    final (lat, lng) = pointAtOffset(
      centerLat: 25.0339,
      centerLng: 121.5623,
      zoom: 19,
      dx: dx,
      dy: dy,
    );
    expect(distanceMeters(lat, lng, 25.0341, 121.5620), lessThan(0.01));
    // At street level one logical pixel is about a quarter of a metre.
    final (south, _) = pointAtOffset(
      centerLat: 25.0339,
      centerLng: 121.5623,
      zoom: 19,
      dx: 0,
      dy: 4,
    );
    expect(distanceMeters(south, 121.5623, 25.0339, 121.5623), closeTo(1, .1));
  });

  testWidgets('觸控標記 56×68，拖曳時浮在手指上方，表單不跟著捲動', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final camera = ValueNotifier<MapCenter>((
      lat: 25.0339,
      lng: 121.5623,
      zoom: 19,
    ));
    addTearDown(camera.dispose);
    (double, double)? moved;
    final list = ScrollController();
    addTearDown(list.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: list,
            children: [
              SizedBox(
                height: 300,
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Colors.grey),
                    ),
                    Positioned.fill(
                      child: TouchMarkerLayer(
                        camera: camera,
                        lat: 25.0339,
                        lng: 121.5623,
                        onMove: (lat, lng) => moved = (lat, lng),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    final pin = find.byKey(const ValueKey('touch-marker'));
    expect(tester.getSize(pin), const Size(56, 68));
    // The tip, the picked point, is the bottom centre at the map centre.
    expect(tester.getBottomLeft(pin).dy, 150);
    final gesture = await tester.startGesture(tester.getCenter(pin));
    await gesture.moveBy(const Offset(0, -20));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.byKey(const ValueKey('touch-marker-ground')), findsOneWidget);
    // Finger at 150 - 34 - 20 = 96; the tip rides 24 px above it.
    expect(tester.getBottomLeft(pin).dy, 72);
    expect(list.offset, 0);
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('touch-marker-ground')), findsNothing);
    final (lat, lng) = pointAtOffset(
      centerLat: 25.0339,
      centerLng: 121.5623,
      zoom: 19,
      dx: 40,
      dy: 72 - 150,
    );
    expect(distanceMeters(moved!.$1, moved!.$2, lat, lng), lessThan(0.01));
    expect(list.offset, 0);

    // A tap without moving keeps the position.
    moved = null;
    await tester.tap(pin);
    await tester.pump();
    expect(moved, isNull);
  });

  Future<void> pumpPicker(
    WidgetTester tester, {
    Future<LocationFix> Function()? onLocate,
    LocationSearch? onSearch,
  }) async {
    var at = (25.0581, 121.5226);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => LocationPicker(
              lat: at.$1,
              lng: at.$2,
              touchMarker: true,
              onLocate: onLocate,
              onSearch: onSearch,
              height: 200,
              mapBuilder: (context, view) => TextButton(
                onPressed: () => view.onMove(view.lat + 0.0001, view.lng),
                child: const Text('拖曳'),
              ),
              onChanged: (lat, lng) => setState(() => at = (lat, lng)),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('我的位置顯示 GPS 精準度，誤差超過 20 m 提醒對準', (tester) async {
    var accuracy = 8.0;
    await pumpPicker(
      tester,
      onLocate: () async => LocationFix(25.06, 121.52, accuracy),
    );
    expect(find.text('搜尋門牌、路段或路口'), findsNothing);
    await tester.tap(find.text('移到我的位置'));
    await tester.pumpAndSettle();
    expect(find.text('25.060000, 121.520000'), findsOneWidget);
    expect(find.text('GPS 精準度約 ±8 m'), findsOneWidget);
    accuracy = 35;
    await tester.tap(find.text('移到我的位置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('GPS 誤差約 35 m，超過 20 m'), findsOneWidget);
    expect(find.byIcon(Icons.gps_not_fixed), findsOneWidget);
    // Once moved by hand, the fix no longer describes the marker.
    await tester.tap(find.text('拖曳'));
    await tester.pump();
    expect(find.textContaining('GPS'), findsNothing);
  });

  testWidgets('定位失敗時說明怎麼做，不影響拖曳', (tester) async {
    await pumpPicker(tester, onLocate: () async => throw TimeoutException(''));
    await tester.tap(find.text('移到我的位置'));
    await tester.pumpAndSettle();
    expect(find.textContaining('抓不到目前位置'), findsOneWidget);
    expect(find.text('25.058100, 121.522600'), findsOneWidget);
  });

  testWidgets('搜尋入口只在有提供搜尋時出現，結果移動標記並提醒拖曳', (tester) async {
    await pumpPicker(
      tester,
      onSearch: (context) async => const AddressCandidate(
        kind: AddressKind.road,
        label: '南京東路一段',
        lat: 25.05,
        lng: 121.53,
        precision: AddressPrecision.center,
      ),
    );
    await tester.tap(find.text('搜尋門牌、路段或路口'));
    await tester.pumpAndSettle();
    expect(find.text('25.050000, 121.530000'), findsOneWidget);
    expect(find.textContaining('已移到「南京東路一段」。路段只定位到中心點'), findsOneWidget);
    // Once moved by hand, the note no longer describes the marker.
    await tester.tap(find.text('拖曳'));
    await tester.pump();
    expect(find.textContaining('已移到'), findsNothing);
  });
}

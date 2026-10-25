import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
}

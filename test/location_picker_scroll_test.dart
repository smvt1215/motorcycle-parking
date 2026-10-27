import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/location_picker.dart';

/// The recognizer class [f] builds ([Factory.type] is only its declared
/// type, the same for all of them).
Type _typeOf(Factory<OneSequenceGestureRecognizer> f) {
  final r = f.constructor();
  r.dispose();
  return r.runtimeType;
}

/// What reached the stand-in map.
class MapLog {
  var pans = 0, taps = 0;
}

/// Stands in for the Google map's platform view: it takes part in the
/// gesture arena with [pickerMapGestures] exactly as the platform view
/// does (no-op callbacks so each recognizer competes), plus the touch
/// marker the real map stacks on top.
LocationMapBuilder pickerStandIn(MapLog log) =>
    (context, view) => Stack(
      children: [
        Positioned.fill(
          child: RawGestureDetector(
            gestures: {
              for (final f in pickerMapGestures)
                _typeOf(f): switch (_typeOf(f)) {
                  const (HorizontalDragGestureRecognizer) =>
                    GestureRecognizerFactoryWithHandlers<
                      HorizontalDragGestureRecognizer
                    >(
                      () => f.constructor() as HorizontalDragGestureRecognizer,
                      (r) => r.onUpdate = (_) => log.pans++,
                    ),
                  const (ScaleGestureRecognizer) =>
                    GestureRecognizerFactoryWithHandlers<
                      ScaleGestureRecognizer
                    >(
                      () => f.constructor() as ScaleGestureRecognizer,
                      (r) => r.onUpdate = (_) => log.pans++,
                    ),
                  const (TapGestureRecognizer) =>
                    GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                      () => f.constructor() as TapGestureRecognizer,
                      (r) => r.onTap = () => log.taps++,
                    ),
                  // A new kind needs a branch here, so this test keeps
                  // standing in for the real map.
                  final t => throw UnimplementedError('$t'),
                },
            },
            child: const ColoredBox(
              key: ValueKey('stand-in-map'),
              color: Color(0xffcfdcd4),
            ),
          ),
        ),
        Positioned.fill(
          child: TouchMarkerLayer(
            camera: ValueNotifier((lat: view.lat, lng: view.lng, zoom: 19)),
            lat: view.lat,
            lng: view.lng,
            onMove: view.onMove,
          ),
        ),
      ],
    );

void main() {
  for (final size in const [Size(320, 640), Size(390, 844), Size(402, 874)]) {
    testWidgets(
      '新增停車點：在小地圖上下滑動會捲動表單，左右拖曳與點按交給地圖'
      '（${size.width.toInt()}×${size.height.toInt()}）',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = (await tester.runAsync(() async {
          SharedPreferences.setMockInitialValues({});
          return AppStore(
            LocalRepository(await SharedPreferences.getInstance()),
            null,
          );
        }))!;
        addTearDown(store.dispose);
        final log = MapLog();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ReportForm(
                store: store,
                lat: 25.0339,
                lng: 121.5623,
                mapBuilder: pickerStandIn(log),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final list = tester
            .state<ScrollableState>(
              find
                  .descendant(
                    of: find.byType(ReportForm),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            )
            .position;
        final map = tester.getRect(find.byKey(const ValueKey('stand-in-map')));
        // Away from the marker in the middle.
        final onMap = map.topLeft + const Offset(30, 30);

        await tester.dragFrom(onMap, const Offset(0, -240));
        await tester.pumpAndSettle();
        expect(list.pixels, greaterThan(150), reason: '上滑捲動表單');
        expect(log.pans, 0);
        // The fields right after the map come into view.
        expect(find.text('基本資訊').hitTestable(), findsOneWidget);

        list.jumpTo(0);
        await tester.pumpAndSettle();
        await tester.dragFrom(onMap, const Offset(-120, 0));
        await tester.pumpAndSettle();
        expect(list.pixels, 0, reason: '左右拖曳不捲動表單');
        expect(log.pans, greaterThan(0), reason: '左右拖曳平移地圖');

        await tester.tapAt(onMap);
        await tester.pumpAndSettle();
        expect(log.taps, 1, reason: '點按交給地圖選位置');
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/ui/address_search_field.dart';
import 'package:motorcycle_parking/ui/location_picker.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _door = AddressCandidate(
  kind: AddressKind.address,
  label: '臺北市中正區忠孝西路一段49號',
  lat: 25.0478,
  lng: 121.517,
);
const _corner = AddressCandidate(
  kind: AddressKind.intersection,
  label: '中山北路二段與南京東路一段',
  place: '臺北市中山區',
  lat: 25.0521,
  lng: 121.5222,
  precision: AddressPrecision.center,
);
const _road = AddressCandidate(
  kind: AddressKind.road,
  label: '臺北市中山區南京東路一段',
  lat: 25.052,
  lng: 121.525,
  precision: AddressPrecision.center,
);

FunctionsClient _functions(int status, Object body) => FunctionsClient(
  'https://example.test/functions/v1',
  const {},
  httpClient: MockClient(
    (req) async => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  ),
);

Widget _host(Widget child, {double width = 390, double scale = 1}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: width - 32,
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );

void main() {
  test('門牌填地址；路段與路口填路段，並提醒再拖曳', () {
    expect(_door.field, 'address');
    expect(_door.reminder, isNull);
    expect(_road.field, 'road_segment');
    expect(_road.reminder, contains('中心點'));
    expect(_corner.field, 'road_segment');
    expect(_corner.reminder, contains('交會點'));
    const guess = AddressCandidate(
      kind: AddressKind.address,
      label: '某路 3 號',
      lat: 25,
      lng: 121,
      precision: AddressPrecision.interpolated,
    );
    expect(guess.reminder, contains('推估'));
  });

  test('解析候選，略過不認得的項目', () {
    final list = parseCandidates({
      'kind': 'intersection',
      'candidates': [
        {
          'kind': 'intersection',
          'label': '中山北路與南京東路',
          'lat': 25.05,
          'lng': 121.52,
          'precision': 'center',
        },
        {'kind': 'planet', 'label': 'x', 'lat': 1, 'lng': 2},
        {'kind': 'road', 'label': 'y'},
      ],
    });
    expect(list.single.kind, AddressKind.intersection);
    expect(list.single.precision, AddressPrecision.center);
    expect(
      () => parseCandidates({'oops': true}),
      throwsA(isA<AddressSearchException>()),
    );
  });

  test('Edge Function 回應與錯誤代碼', () async {
    final found = await geocodeSearch(
      _functions(200, {
        'kind': 'text',
        'candidates': [
          {
            'kind': 'address',
            'label': '臺北市中正區忠孝西路一段49號',
            'lat': 25.0478,
            'lng': 121.517,
            'precision': 'exact',
          },
        ],
      }),
      '忠孝西路一段49號',
    );
    expect(found.single.label, '臺北市中正區忠孝西路一段49號');
    for (final (status, code) in [
      (429, 'daily_limit'),
      (401, 'sign_in_required'),
      (503, 'not_configured'),
    ]) {
      await expectLater(
        geocodeSearch(_functions(status, {'error': code}), '中山北路'),
        throwsA(
          isA<AddressSearchException>().having((e) => e.code, 'code', code),
        ),
      );
    }
    await expectLater(
      geocodeSearch(_functions(500, 'oops'), '中山北路'),
      throwsA(
        isA<AddressSearchException>().having((e) => e.retryable, 'retry', true),
      ),
    );
  });

  for (final width in [390.0, 1280.0]) {
    testWidgets('寬 $width：入口開啟搜尋，點選路口後關閉、移動標記並提醒拖曳', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var at = (25.0, 121.0);
      final filled = <String, String>{};
      final queries = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => LocationPicker(
                  lat: at.$1,
                  lng: at.$2,
                  mapBuilder: (context, view) => const SizedBox.expand(),
                  onChanged: (a, b) => setState(() => at = (a, b)),
                  fills: const {'address': '地址', 'road_segment': '路段'},
                  onSearch: (context) async {
                    final c = await showAddressSearch(
                      context,
                      search: (q, {lat, lng}) async {
                        queries.add(q);
                        return [_corner, _road];
                      },
                    );
                    if (c?.field case final field?) filled[field] = c!.label;
                    return c;
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('搜尋門牌、路段或路口'));
      await tester.pumpAndSettle();
      // Phones get a sheet, wide screens a dialog.
      expect(find.byType(Dialog), width >= 600 ? findsOneWidget : findsNothing);
      final button = find.widgetWithText(OutlinedButton, '搜尋地址');
      expect(tester.widget<OutlinedButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextField), '中山北路二段與南京東路');
      await tester.pump();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(queries, ['中山北路二段與南京東路']);
      expect(find.text('臺北市中山區的路口，只到交會點'), findsOneWidget);
      expect(find.text('路段，只到中心點'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('中山北路二段與南京東路一段'));
      await tester.pumpAndSettle();
      expect(find.text('搜尋位置'), findsNothing);
      expect(at, (25.0521, 121.5222));
      expect(filled, {'road_segment': '中山北路二段與南京東路一段'});
      expect(find.textContaining('並填入「路段」'), findsOneWidget);
      expect(find.textContaining('交會點，請把標記拖到'), findsOneWidget);
    });
  }

  testWidgets('關閉搜尋不移動標記', (tester) async {
    var at = (25.0, 121.0);
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => LocationPicker(
            lat: at.$1,
            lng: at.$2,
            mapBuilder: (context, view) => const SizedBox.expand(),
            onChanged: (a, b) => setState(() => at = (a, b)),
            onSearch: (context) => showAddressSearch(
              context,
              search: (q, {lat, lng}) async => [_door],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('搜尋門牌、路段或路口'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('關閉搜尋'));
    await tester.pumpAndSettle();
    expect(at, (25.0, 121.0));
    expect(find.textContaining('已移到'), findsNothing);
  });

  testWidgets('找不到時引導改寫或拖曳；可重試的錯誤有重新搜尋', (tester) async {
    var fail = true;
    await tester.pumpWidget(
      _host(
        AddressSearchField(
          search: (q, {lat, lng}) async {
            if (fail) throw const AddressSearchException('network');
            return [];
          },
          onPicked: (_) {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '不存在的路');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.textContaining('連不上地址搜尋'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('重新搜尋'));
    await tester.pumpAndSettle();
    expect(find.textContaining('找不到「不存在的路」'), findsOneWidget);
  });

  testWidgets('次數用完時說明恢復時間，沒有重試鈕', (tester) async {
    await tester.pumpWidget(
      _host(
        AddressSearchField(
          search: (q, {lat, lng}) async =>
              throw const AddressSearchException('daily_limit'),
          onPicked: (_) {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '中山北路');
    await tester.pump();
    await tester.tap(find.text('搜尋地址'));
    await tester.pumpAndSettle();
    expect(find.textContaining('明天會恢復'), findsOneWidget);
    expect(find.text('重新搜尋'), findsNothing);
  });

  for (final (width, scale) in [(320.0, 1.0), (390.0, 1.6), (700.0, 1.0)]) {
    testWidgets('寬 $width、字級 $scale 倍：不溢出，按鈕與結果至少 48 px', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          AddressSearchField(
            search: (q, {lat, lng}) async => [_door, _corner, _road],
            onPicked: (_) {},
          ),
          width: width,
          scale: scale,
        ),
      );
      await tester.enterText(find.byType(TextField), '忠孝西路一段49號');
      await tester.pump();
      await tester.tap(find.text('搜尋地址'));
      await tester.pumpAndSettle();
      expect(find.text('臺北市中山區的路口，只到交會點'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final button = tester.getSize(find.byType(OutlinedButton));
      expect(button.height, greaterThanOrEqualTo(48));
      for (final row in find.byType(InkWell).evaluate()) {
        expect(
          tester.getSize(find.byWidget(row.widget)).height,
          greaterThanOrEqualTo(48),
        );
      }
      // The button sits under the field on phones and at large text.
      final field = tester.getRect(find.byType(TextField));
      final stacked =
          tester.getRect(find.byType(OutlinedButton)).top >= field.bottom;
      expect(stacked, width < 360 || scale > 1.5);
    });
  }

  for (final width in [390.0, 1280.0]) {
    testWidgets('寬 $width：Web 上搜尋面板擋住下層地圖的指標事件', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addressSearchInterceptsPointers = true;
      addTearDown(() => addressSearchInterceptsPointers = false);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAddressSearch(
                  context,
                  search: (q, {lat, lng}) async => [_door],
                ),
                child: const Text('開啟'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開啟'));
      await tester.pumpAndSettle();
      final guard = find.ancestor(
        of: find.byType(AddressSearchField),
        matching: find.byType(PointerInterceptor),
      );
      expect(guard, findsOneWidget);
      expect(tester.widget<PointerInterceptor>(guard).intercepting, isTrue);
      // The field, the button and the results are all inside the guard.
      await tester.enterText(find.byType(TextField), '忠孝西路一段49號');
      await tester.pump();
      await tester.tap(find.text('搜尋地址'));
      await tester.pumpAndSettle();
      for (final f in [
        find.byType(TextField),
        find.widgetWithText(OutlinedButton, '搜尋地址'),
        find.text('臺北市中正區忠孝西路一段49號'),
      ]) {
        expect(find.descendant(of: guard, matching: f), findsOneWidget);
      }
    });
  }

  testWidgets('非 Web 不攔截', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAddressSearch(
                context,
                search: (q, {lat, lng}) async => [],
              ),
              child: const Text('開啟'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('開啟'));
    await tester.pumpAndSettle();
    final guard = find.ancestor(
      of: find.byType(AddressSearchField),
      matching: find.byType(PointerInterceptor),
    );
    expect(tester.widget<PointerInterceptor>(guard).intercepting, isFalse);
  });
}

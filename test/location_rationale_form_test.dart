import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/data/app_store.dart';
import 'package:motorcycle_parking/data/repositories.dart';
import 'package:motorcycle_parking/features/report/report_sheet.dart';
import 'package:motorcycle_parking/features/report/spot_suggestions.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

import 'location_rationale_test.dart' show FakeLocationDevice;

/// Where #458 (the location explanation before the first system ask) meets
/// #462 (no county or door lookup before the rider agrees): the picker's
/// 移到我的位置 on a device never asked for location, with lookups not yet
/// agreed to.

const _spot = ParkingSpot(
  id: '00000000-0000-4000-8000-000000000458',
  name: '松壽地下停車場',
  lat: 25.0339,
  lng: 121.5623,
  city: '臺北市',
  district: '信義區',
  spaceType: SpaceType.freeMotorcycle,
);

/// Records every lookup that would leave the device; reads the position
/// through the store's real permission path with a stand-in device.
class _Store extends AppStore {
  _Store(LocalRepository local, FakeLocationDevice device)
    : super(local, null, locationDevice: device);

  final towns = <(double, double)>[];
  final doors = <(double, double)>[];

  @override
  bool get approxAddressEnabled => true;
  @override
  bool get canReport => true;
  @override
  Future<ApproxAddress?> approxAddressAt(double lat, double lng) async {
    doors.add((lat, lng));
    return const ApproxAddress('松壽路', '45');
  }

  @override
  Future<Town?> townAt(double lat, double lng) async {
    towns.add((lat, lng));
    return const Town('臺中市', '西區');
  }
}

enum _Form { report, suggestion }

final _rationale = find.byKey(const ValueKey('location-rationale'));
final _continue = find.byKey(const ValueKey('location-rationale-continue'));
final _decline = find.byKey(const ValueKey('location-rationale-decline'));
final _consent = find.byKey(const ValueKey('lookup-consent-card'));
final _agree = find.byKey(const ValueKey('lookup-consent-agree'));
final _locateButton = find.byKey(const ValueKey('location-locate'));

Future<void> _rest(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find
          .descendant(
            of: find.byType(Form).last,
            matching: find.byType(Scrollable),
          )
          .first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

Future<_Store> _open(
  WidgetTester tester,
  _Form form,
  FakeLocationDevice device,
) async {
  final store = (await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    return _Store(
      LocalRepository(await SharedPreferences.getInstance()),
      device,
    )..spots = const [_spot];
  }))!;
  addTearDown(store.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          // The app's bridge for CNBottomSheet's Material localizations.
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: child!),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => form == _Form.report
                ? showReport(context, store, 25.0339, 121.5623)
                : showSpotSuggestions(context, store, _spot),
            child: const Text('開啟'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('開啟'));
  await tester.pumpAndSettle();
  if (form == _Form.suggestion) {
    await tester.ensureVisible(find.text('位置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('位置'));
    await tester.pumpAndSettle();
  }
  await _rest(tester);
  return store;
}

Future<void> _tapLocate(WidgetTester tester) async {
  await _reveal(tester, _locateButton.last);
  await tester.tap(_locateButton.last);
  await _rest(tester);
}

/// The marker's position, as the open form holds it.
(double, double) _marker(WidgetTester tester, _Form form) {
  final dynamic state = tester.state(
    form == _Form.report
        ? find.byType(ReportForm)
        : find.byWidgetPredicate(
            (w) => '${w.runtimeType}' == '_SuggestionForm',
          ),
  );
  return (state.lat as double, state.lng as double);
}

void main() {
  for (final form in _Form.values) {
    testWidgets('${form.name}：還沒問過定位、也還沒選自動查詢時按「移到我的位置」，'
        '先說明定位，繼續後移動標記但不查縣市與門牌', (tester) async {
      final device = FakeLocationDevice();
      final store = await _open(tester, form, device);
      expect(_consent, findsOneWidget);
      final before = _marker(tester, form);

      await _tapLocate(tester);
      // The location explanation rises over the form; the system has not
      // been asked yet.
      expect(_rationale, findsOneWidget);
      expect(device.requests, 0);
      expect(tester.getRect(_continue).bottom, lessThanOrEqualTo(844));
      await tester.tap(_continue);
      await _rest(tester);

      expect(_rationale, findsNothing);
      expect(device.requests, 1);
      expect(_marker(tester, form), isNot(before));
      expect(_marker(tester, form).$1, closeTo(24.15, 1e-9));
      expect(_marker(tester, form).$2, closeTo(120.67, 1e-9));
      // #462: still no lookup before the rider agrees.
      expect(store.towns, isEmpty);
      expect(store.doors, isEmpty);
      // The consent card is still there and still works.
      expect(_consent, findsOneWidget);
      await _reveal(tester, _agree);
      await tester.tap(_agree);
      await _rest(tester);
      expect(_consent, findsNothing);
      expect(store.doors, isNotEmpty);
      expect(store.doors.last, (24.15, 120.67));
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('${form.name}：iOS 一樣先說明，繼續後移動標記、不查縣市與門牌', (tester) async {
      final device = FakeLocationDevice();
      final store = await _open(tester, form, device);
      final before = _marker(tester, form);
      await _tapLocate(tester);
      expect(_rationale, findsOneWidget);
      expect(_decline, findsNothing);
      await tester.tap(_continue);
      await _rest(tester);
      expect(device.requests, 1);
      expect(_marker(tester, form), isNot(before));
      expect(store.towns, isEmpty);
      expect(store.doors, isEmpty);
      expect(_consent, findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('${form.name}：在定位說明按「先不要」，標記不動、不查，同意卡照常可按', (tester) async {
      final device = FakeLocationDevice();
      final store = await _open(tester, form, device);
      final before = _marker(tester, form);
      await _tapLocate(tester);
      await tester.tap(_decline);
      await _rest(tester);
      expect(_rationale, findsNothing);
      expect(device.requests, 0);
      expect(_marker(tester, form), before);
      expect(find.textContaining('抓不到目前位置'), findsNothing);
      expect(store.towns, isEmpty);
      expect(store.doors, isEmpty);
      await _reveal(tester, _agree);
      await tester.tap(_agree);
      await _rest(tester);
      expect(_consent, findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  }
}

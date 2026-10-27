import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/admin/admin_app.dart';
import 'package:motorcycle_parking/admin/admin_controller.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/review/review_page.dart'
    show ChangeBand;
import 'package:motorcycle_parking/admin/spots/spot_map.dart';
import 'package:motorcycle_parking/admin/spots/spots_controller.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/closure.dart';

import 'fake_admin_gateway.dart';

Map<String, dynamic> _row(String id, {bool official = false}) => {
  'id': official ? 'official:$id' : id,
  'source': official ? 'official' : 'community',
  'name': id,
  'lat': 25.0,
  'lng': 121.5,
  'city': '臺北市',
  'space_type': 'paidMotorcycle',
  'status': 'confirmed',
  'hidden': false,
};

/// The admin map gets one jsonb value with counts (#133).
class _LimitGateway extends FakeAdminGateway {
  _LimitGateway() : super(access: adminAal2);

  @override
  Future<MapSpotPage> mapSpots(
    MapViewport bounds, {
    required bool community,
    required bool official,
    required bool hidden,
  }) async => MapSpotPage.fromJson({
    'rows': [
      for (var i = 0; i < 500; i++) _row('c$i'),
      for (var i = 0; i < 500; i++) _row('o$i', official: true),
    ],
    'counts': {
      'community': {'shown': 500, 'total': 500},
      'official': {'shown': 500, 'total': 640},
      'hidden': {'shown': 0, 'total': 3},
    },
    'truncated': true,
  });
}

/// Temporary closures on the admin site (#116; C6 canvas ClosureAdmin) and
/// the admin map's limit note (#133; canvas MapLimit).
void main() {
  final today = taiwanToday(DateTime.now());

  test('騎士回報的暫時封閉：開始日為回報日，依據為車友回報與說明', () {
    final report = ReviewReport(
      id: 'r-works',
      sourceId: communityId,
      reason: '這裡已經不能停車：施工中',
      field: 'gone',
      proposed: const {
        'closure': {'reason': 'works', 'until': '2026-11-30'},
      },
      note: '公告寫 11 月 30 日完工',
      createdAt: DateTime.utc(2026, 10, 25, 17),
    );
    final proposal = initialProposal(report, sampleSpots()[communityId]);
    expect(proposal['closure'], {
      'reason': 'works',
      'until': '2026-11-30',
      // 01:00 in Taiwan the next day.
      'since': '2026-10-26',
      'basis': '車友回報，附「公告寫 11 月 30 日完工」',
    });
    expect(
      formatValue('closure', proposal['closure']),
      '施工中，預計 11 月 30 日（一）恢復（2026-10-26 起）',
    );
    expect(formatValue('closure', null), '沒有（可以停）');
    expect(report.kind, ReviewKind.gone);
    expect(validatePatch(proposal, sampleSpots()[communityId]!), isNull);
    expect(
      validatePatch({
        'closure': {'reason': 'works'},
      }, sampleSpots()[communityId]!),
      contains('暫時無法停車'),
    );
  });

  test('地圖回傳每層數量與截斷旗標；舊版回 1,000 列時視為截斷', () {
    final page = MapSpotPage.fromJson({
      'rows': [_row('a')],
      'counts': {
        'community': {'shown': 1, 'total': 900},
      },
      'truncated': true,
    });
    expect(page.truncated, isTrue);
    expect(page.counts[SpotLayer.community], (shown: 1, total: 900));
    final cut = MapSpotPage.fromRows([
      for (var i = 0; i < 500; i++) _row('c$i'),
      for (var i = 0; i < 500; i++) _row('o$i', official: true),
    ]);
    expect(cut.truncated, isTrue);
  });

  group('點位表單：暫時無法停車', () {
    late FakeAdminGateway gateway;
    late SpotsController spots;

    setUp(() {
      gateway = FakeAdminGateway(access: adminAal2);
      spots = SpotsController(gateway);
    });
    tearDown(() => gateway.dispose());

    test('設定、延長與標記已恢復都只送 closure', () async {
      await spots.open(communityId);
      spots.setClosure(
        SpotClosure(
          reason: ClosureReason.closed,
          since: today,
          basis: '管理員設定',
        ).toJson(),
      );
      expect(spots.changes.keys, ['closure']);
      expect(await spots.save(''), isTrue);
      expect(gateway.spotUpdates.single.$2['closure'], {
        'reason': 'closed',
        'since': closureDate(today),
        'basis': '管理員設定',
      });
      spots.setClosure(null);
      expect(spots.changes, {'closure': null});
      expect(spots.changed('closure'), isTrue);
    });
  });

  group('畫面', () {
    late FakeAdminGateway gateway;
    late AdminController controller;

    tearDown(() async {
      controller.dispose();
      await gateway.dispose();
    });

    Future<void> show(WidgetTester tester, String path, Size size) async {
      controller = AdminController(gateway);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await controller.refresh();
      await tester.pumpWidget(
        AdminApp(
          controller: controller,
          initialLocation: path,
          reviewMapBuilder: (_, _) => const SizedBox(),
          locationMapBuilder: (_, _) => const SizedBox(),
          spotMapBuilder: (_, _) => const SizedBox(),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final size in const [
      Size(320, 640),
      Size(402, 874),
      Size(820, 1180),
      Size(1440, 960),
    ]) {
      testWidgets('暫時無法停車在 ${size.width.round()} px：過期待確認、標記已恢復，不溢出', (
        tester,
      ) async {
        gateway = FakeAdminGateway(access: adminAal2);
        gateway.spotRows[communityId] = {
          ...gateway.spotRows[communityId]!,
          'closure': {
            'reason': 'closed',
            'since': closureDate(today.subtract(const Duration(days: 30))),
            'until': closureDate(today.subtract(const Duration(days: 2))),
            'basis': '車友回報',
          },
          'closure_state': 'expired',
        };
        await show(tester, '/spots/$communityId', size);
        final section = find.byKey(const ValueKey('closure-section'));
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('closure-reopen')),
          200,
          scrollable: find
              .descendant(
                of: find.byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>).value.startsWith(
                        'spot-form-',
                      ),
                ),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('closure-reopen'))),
          alignment: .3,
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: section, matching: find.text('待確認')),
          findsOneWidget,
        );
        expect(find.textContaining('App 已恢復顯示，還沒有車友確認'), findsOneWidget);
        final reopen = find.byKey(const ValueKey('closure-reopen'));
        expect(tester.getSize(reopen).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        await tester.tap(reopen.hitTestable());
        await tester.pumpAndSettle();
        // The section shrank and may have scrolled away: back to it.
        final form = find.byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('closure-none')),
          -200,
          scrollable: form.last,
        );
        // Marked reopened: no cause left, the date and buttons go.
        expect(find.byKey(const ValueKey('closure-reopen')), findsNothing);
        expect(find.byKey(const ValueKey('closure-until')), findsNothing);
        expect(
          find.descendant(of: section, matching: find.byType(ChangeBand)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    for (final width in const [320.0, 402.0]) {
      testWidgets('地圖超過上限時寫明只顯示 1,000 個與各圖層數量（${width.round()} px）', (
        tester,
      ) async {
        gateway = _LimitGateway();
        controller = AdminController(gateway);
        tester.view.physicalSize = Size(width, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final map = SpotMapController(gateway);
        addTearDown(map.dispose);
        await map.show(
          const MapViewport(south: 24.9, west: 121.3, north: 25.2, east: 121.7),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(12),
                child: SpotMapControls(map: map),
              ),
            ),
          ),
        );
        expect(find.text('這個範圍的點位太多，只顯示 1,000 個'), findsOneWidget);
        expect(find.text('社群點 500・官方點 500／640'), findsOneWidget);
        expect(find.textContaining('放大地圖或關掉一個圖層'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}

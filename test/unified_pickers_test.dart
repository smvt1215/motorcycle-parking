import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/space_type_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart'
    show ShareKind;
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fold_section.dart';
import 'package:motorcycle_parking/ui/option_pill.dart';

/// The shared choice widgets of decision 57 (C6 canvas AppPatterns).
void main() {
  Future<void> pump(WidgetTester tester, Widget child, {double width = 320}) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );
  }

  test('六種格位加停車場；限時不再是格位類型（決定 62）', () {
    expect(SpaceKind.painted.map((k) => k.label), [
      '一般機車格',
      '大型重機專用格',
      '充電格',
      '身障格',
      '共用格',
      '一般汽車格',
    ]);
    expect(SpaceKind.values, [...SpaceKind.painted, SpaceKind.offStreet]);
    expect(SpaceKind.of(SpaceType.timedMotorcycle, null), SpaceKind.motorcycle);
    expect(SpaceKind.of(SpaceType.flexShared, null), SpaceKind.shared);
    expect(
      SpaceKind.shareOf(SpaceType.flexShared, null),
      ShareKind.carMotorcycle,
    );
    expect(kindText(SpaceKind.shared, ShareKind.scooterHeavy), '共用格（普通＆大型重機）');
    // Decision 63: the app's ground markings.
    expect(SpaceKind.motorcycle.markingType, SpaceType.freeMotorcycle);
    expect(SpaceKind.shared.markingType, SpaceType.flexShared);
  });

  for (final width in [320.0, 402.0, 820.0]) {
    testWidgets('格位清單列出全部類型，追問只在選中的下方（$width px）', (tester) async {
      SpaceKind? picked = SpaceKind.motorcycle;
      await pump(
        tester,
        StatefulBuilder(
          builder: (context, setState) => SpaceKindList(
            value: picked,
            followUp: const Text('追問'),
            onChanged: (v) => setState(() => picked = v),
          ),
        ),
        width: width,
      );
      for (final k in SpaceKind.values) {
        expect(find.byKey(ValueKey('space-${k.name}')), findsOne);
      }
      expect(find.text('追問'), findsOne);
      await tester.tap(find.byKey(const ValueKey('space-heavyOnly')));
      await tester.pumpAndSettle();
      expect(picked, SpaceKind.heavyOnly);
      expect(find.text('追問'), findsOne);
      for (final k in SpaceKind.values) {
        expect(
          tester.getSize(find.byKey(ValueKey('space-${k.name}'))).height,
          greaterThanOrEqualTo(48),
          reason: k.name,
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('勾選列整列可點，收合段落沒填時寫還沒填', (tester) async {
    var ticked = false;
    var open = false;
    await pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => Column(
          children: [
            OptionCheck(
              label: '也限電動機車',
              value: ticked,
              onChanged: (v) => setState(() => ticked = v),
            ),
            FoldSection(
              title: '收費（選填）',
              summary: null,
              open: open,
              onToggle: () => setState(() => open = !open),
              child: const TextField(key: ValueKey('inside')),
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('也限電動機車'));
    await tester.pump();
    expect(ticked, isTrue);
    expect(
      tester.getSize(find.byType(OptionCheck)).height,
      greaterThanOrEqualTo(48),
    );
    expect(find.text('還沒填'), findsOne);
    // Folded fields stay mounted, out of sight.
    expect(find.byKey(const ValueKey('inside')), findsNothing);
    expect(find.byKey(const ValueKey('inside'), skipOffstage: false), findsOne);
    await tester.tap(find.byKey(const ValueKey('fold-收費（選填）')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('inside')), findsOne);
    expect(find.text('還沒填'), findsNothing);
  });

  testWidgets('清單顯示每種的點位數', (tester) async {
    await pump(
      tester,
      SpaceKindList(
        value: null,
        counts: const {SpaceKind.motorcycle: 2, SpaceKind.shared: 1},
        onChanged: (_) {},
      ),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('space-motorcycle')),
        matching: find.text('2'),
      ),
      findsOne,
    );
  });
}

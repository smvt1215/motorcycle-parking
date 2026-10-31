import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/space_type_sheet.dart';
import 'package:motorcycle_parking/models/space_kind.dart';
import 'package:motorcycle_parking/models/zone_entries.dart';
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

  test('the seven bay kinds and the lot, in the canvas order (#188, P1)', () {
    expect(SpaceKind.values.map((k) => k.label), [
      '一般機車格',
      '普大共用格',
      '重機專用格',
      '汽機車共用格',
      '汽車格',
      '身障格',
      '充電格',
      '停車場',
    ]);
    expect(SpaceKind.values.map((k) => k.bay), [...BayKind.values, null]);
  });

  for (final width in [320.0, 402.0, 820.0]) {
    testWidgets('格位清單列出 7 類與停車場，追問只在選中的下面（$width px）', (tester) async {
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
      for (final kind in SpaceKind.values) {
        expect(find.byKey(ValueKey('space-${kind.name}')), findsOne);
        expect(
          tester.getSize(find.byKey(ValueKey('space-${kind.name}'))).height,
          greaterThanOrEqualTo(48),
          reason: kind.name,
        );
      }
      expect(find.text('追問'), findsOne);
      expect(
        tester.getTopLeft(find.text('追問')).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('space-scooterHeavy')))
              .dy,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('space-ev')));
      await tester.pumpAndSettle();
      expect(picked, SpaceKind.ev);
      expect(find.text('追問'), findsOne);
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

  testWidgets('each kind shows its own count', (tester) async {
    await pump(
      tester,
      SpaceKindList(
        value: null,
        counts: const {SpaceKind.motorcycle: 2, SpaceKind.scooterHeavy: 1},
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
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('space-scooterHeavy')),
        matching: find.text('1'),
      ),
      findsOne,
    );
  });
}

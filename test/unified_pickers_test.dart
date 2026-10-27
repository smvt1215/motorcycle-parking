import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/space_type_sheet.dart';
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

  test('every kind sits in one of the four groups, 普大共用 among them', () {
    expect(SpaceKindGroup.values.expand((g) => g.kinds), SpaceKind.values);
    expect(SpaceKindGroup.motorcycle.kinds, [
      SpaceKind.paidMotorcycle,
      SpaceKind.freeMotorcycle,
      SpaceKind.sharedMotorcycle,
    ]);
    expect(SpaceKind.sharedMotorcycle.label, '普大共用機車格');
    expect(SpaceKind.sharedMotorcycle.type, isNull);
  });

  for (final width in [320.0, 402.0, 820.0]) {
    testWidgets('格位分組清單只展開選中的組，其他組可點開（$width px）', (tester) async {
      SpaceKind? picked = SpaceKind.timedMotorcycle;
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
      expect(find.byKey(const ValueKey('space-timedMotorcycle')), findsOne);
      expect(find.byKey(const ValueKey('space-heavyOnly')), findsNothing);
      // The follow-up sits under the pick only.
      expect(find.text('追問'), findsOne);
      expect(find.text('重機、電動、身障'), findsOne);
      await tester.tap(find.byKey(const ValueKey('space-group-reserved')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('space-timedMotorcycle')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('space-heavyOnly')));
      await tester.pumpAndSettle();
      expect(picked, SpaceKind.heavyOnly);
      expect(find.text('追問'), findsOne);
      for (final key in ['space-heavyOnly', 'space-group-motorcycle']) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          greaterThanOrEqualTo(48),
          reason: key,
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
}

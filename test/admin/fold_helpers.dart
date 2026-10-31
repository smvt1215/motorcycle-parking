import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motorcycle_parking/ui/fold_section.dart';

/// Scrolls the spot form to the header of its folding section [title]
/// (decision 57) and returns it.
Future<Finder> revealFold(WidgetTester tester, String title) async {
  // A field scrolling itself into view ignores taps until it stops.
  await tester.pumpAndSettle();
  final header = find.byKey(ValueKey('fold-$title'));
  if (header.evaluate().isEmpty) {
    // Further down a long form: the list has not built it yet.
    final form = find
        .ancestor(
          of: find.byType(FoldSection).first,
          matching: find.byType(Scrollable),
        )
        .first;
    tester.state<ScrollableState>(form).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(header, 200, scrollable: form);
  }
  await tester.ensureVisible(header);
  await tester.pumpAndSettle();
  return header;
}

/// Opens the folding section [title] unless it is open already; one
/// section is open at a time.
Future<void> openFold(WidgetTester tester, String title) async {
  final header = await revealFold(tester, title);
  final open = find.descendant(
    of: header,
    matching: find.byIcon(Icons.expand_less),
  );
  if (open.evaluate().isEmpty) {
    await tester.tap(header);
    // It scrolls back to its title once the one above has folded.
    await tester.pumpAndSettle();
  }
}

/// Picks [scooter] and [heavy] (`allowed`, `notAllowed`, `notStated`) in
/// the spot form's 可停車種 section: every save of new or old data states
/// both vehicles (#201).
Future<void> pickVehicles(
  WidgetTester tester, {
  String scooter = 'allowed',
  String heavy = 'allowed',
}) async {
  await openFold(tester, '可停車種');
  for (final key in ['scooter_allowed-$scooter', 'heavy_allowed-$heavy']) {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }
}

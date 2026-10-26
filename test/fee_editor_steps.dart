import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Steps through the shared fee editor (lib/ui/fee_editor.dart): opens a
/// vehicle when it is collapsed, then picks a mode (`hourly`, `per_visit`,
/// `same_as`, `unknown` …). The first editor on screen is used.
Future<void> chooseFeeMode(
  WidgetTester tester,
  String vehicle,
  String mode,
) async {
  await openFeeVehicle(tester, vehicle);
  await tapFee(tester, 'fee-mode-$vehicle-$mode');
}

/// Opens [vehicle] in the first fee editor unless it is open already.
Future<void> openFeeVehicle(WidgetTester tester, String vehicle) async {
  if (find.byKey(ValueKey('fee-open-$vehicle')).evaluate().isNotEmpty) return;
  await tapFee(tester, 'fee-row-$vehicle');
}

/// Scrolls to and taps the first widget keyed [key].
Future<void> tapFee(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key)).first;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// The first text field keyed `fee-<field>-<prefix>`.
Finder feeField(String field, String prefix) =>
    find.byKey(ValueKey('fee-$field-$prefix')).first;

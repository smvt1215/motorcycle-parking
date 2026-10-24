import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/map/space_type_sheet.dart';
import 'package:motorcycle_parking/features/map/vehicle_sheet.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';

void main() {
  testWidgets('車種與格位選項可由螢幕閱讀器點擊', (tester) async {
    final handle = tester.ensureSemantics();
    final tapped = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              VehicleChoice(
                vehicle: VehicleType.heavy,
                selected: false,
                onTap: () => tapped.add('vehicle'),
              ),
              SpaceTypeOption(
                type: SpaceType.car,
                count: 3,
                selected: false,
                onTap: () => tapped.add('space'),
              ),
            ],
          ),
        ),
      ),
    );
    // Each option is one button node whose tap action reaches its handler,
    // as TalkBack and VoiceOver activate it.
    for (final label in [RegExp('^大型重機，'), RegExp('^汽車格，')]) {
      final option = find.semantics.byLabel(label);
      expect(option, findsOne);
      tester.semantics.tap(option);
    }
    expect(tapped, ['vehicle', 'space']);
    handle.dispose();
  });
}

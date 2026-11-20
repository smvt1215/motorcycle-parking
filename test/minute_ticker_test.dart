import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/ui/minute_ticker.dart';

void main() {
  testWidgets('畫面開著跨過整分時，在下一分鐘開始時重建', (tester) async {
    var now = DateTime.utc(2026, 11, 27, 11, 59, 30);
    var builds = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MinuteTicker(
          clock: () => now,
          builder: (_, at) {
            builds++;
            return Text('${at.hour}:${at.minute}');
          },
        ),
      ),
    );
    expect(find.text('11:59'), findsOneWidget);
    // Before the minute turns: no rebuild.
    await tester.pump(const Duration(seconds: 29));
    expect(builds, 1);
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('12:0'), findsOneWidget);
    expect(builds, 2);
    // It schedules the minute after as well.
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('12:1'), findsOneWidget);
    // Unmounting cancels the timer, so no timer is left pending.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

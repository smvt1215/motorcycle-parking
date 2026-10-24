import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/features/my_parking/parking_page.dart';

void main() {
  test('停車時長以天、小時、分鐘顯示', () {
    expect(parkedDuration(const Duration(seconds: 30)), '0 分鐘');
    expect(parkedDuration(const Duration(minutes: 5)), '5 分鐘');
    expect(parkedDuration(const Duration(hours: 2)), '2 小時');
    expect(parkedDuration(const Duration(hours: 2, minutes: 5)), '2 小時 5 分鐘');
    expect(parkedDuration(const Duration(days: 1)), '1 天');
    expect(parkedDuration(const Duration(days: 1, hours: 3)), '1 天 3 小時');
    // A clock set back never shows a negative time.
    expect(parkedDuration(const Duration(minutes: -3)), '0 分鐘');
  });
}

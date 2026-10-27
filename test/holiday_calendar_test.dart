import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/models/holiday_calendar.dart';

/// The government office calendar as 平日／假日 (decision 61).
void main() {
  // 114 年: 2025-02-08 (Saturday) is 補行上班.
  const y2025 = HolidayCalendar(
    years: {2025},
    off: {'2025-01-01', '2025-04-03', '2025-04-04'},
    work: {'2025-02-08'},
  );

  group('HolidayCalendar', () {
    test('內建 115、116 年：端午週五與補假是假日，一般週二是平日', () {
      final cal = builtinHolidays;
      expect(cal.covers(2026) && cal.covers(2027), isTrue);
      final dragonBoat = cal.dayOf(DateTime.utc(2026, 6, 19));
      expect(dragonBoat, (weekday: 4, off: true, known: true));
      expect(cal.dayOf(DateTime.utc(2026, 10, 26)).off, isTrue, reason: '補假');
      expect(cal.dayOf(DateTime.utc(2026, 10, 27)).off, isFalse);
      expect(cal.dayOf(DateTime.utc(2026, 10, 31)).off, isTrue, reason: '週六');
      expect(cal.dayOf(DateTime.utc(2027, 6, 9)).off, isTrue, reason: '端午');
    });

    test('補行上班的週六是平日', () {
      expect(y2025.dayOf(DateTime.utc(2025, 2, 8)).off, isFalse);
      expect(y2025.dayOf(DateTime.utc(2025, 2, 9)).off, isTrue);
      expect(y2025.dayOf(DateTime.utc(2025, 4, 3)).off, isTrue);
    });

    test('沒有日曆的年份退回週六日是假日，並標示不是日曆資料', () {
      final day = builtinHolidays.dayOf(DateTime.utc(2030, 6, 19));
      expect(day, (weekday: 2, off: false, known: false));
      expect(builtinHolidays.dayOf(DateTime.utc(2030, 6, 22)).off, isTrue);
      expect(HolidayCalendar.none.dayOf(DateTime.utc(2026, 6, 19)).off, false);
    });

    test('只讀日期，不看時區與時間', () {
      expect(builtinHolidays.dayOf(DateTime(2026, 6, 19, 23, 59)).off, isTrue);
    });

    test('holiday_calendar() 的 JSON；格式不對時為 null', () {
      final cal = HolidayCalendar.fromJson({
        'years': [2025],
        'off': ['2025-01-01'],
        'work': ['2025-02-08'],
      })!;
      expect(cal.years, {2025});
      expect(cal.dayOf(DateTime.utc(2025, 2, 8)).off, isFalse);
      expect(HolidayCalendar.fromJson(null), isNull);
      expect(HolidayCalendar.fromJson({'years': <int>[], 'off': <String>[]}), isNull);
      expect(
        HolidayCalendar.fromJson({
          'years': [2025],
          'off': ['2025/01/01'],
          'work': <String>[],
        }),
        isNull,
      );
    });

    test('後端的年份取代內建的同一年，後端沒有的年份保留內建', () {
      final remote = HolidayCalendar(
        years: const {2026},
        off: const {'2026-03-03'},
      );
      final merged = builtinHolidays.overriddenBy(remote);
      expect(merged.dayOf(DateTime.utc(2026, 3, 3)).off, isTrue);
      expect(merged.dayOf(DateTime.utc(2026, 6, 19)).off, isFalse);
      expect(merged.dayOf(DateTime.utc(2027, 6, 9)).off, isTrue);
    });
  });

  group('daysHoldOn／datedSpans', () {
    test('平日、假日看日曆；指定星期幾只看星期', () {
      const holidayFriday = (weekday: 4, off: true, known: true);
      expect(daysHoldOn('weekday', holidayFriday), isFalse);
      expect(daysHoldOn('holiday', holidayFriday), isTrue);
      expect(daysHoldOn('all', holidayFriday), isTrue);
      expect(daysHoldOn(['fri'], holidayFriday), isTrue);
      expect(daysHoldOn(['sat'], holidayFriday), isFalse);
    });

    test('跨午夜時段屬於開始那天（決定 47）', () {
      // Thursday 2026-06-18 works, Friday 06-19 is 端午.
      final thu = DateTime.utc(2026, 6, 18);
      expect(datedSpans('weekday', '20:00', '08:00', thu, builtinHolidays), [
        (-240, 480),
        (1200, 1920),
      ]);
      // Friday's night belongs to 端午 (假日), not 平日.
      expect(
        datedSpans(
          'weekday',
          '20:00',
          '08:00',
          DateTime.utc(2026, 6, 19),
          builtinHolidays,
        ),
        [(-240, 480)],
      );
      expect(
        datedSpans('weekday', '20:00', '20:00', thu, builtinHolidays),
        isEmpty,
      );
    });

    test('需要日曆的日子不在資料內才算退回', () {
      final d = DateTime.utc(2027, 12, 31);
      expect(calendarFellBack(['weekday'], d, builtinHolidays), isTrue);
      expect(calendarFellBack(['all', 'mon'], d, builtinHolidays), isFalse);
      expect(
        calendarFellBack(
          ['holiday'],
          DateTime.utc(2026, 7, 1),
          builtinHolidays,
        ),
        isFalse,
      );
    });
  });
}

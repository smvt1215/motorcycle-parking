import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/domain/parking_decision.dart';
import 'package:motorcycle_parking/features/map/spot_fees.dart';
import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/models/holiday_calendar.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/parking_condition.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fee_board.dart';
import 'package:motorcycle_parking/ui/vehicle_marks.dart';

/// [hour]:[minute] in Taiwan on 2026-10-27, a Tuesday, or on [day].
DateTime taipei(int hour, int minute, {int day = 27}) => DateTime.utc(
  2026,
  10,
  day,
  hour,
  minute,
).subtract(const Duration(hours: 8));

/// The canvas's 依時段不同: 08:00–20:00 每次 30 元, 20:00–08:00 每次 50 元.
Rate dayNight({String days = 'all'}) => Rate.fromJson({
  'mode': 'by_time',
  'periods': [
    {
      'days': days,
      'from': '08:00',
      'to': '20:00',
      'rate': {'mode': 'per_visit', 'amount': 30, 'renew': 'none'},
    },
    {
      'days': days,
      'from': '20:00',
      'to': '08:00',
      'rate': {'mode': 'per_visit', 'amount': 50, 'renew': 'midnight'},
    },
  ],
  'cross_period': 'each_period',
}, heavy: true)!;

/// The canvas's 市府轉運站 lot: 機車區 (普大共用, 試辦) and 汽車區.
ParkingSpot canvasLot({
  String expiresOn = '2026-12-31',
  bool lotWide = false,
}) => ParkingSpot.fromJson({
  // One rate for the whole lot instead of the zones' own.
  if (lotWide)
    'fee': {
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
    },
  'id': 'canvas-lot',
  'name': '市府轉運站地下停車場',
  'lat': 25.04,
  'lng': 121.57,
  'city': '臺北市',
  'district': '信義區',
  'space_type': 'offStreet',
  'facility_type': 'underground',
  'source': 'official',
  'status': 'confirmed',
  'scooter_allowed': true,
  'heavy_allowed': true,
  'parking_zones': [
    {
      'name': '機車區',
      'area': 'motorcycle',
      'access': 'scooterHeavy',
      'condition': {
        'bay': 'motorcycle',
        'use': 'share',
        'share': 'scooter_heavy',
        'charge': 'toll',
        'allow': {'scooter': true, 'heavy': true},
        'basis': {
          'source_url': 'https://pma.gov.taipei/',
          'effective_date': '2026-04-06',
          'expires_on': expiresOn,
        },
      },
      if (!lotWide)
        'fee': {
          'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
          'heavy': {'mode': 'same_as_scooter'},
        },
    },
    {
      'name': '汽車區',
      'area': 'car',
      'access': 'heavyCar',
      'condition': {
        'bay': 'car',
        'use': 'usual',
        'charge': 'toll',
        'allow': {'scooter': false, 'heavy': true},
      },
      if (!lotWide)
        'fee': {
          'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
          'heavy': {'mode': 'same_as_car'},
        },
    },
  ],
});

void main() {
  group('摘要列依目前時間選出當下時段（#120、決定 26、47）', () {
    final fee = Fee(heavy: dayNight());

    test('21:10 是夜間時段，時間不寫「現在」「隔日」，附下一段', () {
      final now = feeNowOf(fee, VehicleType.heavy, taipei(21, 10));
      expect(now.label, '大型重機費率・20:00–08:00');
      expect(now.main.text, '每次 50 元');
      expect(now.caption, '隔日另計・08:00 起每次 30 元');
      expect('$now', isNot(contains('現在')));
      expect('$now', isNot(contains('隔日 08:00')));
    });

    test('跨午夜的時段在凌晨仍成立', () {
      final now = feeNowOf(fee, VehicleType.heavy, taipei(2, 0));
      expect(now.label, '大型重機費率・20:00–08:00');
      expect(now.main.text, '每次 50 元');
    });

    test('白天時段與時段邊界', () {
      for (final t in [taipei(8, 0), taipei(10, 0), taipei(19, 59)]) {
        final now = feeNowOf(fee, VehicleType.heavy, t);
        expect(now.label, '大型重機費率・08:00–20:00');
        expect(now.main.text, '每次 30 元');
        expect(now.caption, '停多久都只收一次・20:00 起每次 50 元');
      }
      expect(
        feeNowOf(fee, VehicleType.heavy, taipei(20, 0)).main.text,
        '每次 50 元',
      );
    });

    test('時區以臺灣時間判斷，不看裝置時區', () {
      // 13:10 UTC is 21:10 in Taiwan.
      expect(
        feeNowOf(
          fee,
          VehicleType.heavy,
          DateTime.utc(2026, 10, 27, 13, 10),
        ).main.text,
        '每次 50 元',
      );
    });

    test('計次 0 元不寫免費；延長寫每次金額（#188 第 2 層）', () {
      final now = feeNowOf(
        Fee.fromJson({
          'heavy': {
            'mode': 'per_visit',
            'amount': 0,
            'renew': 'none',
            'extension_amount': 40,
          },
        }),
        VehicleType.heavy,
        taipei(14, 0),
      );
      expect(now.label, '大型重機費率');
      expect(now.main.text, '每次 0 元');
      expect(now.caption, '停多久都只收一次');
      expect('$now', isNot(contains('免費')));
    });

    test('目前不收費的時段寫「此時段不收費」，附下一段費率；摘要用「機車費率」', () {
      final now = feeNowOf(
        Fee.fromJson({
          'scooter': {
            'mode': 'by_time',
            'periods': [
              {
                'days': 'all',
                'from': '20:00',
                'to': '08:00',
                'rate': {'mode': 'free'},
              },
              {
                'days': 'all',
                'from': '08:00',
                'to': '20:00',
                'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
              },
            ],
          },
        }),
        VehicleType.scooter,
        taipei(6, 30),
      );
      expect(now.label, '機車費率・20:00–08:00');
      expect(now.main.text, '此時段不收費');
      expect(now.caption, '08:00 起每小時 10 元');
    });

    test('計時加當日上限：摘要只寫上限金額', () {
      final now = feeNowOf(
        const Fee(
          scooter: Rate(
            FeeMode.hourly,
            amount: 10,
            perMinutes: 60,
            dailyCap: 50,
            capReset: CapReset.calendarDay,
          ),
        ),
        VehicleType.scooter,
        taipei(10, 0),
      );
      expect(now.label, '機車費率');
      expect(now.main.text, '每小時 10 元');
      expect(now.caption, '當日上限 50 元');
    });

    test('時段沒有涵蓋現在：此時段費率未確認，往下看公告牌', () {
      final weekdays = Fee(heavy: dayNight(days: 'weekday'));
      // 2026-10-31 is a Saturday.
      final now = feeNowOf(weekdays, VehicleType.heavy, taipei(10, 0, day: 31));
      expect(now.label, '大型重機費率');
      expect(now.main.text, '此時段費率未確認');
      expect(now.main.tone, FeeTone.unconfirmed);
      expect(now.main.icon, isNotNull);
      expect(now.caption, '往下看完整收費公告牌');
      // Decision 47: Saturday's small hours are Friday's night period.
      expect(
        feeNowOf(weekdays, VehicleType.heavy, taipei(2, 0, day: 31)).main.text,
        '每次 50 元',
      );
      // Monday's are Sunday's, which has none.
      expect(
        feeNowOf(weekdays, VehicleType.heavy, taipei(2, 0, day: 26)).main.text,
        '此時段費率未確認',
      );
      // The same rate on a weekday is covered.
      expect(
        feeNowOf(weekdays, VehicleType.heavy, taipei(10, 0)).main.text,
        '每次 30 元',
      );
    });

    test('跨午夜時段預告的下一段依隔天的星期（Codex 審查）', () {
      final fee = Fee.fromJson({
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'free'},
            },
            {
              'days': 'weekday',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
            },
            {
              'days': 'holiday',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
          ],
        },
      });
      // 2026-10-30 is a Friday: tomorrow morning is Saturday's rate.
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(21, 10, day: 30)).caption,
        '08:00 起每小時 20 元',
      );
      // Past midnight the period ends today: Friday 02:00 → Friday's rate.
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(2, 0, day: 30)).caption,
        '08:00 起每小時 10 元',
      );
      // Sunday night → Monday: 2026-11-02 works.
      expect(
        feeNowOf(
          fee,
          VehicleType.scooter,
          DateTime.utc(2026, 11, 1, 13),
        ).caption,
        '08:00 起每小時 10 元',
      );
      // 2026-10-26 is a Monday off (補假), so 假日 (decision 61).
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(21, 0, day: 25)).caption,
        '08:00 起每小時 20 元',
      );
    });

    test('跨午夜時段依開始那天的星期，到時段結束才換（決定 47）', () {
      final fee = Fee.fromJson({
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'weekday',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'free'},
            },
            {
              'days': 'holiday',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 30, 'per_minutes': 60},
            },
          ],
        },
      });
      // Friday night is a weekday night until Saturday 08:00.
      final friday = feeNowOf(
        fee,
        VehicleType.scooter,
        taipei(21, 10, day: 30),
      );
      expect(friday.main.text, '此時段不收費');
      expect(friday.caption, '08:00 起每小時 30 元');
      final saturday = feeNowOf(
        fee,
        VehicleType.scooter,
        taipei(2, 0, day: 31),
      );
      expect(saturday.label, '機車費率・20:00–08:00');
      expect(saturday.main.text, '此時段不收費');
      // Sunday night is a holiday night until Monday 08:00.
      final sunday = feeNowOf(
        fee,
        VehicleType.scooter,
        taipei(21, 10, day: 25),
      );
      expect(sunday.main.text, '每小時 20 元');
      expect(sunday.caption, '08:00 起每小時 30 元');
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(2, 0, day: 26)).main.text,
        '每小時 20 元',
      );
      // Monday night: Tuesday's night period is the same, so 08:00.
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(21, 10, day: 26)).caption,
        '08:00 起每小時 30 元',
      );
    });

    test('預告的下一段跟隨隔天那段的實際邊界（#155 第 18 項）', () {
      final fee = Fee.fromJson({
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'weekday',
              'from': '20:00',
              'to': '08:00',
              'rate': {'mode': 'free'},
            },
            {
              'days': 'holiday',
              'from': '00:00',
              'to': '06:00',
              'rate': {'mode': 'free'},
            },
            {
              'days': 'holiday',
              'from': '06:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
            },
          ],
        },
      });
      // Friday 21:10: free into Saturday, where the free stretch is the
      // holiday's own 00:00–06:00 and charging starts at 06:00.
      final now = feeNowOf(fee, VehicleType.scooter, taipei(21, 10, day: 30));
      expect(now.main.text, '此時段不收費');
      expect(now.caption, '06:00 起每小時 20 元');
      // The same rate in the next period is not a change.
      final same = Fee.fromJson({
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '12:00',
              'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
            },
            {
              'days': 'all',
              'from': '12:00',
              'to': '18:00',
              'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
            },
            {
              'days': 'all',
              'from': '18:00',
              'to': '08:00',
              'rate': {'mode': 'free'},
            },
          ],
        },
      });
      expect(
        feeNowOf(same, VehicleType.scooter, taipei(9, 0)).caption,
        '18:00 起不收費',
      );
    });

    test('平日與假日依當天星期幾', () {
      final fee = Fee.fromJson({
        'scooter': {
          'mode': 'by_time',
          'periods': [
            {
              'days': 'weekday',
              'rate': {'mode': 'per_visit', 'amount': 10, 'renew': 'none'},
            },
            {
              'days': 'holiday',
              'rate': {'mode': 'per_visit', 'amount': 20, 'renew': 'none'},
            },
          ],
        },
      });
      expect(
        feeNowOf(fee, VehicleType.scooter, taipei(12, 0)).main.text,
        '每次 10 元',
      );
      final sunday = feeNowOf(fee, VehicleType.scooter, taipei(12, 0, day: 25));
      expect(sunday.label, '機車費率・全天');
      expect(sunday.main.text, '每次 20 元');
    });

    test('比照寫算好的金額，被比照的車種未確認時寫未提供', () {
      final follow = Fee(
        scooter: Rate.fromJson({
          'mode': 'by_time',
          'periods': [
            {
              'days': 'all',
              'from': '08:00',
              'to': '20:00',
              'rate': {'mode': 'hourly', 'amount': 15, 'per_minutes': 60},
            },
          ],
        }, heavy: false),
        heavy: const Rate(FeeMode.sameAsScooter),
      );
      expect(
        feeNowOf(follow, VehicleType.heavy, taipei(9, 0)).main.text,
        '每小時 15 元',
      );
      final missing = feeNowOf(
        const Fee(heavy: Rate(FeeMode.sameAsCar)),
        VehicleType.heavy,
        taipei(9, 0),
      );
      expect(missing.main.text, '費率未提供');
      expect(missing.main.tone, FeeTone.unconfirmed);
      final none = feeNowOf(const Fee(), VehicleType.scooter, taipei(9, 0));
      expect(none.main.text, '費率未確認，請依現場公告');
    });
  });

  group('國定假日算假日（決定 61）', () {
    /// 平日 08:00–20:00 每小時 10 元、20:00–08:00 免費; 假日全天每小時 20 元.
    final fee = Fee.fromJson({
      'scooter': {
        'mode': 'by_time',
        'periods': [
          {
            'days': 'weekday',
            'from': '08:00',
            'to': '20:00',
            'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
          },
          {
            'days': 'weekday',
            'from': '20:00',
            'to': '08:00',
            'rate': {'mode': 'free'},
          },
          {
            'days': 'holiday',
            'rate': {'mode': 'hourly', 'amount': 20, 'per_minutes': 60},
          },
        ],
      },
    });
    DateTime at(int y, int m, int d, int h, [int min = 0]) =>
        DateTime.utc(y, m, d, h, min).subtract(const Duration(hours: 8));

    test('2026-06-19 端午（週五）套假日費率', () {
      final now = feeNowOf(fee, VehicleType.scooter, at(2026, 6, 19, 10));
      expect(now.label, '機車費率・全天');
      expect(now.main.text, '每小時 20 元');
      expect(now.caption, isNull);
      // Without the calendar it is a Friday.
      expect(
        feeNowOf(
          fee,
          VehicleType.scooter,
          at(2026, 6, 19, 10),
          calendar: HolidayCalendar.none,
        ).main.text,
        '每小時 10 元',
      );
    });

    test('補假（2026-10-26 週一）是假日；隔天週二回到平日', () {
      expect(
        feeNowOf(fee, VehicleType.scooter, at(2026, 10, 26, 10)).main.text,
        '每小時 20 元',
      );
      expect(
        feeNowOf(fee, VehicleType.scooter, at(2026, 10, 27, 10)).main.text,
        '每小時 10 元',
      );
    });

    test('跨午夜：週四平日夜間延續到端午早上，之後才換假日費率（決定 47）', () {
      // 06-18 Thursday 23:00 is 平日's night; 端午's 假日 period starts at
      // 00:00, later than Thursday's night, so it holds from then.
      final night = feeNowOf(fee, VehicleType.scooter, at(2026, 6, 18, 23));
      expect(night.main.text, '此時段不收費');
      expect(night.caption, '00:00 起每小時 20 元');
      // 端午 07:00: the 假日 period (00:00) started after Thursday's night.
      expect(
        feeNowOf(fee, VehicleType.scooter, at(2026, 6, 19, 7)).main.text,
        '每小時 20 元',
      );
      // Friday 端午 21:00 is not 平日, so no free night.
      expect(
        feeNowOf(fee, VehicleType.scooter, at(2026, 6, 19, 21)).main.text,
        '每小時 20 元',
      );
      // Sunday 06-21 night: Monday's small hours belong to Sunday, a
      // 假日 without a night period, so nothing is announced.
      final sunday = feeNowOf(fee, VehicleType.scooter, at(2026, 6, 21, 23));
      expect(sunday.caption, isNull);
    });

    test('補行上班的週六是平日', () {
      const cal = HolidayCalendar(years: {2025}, work: {'2025-02-08'});
      expect(
        feeNowOf(
          fee,
          VehicleType.scooter,
          at(2025, 2, 8, 10),
          calendar: cal,
        ).main.text,
        '每小時 10 元',
      );
    });

    test('沒有日曆的年份退回週六日是假日，並標示', () {
      final now = feeNowOf(fee, VehicleType.scooter, at(2030, 6, 19, 10));
      expect(now.main.text, '每小時 10 元');
      expect(now.caption, '20:00 起不收費・$holidayFallbackNote');
      // Every day only: the calendar does not matter.
      final allDays = Fee(heavy: dayNight());
      expect(
        feeNowOf(allDays, VehicleType.heavy, at(2030, 6, 19, 10)).caption,
        isNot(contains(holidayFallbackNote)),
      );
    });
  });

  group('公告牌只列分區適用的車種（§2.6 投影）', () {
    test('分區與路邊的車種', () {
      final lot = canvasLot();
      expect(zoneFeeVehicles(lot.zones[0].condition, lot.zones[0].fee), [
        FeeVehicle.scooter,
        FeeVehicle.heavy,
      ]);
      expect(zoneFeeVehicles(lot.zones[1].condition, lot.zones[1].fee), [
        FeeVehicle.heavy,
        FeeVehicle.car,
      ]);
      expect(zoneFeeVehicles(zoneConditionOf(ParkingAccess.heavyOnly), null), [
        FeeVehicle.heavy,
      ]);
      expect(
        zoneFeeVehicles(zoneConditionOf(ParkingAccess.scooterOnly), null),
        [FeeVehicle.scooter],
      );
      expect(zoneFeeVehicles(null, null), isNull);
    });

    test('試辦到期的分區標示試辦期間費率；未到期不另標', () {
      final ended = canvasLot(expiresOn: '2026-10-05');
      final boards = feeSectionBoards(
        ended,
        decideParking(ended, VehicleType.heavy, const [], now: taipei(12, 0)),
      );
      expect(boards.map((b) => b.title), ['機車區', '汽車區']);
      expect(boards[0].trialEnded, '2026-10-05');
      expect(boards[1].trialEnded, isNull);
      final open = canvasLot();
      expect(
        feeSectionBoards(
          open,
          decideParking(open, VehicleType.heavy, const [], now: taipei(12, 0)),
        ).map((b) => b.trialEnded),
        [null, null],
      );
    });
  });

  group('#155 第 27–29 項', () {
    ParkingSpot lotOf(List<ParkingZone> zones) => ParkingSpot(
      id: 'items-27-29',
      name: '舊資料停車場',
      lat: 25.04,
      lng: 121.57,
      city: '臺北市',
      spaceType: SpaceType.offStreet,
      zones: zones,
    );

    test('第 27 項：分區有結構化費率但條件未知，汽車列仍在且寫未確認', () {
      final spot = lotOf(const [
        ParkingZone(
          name: '舊分區',
          carFeeNote: '每小時 40 元',
          fee: Fee(scooter: Rate(FeeMode.hourly, amount: 10, perMinutes: 60)),
        ),
      ]);
      final board = feeSectionBoards(spot, null).single;
      expect(board.vehicles, [
        FeeVehicle.scooter,
        FeeVehicle.heavy,
        FeeVehicle.car,
      ]);
      final car = feeBoardOf(
        board.fee!,
        vehicles: board.vehicles,
      ).firstWhere((b) => b.vehicle == FeeVehicle.car);
      expect(car.headline?.text, feeUnconfirmed);
    });

    test('第 28 項：分區說明等於舊汽車文字時不從通用說明列漏出', () {
      final spot = lotOf(const [
        ParkingZone(
          name: '汽車區',
          access: ParkingAccess.heavyCar,
          heavyFeeNote: '每次 40 元',
          carFeeNote: '每小時 30 元',
          feeNote: '每小時 30 元',
        ),
      ]);
      final legacy = feeSectionBoards(spot, null).single.legacy;
      expect(legacy.map((l) => l.$2), isNot(contains('每小時 30 元')));
      expect(legacy, contains((FeeVehicle.car, '')));
    });

    test('第 29 項：全場費率也標出分區試辦到期', () {
      final spot = canvasLot(expiresOn: '2026-10-05', lotWide: true);
      final boards = feeSectionBoards(
        spot,
        decideParking(spot, VehicleType.heavy, const [], now: taipei(12, 0)),
      );
      expect(boards.single.title, '全場');
      expect(boards.single.trialEnded, '2026-10-05');
    });
  });

  Future<void> pumpFees(
    WidgetTester tester,
    double width,
    ParkingSpot spot, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    VehicleType vehicle = VehicleType.heavy,
    DateTime? now,
  }) {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FeeNowSummary(
                    now: spotFeeNow(spot, vehicle, now ?? taipei(21, 10)),
                  ),
                  SpotFees(
                    spot: spot,
                    vehicle: vehicle,
                    decision: decideParking(
                      spot,
                      vehicle,
                      const [],
                      now: now ?? taipei(21, 10),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  double top(WidgetTester tester, Finder board, String text) => tester
      .getTopLeft(find.descendant(of: board, matching: find.text(text)))
      .dy;

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    for (final (scale, brightness) in [
      (1.0, Brightness.light),
      (1.6, Brightness.dark),
    ]) {
      testWidgets('寬 $width、字級 $scale、${brightness.name}：分區公告牌不溢出，目前車種排第一', (
        tester,
      ) async {
        await pumpFees(
          tester,
          width,
          canvasLot(),
          scale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('機車區'), findsOneWidget);
        expect(find.text('汽車區'), findsOneWidget);
        final boards = find.byKey(const ValueKey('fee-board'));
        expect(boards, findsNWidgets(2));
        // 機車區: the heavy bike first, the scooter's rate it follows (#140;
        // no factor since #188 layer 2).
        final moto = boards.first;
        expect(top(tester, moto, '大型重機'), lessThan(top(tester, moto, '普通機車')));
        expect(
          find.descendant(of: moto, matching: find.text('每小時 10 元')),
          findsNWidgets(2),
        );
        // 汽車區: heavy and car only, the scooter excluded.
        final car = boards.last;
        expect(
          find.descendant(of: car, matching: find.text('普通機車')),
          findsNothing,
        );
        expect(
          find.descendant(of: car, matching: find.text('每小時 40 元')),
          findsNWidgets(2),
        );
        expect(find.textContaining('比照'), findsNothing);
        // Two zones side by side only where the sheet is wide.
        final side =
            tester.getTopLeft(find.text('汽車區')).dy ==
            tester.getTopLeft(find.text('機車區')).dy;
        expect(side, width >= 560 + 32);
        // Nothing to tap: no target below 48 px is added.
        expect(
          find.descendant(
            of: find.byType(SpotFees),
            matching: find.byWidgetPredicate(
              (w) => w is InkWell || w is GestureDetector,
            ),
          ),
          findsNothing,
        );
      });
    }
  }

  testWidgets('普通機車騎士在機車區看到自己的車種排第一', (tester) async {
    await pumpFees(tester, 390, canvasLot(), vehicle: VehicleType.scooter);
    final moto = find.byKey(const ValueKey('fee-board')).first;
    expect(top(tester, moto, '普通機車'), lessThan(top(tester, moto, '大型重機')));
    // A zone with several rates: the summary sends the rider to the boards.
    expect(find.text('依分區計費'), findsOneWidget);
    expect(find.text('往下看完整收費公告牌'), findsOneWidget);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('寬 $width：分區沒有結構化汽車費率時寫未確認，不退回舊汽車文字（決定 45）', (tester) async {
      const spot = ParkingSpot(
        id: 'car-text',
        name: '汽車區舊文字',
        lat: 25.04,
        lng: 121.57,
        city: '臺北市',
        spaceType: SpaceType.offStreet,
        zones: [
          ParkingZone(
            name: '汽車區',
            access: ParkingAccess.heavyCar,
            carFeeNote: '每小時 50 元',
            fee: Fee(heavy: Rate(FeeMode.hourly, amount: 30, perMinutes: 60)),
          ),
        ],
      );
      await pumpFees(
        tester,
        width,
        spot,
        scale: 1.6,
        brightness: Brightness.dark,
      );
      expect(find.text('每小時 30 元'), findsWidgets);
      expect(find.textContaining('每小時 50 元'), findsNothing);
      expect(find.byKey(const ValueKey('fee-legacy-board')), findsNothing);
      // The car is listed once, unconfirmed.
      expect(find.text('汽車'), findsOneWidget);
      // Decision 54: the line says 費率未確認, the board's foot says once
      // to read the posted notice.
      expect(find.textContaining('費率未確認'), findsOneWidget);
      expect(find.text('未確認的費率請依現場公告'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('詳情開著跨過時段邊界時，摘要在下一分鐘換成新時段', (tester) async {
    var now = taipei(19, 59, day: 27).add(const Duration(seconds: 30));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MinuteTicker(
            clock: () => now,
            builder: (_, at) => FeeNowSummary(
              now: feeNowOf(Fee(heavy: dayNight()), VehicleType.heavy, at),
            ),
          ),
        ),
      ),
    );
    expect(find.text('每次 30 元'), findsOneWidget);
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('每次 50 元'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('寬 $width：試辦到期以文字＋日曆圖示標示試辦期間費率', (tester) async {
      await pumpFees(tester, width, canvasLot(expiresOn: '2026-10-05'));
      final line = find.byKey(const ValueKey('fee-trial-ended'));
      expect(line, findsOneWidget);
      expect(
        find.descendant(
          of: line,
          matching: find.text('試辦期間費率，試辦已於 2026-10-05 到期，請看現場公告'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: line,
          matching: find.byIcon(Icons.calendar_today_outlined),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final width in [320.0, 390.0, 700.0, 1280.0]) {
    testWidgets('寬 $width：路邊時段表、首段 0 元、延長與未確認車種', (tester) async {
      final street = ParkingSpot(
        id: 'street',
        name: '路邊限時格',
        lat: 25.04,
        lng: 121.56,
        city: '臺北市',
        spaceType: SpaceType.timedMotorcycle,
        fee: Fee.fromJson({
          'heavy': {
            'mode': 'per_visit',
            'amount': 0,
            'renew': 'none',
            'extension_amount': 40,
          },
          'car': dayNight().toJson(),
        }),
      );
      await pumpFees(
        tester,
        width,
        street,
        scale: 1.6,
        brightness: Brightness.dark,
        now: taipei(14, 0),
      );
      expect(tester.takeException(), isNull);
      final board = find.byKey(const ValueKey('fee-board'));
      expect(board, findsOneWidget);
      expect(
        find.descendant(of: board, matching: find.textContaining('每次 0 元')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: board, matching: find.textContaining('延長每次 40 元')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: board, matching: find.textContaining('費率未確認')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: board, matching: find.text('20:00–隔日 08:00')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: board, matching: find.textContaining('隔日另計')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: board, matching: find.text('跨時段分別計費')),
        findsOneWidget,
      );
      expect(find.textContaining('免費'), findsNothing);
      // The summary: the heavy bike's 首段 0 元 at 14:00.
      final summary = find.byKey(const ValueKey('fee-now'));
      expect(
        find.descendant(of: summary, matching: find.text('大型重機費率')),
        findsOneWidget,
      );
    });
  }

  testWidgets('沒有任何費率：公告牌與摘要都寫「費率未確認，請依現場公告」', (tester) async {
    const spot = ParkingSpot(
      id: 'none',
      name: '無費率',
      lat: 25.04,
      lng: 121.56,
      city: '臺北市',
      spaceType: SpaceType.paidMotorcycle,
    );
    await pumpFees(tester, 390, spot);
    expect(find.textContaining('費率未確認，請依現場公告'), findsNWidgets(2));
    expect(find.text('依現場公告'), findsNothing);
  });
}

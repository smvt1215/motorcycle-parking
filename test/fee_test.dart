import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/fee.dart';

void main() {
  test('費率文字與匯入資料的寫法一致', () {
    expect(
      const Fee(
        scooter: Rate(FeeMode.daily, amount: 30),
        heavy: Rate(FeeMode.sameAsScooter),
      ).summary,
      '每日 30 元（大型重機比照機車費率）',
    );
    expect(
      const Fee(
        scooter: Rate(FeeMode.hourly, amount: 40, perMinutes: 60),
        heavy: Rate(FeeMode.sameAsCar),
      ).summary,
      '每小時 40 元（大型重機比照汽車費率）',
    );
    expect(
      const Fee(
        scooter: Rate(FeeMode.free),
        heavy: Rate(FeeMode.hourly, amount: 20, perMinutes: 60, dailyCap: 100),
      ).summary,
      '機車免費；大型重機每小時 20 元，當日上限 100 元',
    );
    expect(
      const Fee(scooter: Rate(FeeMode.hourly, amount: 30, perMinutes: 240))
          .summary,
      '每 4 小時 30 元（大型重機費率未確認）',
    );
    expect(
      const Fee(scooter: Rate(FeeMode.perVisit, amount: 30, maxMinutes: 360))
          .summary,
      '每次 30 元（6 小時內）（大型重機費率未確認）',
    );
    expect(const Fee(heavy: Rate(FeeMode.posted)).summary, '大型重機依現場公告');
    expect(
      const Rate(FeeMode.hourly, amount: 15, perMinutes: 30).text,
      '每 30 分鐘 15 元',
    );
  });

  test('沒有任何車種費率時，fee_note 維持預設文字', () {
    expect(feeNoteOf(null), '請依現場公告');
    expect(feeNoteOf(const Fee()), '請依現場公告');
    expect(feeNoteOf(const Fee(scooter: Rate(FeeMode.free))), '免費（大型重機費率未確認）');
  });

  test('JSON 往返只保留該收費方式使用的欄位', () {
    const fee = Fee(
      scooter: Rate(FeeMode.hourly, amount: 20, perMinutes: 60, dailyCap: 100),
      heavy: Rate(FeeMode.sameAsCar),
    );
    expect(fee.toJson(), {
      'scooter': {
        'mode': 'hourly',
        'amount': 20,
        'per_minutes': 60,
        'daily_cap': 100,
      },
      'heavy': {'mode': 'same_as_car'},
    });
    expect(Fee.fromJson(fee.toJson()), fee);
    // A daily rate never carries an hourly period, whatever was set.
    expect(const Rate(FeeMode.daily, amount: 30, perMinutes: 60).toJson(), {
      'mode': 'daily',
      'amount': 30,
    });
  });

  test('欄位無法接受的費率讀成未確認', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'same_as_car'},
      'heavy': {'mode': 'monthly', 'amount': 300},
    });
    expect(fee.isEmpty, isTrue);
    expect(
      Rate.fromJson({'mode': 'hourly', 'amount': 20}, heavy: false),
      isNull,
    );
    expect(
      Rate.fromJson({'mode': 'daily', 'amount': 20.5}, heavy: false),
      isNull,
    );
    expect(Fee.fromJson(null).isEmpty, isTrue);
    expect(Fee.fromJson('free').isEmpty, isTrue);
  });
}

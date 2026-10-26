import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motorcycle_parking/admin/import/fee_reading.dart';
import 'package:motorcycle_parking/models/fee.dart';

const free = {'mode': 'free'};
const sameAsScooter = {'mode': 'same_as_scooter'};
Map<String, Object> hourly(int amount, [int perMinutes = 60, int? cap]) => {
  'mode': 'hourly',
  'amount': amount,
  'per_minutes': perMinutes,
  'daily_cap': ?cap,
};
Map<String, Object> visit(int amount, [int? maxMinutes]) => {
  'mode': 'per_visit',
  'amount': amount,
  'max_minutes': ?maxMinutes,
};
Map<String, Object> daily(int amount) => {'mode': 'daily', 'amount': amount};

void expectReading(
  String note,
  FeeVerdict verdict, {
  Map<String, Object>? fee,
  String? spaceType,
  String? reason,
}) {
  final reading = readFeeNote(note, spaceType: spaceType);
  expect(reading.verdict, verdict, reason: '$note → $reading');
  expect(reading.fee?.toJson(), fee, reason: '$note → $reading');
  if (reason != null) expect(reading.reason, contains(reason));
  // Every fee this reader suggests is one the column accepts.
  if (reading.fee case final fee?) {
    expect(Fee.fromJson(fee.toJson()), fee, reason: note);
  }
}

/// The notes below are written exactly as they are stored on staging
/// (sampled read-only on 2026-10-25), most common writings first.
void main() {
  group('無法判斷：沒有可轉換的費率，維持未確認', () {
    test('placeholders', () {
      for (final note in ['請依現場公告', '未知', ';', '', '  ']) {
        expectReading(note, FeeVerdict.unknown, reason: '沒有寫明費率');
      }
    });

    test('a basis with no price stays unknown', () {
      for (final note in [
        '請依現場公告（大型重機比照機車費率）',
        '請依現場公告（大型重機比照汽車費率）',
        '請依現場公告（重機專用格比照汽車費率）',
        '請依現場公告（大型重機另訂費率）',
      ]) {
        expectReading(note, FeeVerdict.unknown);
      }
    });

    test('car rates only', () {
      for (final note in [
        '小車計時(15元/半小時)',
        '小車計次(30元/6小時)',
        '小型車計時80元;小型車月租8000元;',
        '計時：小型車100元/時，停車全程以半小時計。',
        '小車平日計時(15元/半小時) 小車假日計時(20元/半小時)',
      ]) {
        expectReading(note, FeeVerdict.unknown, reason: '只有汽車費率');
      }
    });

    test('monthly passes only', () {
      expectReading('小型車月租8000元;機車月租800元;', FeeVerdict.unknown, reason: '月租');
      expectReading('月租：機車全日500元/月。', FeeVerdict.unknown);
    });
  });

  group('可轉換：社群整理的寫法', () {
    test('大型重機比照機車費率: the amount is the scooter rate', () {
      expectReading(
        '免費（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading(
        '每日 30 元（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': daily(30)},
      );
      expectReading(
        '每小時 10 元；每日 30 元（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10, 60, 30)},
      );
      expectReading(
        '每次 20 元（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': visit(20)},
      );
      expectReading(
        '機車每日 30 元（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': daily(30)},
      );
    });

    test('entrance notes beside the price do not change it', () {
      expectReading(
        '免費；機車區（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading(
        '每小時 10 元；窄車道（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10)},
      );
      expectReading(
        '每日 30 元；機車（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': daily(30)},
      );
    });

    test('monthly prices beside a daily one are ignored', () {
      expectReading(
        '每日 30 元；每月 600 元（大型重機比照機車費率）',
        FeeVerdict.convertible,
        fee: {'scooter': daily(30)},
      );
    });

    test('an unlabelled price on a heavy-only bay is the heavy rate', () {
      expectReading(
        '每 4 小時 30 元',
        FeeVerdict.convertible,
        spaceType: 'heavyOnly',
        fee: {'heavy': hourly(30, 240)},
      );
    });
  });

  group('需人工確認：社群整理的寫法', () {
    test('比照 is a rider\'s report: the heavy rate never falls back', () {
      // The amount is a suggestion for a person to check, never a fallback
      // to another vehicle's rate.
      for (final (note, fee) in [
        ('每小時 40 元（大型重機比照汽車費率）', {'heavy': hourly(40)}),
        ('每小時 30 元；每日 150 元（大型重機比照汽車費率）', {'heavy': hourly(30, 60, 150)}),
        ('每小時 30 元（重機專用格比照汽車費率）', {'heavy': hourly(30)}),
        ('免費（大型重機停汽車區）', {'heavy': free}),
        ('每小時 50 元；需管理員協助（大型重機比照汽車費率）', {'heavy': hourly(50)}),
        ('每 4 小時 50 元；注意開放時間（大型重機比照汽車費率）', {'heavy': hourly(50, 240)}),
      ]) {
        expectReading(note, FeeVerdict.manual, fee: fee, reason: '非公告明定');
      }
      // 比照機車 converts only the scooter rate it names.
      final reading = readFeeNote('每日 30 元（大型重機比照機車費率）');
      expect(reading.fee!.heavy, isNull);
      expect(reading.reason, contains('維持未確認'));
    });

    test('an unlabelled price elsewhere names no vehicle', () {
      expectReading(
        '每 4 小時 30 元',
        FeeVerdict.manual,
        spaceType: 'paidMotorcycle',
        fee: {'scooter': hourly(30, 240)},
        reason: '未註明',
      );
      expectReading(
        '免費',
        FeeVerdict.manual,
        spaceType: 'car',
        fee: {'heavy': free},
      );
    });

    test('另訂費率 is only a suggestion', () {
      expectReading(
        '免費（大型重機另訂費率）',
        FeeVerdict.manual,
        fee: {'heavy': free},
        reason: '另訂費率',
      );
      expectReading(
        '每日 80 元（大型重機另訂費率）',
        FeeVerdict.manual,
        fee: {'heavy': daily(80)},
      );
    });

    test('rates split by day, hour, zone, area or plate', () {
      for (final note in [
        '平日每小時 40 元；假日每小時 60 元（大型重機比照汽車費率）',
        '平日每日 25 元；假日每日 100 元（大型重機比照汽車費率）',
        '日間每小時 40 元；夜間每小時 10 元（大型重機比照汽車費率）',
        '室內每小時 30 元；室外每小時 20 元（大型重機比照汽車費率）',
        '黃牌每日 60 元；紅牌每日 100 元（大型重機另訂費率）',
        '機車區每日 20 元；汽車區每小時 40 元（大型重機比照機車費率）',
      ]) {
        expectReading(note, FeeVerdict.manual);
      }
    });

    test('prices that are not one rate', () {
      for (final note in [
        '每小時 40 元；每 10 小時 220 元（重機專用格比照汽車費率）',
        '每半天 50 元（大型重機比照汽車費率）',
        '每日 60 元起可能要留鑰匙（大型重機另訂費率）',
        '每小時 200 元；消費折抵；人工註記（重機專用格比照汽車費率）',
      ]) {
        expectReading(note, FeeVerdict.manual);
      }
    });

    test('a daily price below the hourly one is not a cap', () {
      expectReading('每小時 50 元；每日 20 元（大型重機比照汽車費率）', FeeVerdict.manual);
    });

    test('Taipei roadside heavy rates depend on the segment', () {
      expectReading(
        '大型重機依路段收費方式：計次每次 40 元；計時每小時 20 元、當日上限 100 元；限時格首 20 分鐘 0 元（臺北市 115/10/6 起，可斜停 2 格）',
        FeeVerdict.manual,
        reason: '路段',
      );
    });
  });

  group('可轉換：官方資料的寫法', () {
    test('Taipei semicolon lists: the motorcycle entry, not car or passes', () {
      expectReading(
        '機車計次20元;機車月租300元;身障機車月租150元;',
        FeeVerdict.convertible,
        fee: {'scooter': visit(20)},
      );
      expectReading(
        '小型車計時20元;小型車計時10元;小型車月租2200元;身障車月租1100元;機車免費;',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading('機車免費;', FeeVerdict.convertible, fee: {'scooter': free});
      expectReading(
        '小型車計時30元;小型車月租2000元;身障車月租1000元;機車計次30元;機車月租300元;',
        FeeVerdict.convertible,
        fee: {'scooter': visit(30)},
      );
    });

    test('sentences per vehicle', () {
      expectReading(
        '計時：小型車40元/時，停車全程以半小時計。月租：小型車全日4,800元/月。免費停車：機車。',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading(
        '小型車：計時 20元/時，停車全程以半小時計。機車：免費停車。',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading(
        '機車：20元/次，隔日另計。',
        FeeVerdict.convertible,
        fee: {'scooter': visit(20)},
      );
      expectReading(
        '計次：機車50元/次，隔日另計，以00時為基準。',
        FeeVerdict.convertible,
        fee: {'scooter': visit(50)},
      );
      expectReading(
        '小型車：計時 30元/時，大客車60元/時，停車全程以半小時計。機車：20元/次，隔日另計。',
        FeeVerdict.convertible,
        fee: {'scooter': visit(20)},
      );
      expectReading(
        '計時：小型車100元/時，全程以半小時計費。月租：小型車10,000元/月，機車300元/月。機車免收費。',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
    });

    test('per-day, per-hour and capped motorcycle rates', () {
      expectReading(
        '機車計次(15元/日)',
        FeeVerdict.convertible,
        fee: {'scooter': daily(15)},
      );
      expectReading(
        '機車計次(15元/日) 小車計時(15元/半小時)',
        FeeVerdict.convertible,
        fee: {'scooter': daily(15)},
      );
      expectReading(
        '計時：小型車120元/時，機車40元/時，停車全程以半小時計。月租：小型車全日10,000元/月。',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(40)},
      );
      expectReading(
        '機車：10元/時，停車未滿1小時以1小時計，逾1小時以上者，未滿半小時以半小時計；月租200元/月。',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10)},
      );
      expectReading(
        '小型車：計時 30元/時(09-18)，10元/時(18-09)，全程以半小時計；月租 全日4,200元，夜間1,000元(週一至週五19-08，週六、日及政府行政機關放假之紀念日、民俗節日之全日)。機車：計時 10元/時，當日單次停車最高收費上限20元(隔日另計)，全程以半小時計；月租300元。',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10, 60, 20)},
      );
    });

    test('a visit that ends after some hours', () {
      expectReading(
        '小型車：(1) 計時收費：每半小時50元(當日連續停放最高收費500元)。(2) 月租收費：每月3,000元(不含假日)。機車：(1) 計次收費：每次50元(離場再停或停車逾6小時則另計次收費)。 (2) 月租收費：每月1,500元(含假日)。',
        FeeVerdict.convertible,
        fee: {'scooter': visit(50, 360)},
      );
    });

    test('the same motorcycle rate on weekdays and weekends', () {
      expectReading(
        '平日 汽車：20元/H，機車：免費；假日 汽車：20元/H，機車：免費',
        FeeVerdict.convertible,
        fee: {'scooter': free},
      );
      expectReading(
        '平日 汽車：30元/H，機車：10元/H(當日上限30元)；假日 汽車：30元/H，機車：10元/H(當日上限30元)',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10, 60, 30)},
      );
    });

    test('heavy bikes named with cars', () {
      expectReading(
        '計時：小型車(含大型重型機車)20元/時，機車10元/時，當日單次停車最高收費上限20元/日，隔日另計，以00時為基準，停車全程以半小時計。月租：小型車全日4,200元/月，機車全日300元/月，大型重型機車全日4,200元/月。',
        FeeVerdict.convertible,
        fee: {'scooter': hourly(10, 60, 20), 'heavy': hourly(20)},
      );
    });

    test(
      'a heavy rate that varies stays unconfirmed beside a clear scooter one',
      () {
        expectReading(
          '計時：小型車(含大型重型機車)40元/時(08-21)、20元/時(21-08)，機車10元/時，當日單次停車最高收費上限20元/日，隔日另計，以00時為基準，停車全程以半小時計。',
          FeeVerdict.convertible,
          fee: {'scooter': hourly(10, 60, 20)},
          reason: '維持未確認',
        );
      },
    );
  });

  group('不轉換：現有費率格式無法表達的寫法', () {
    test('a multiple of another rate (臺北路外試辦機車區)', () {
      expectReading('大型重機機車費率2倍', FeeVerdict.manual, reason: '倍率');
      expectReading(
        '機車區：大型重機依機車費率 2 倍計收；汽車區依小型車費率',
        FeeVerdict.manual,
        reason: '倍率',
      );
    });

    test('a first period at 0 yuan is not free', () {
      expectReading(
        '限時格首 20 分鐘 0 元，可付 40 元延長一次',
        FeeVerdict.manual,
        reason: '0 元不等於免費',
      );
      expectReading('機車：首20分鐘0元，之後每次20元', FeeVerdict.manual);
    });

    test('a free first period for motorcycles', () {
      expectReading(
        '計時：小型車100元/時，機車20元/時，入場前30分鐘免費，停車未滿1小時以1小時計，逾1小時以上，未滿半小時以半小時計。',
        FeeVerdict.manual,
        reason: '免費時段',
      );
    });

    test('caps and visits that reset at another hour', () {
      for (final note in [
        '計次：20元/次，隔日另計(以凌晨2時為基準)。季租：全日900元/季。',
        '計時：小型車60元/時，機車10元/時，停車全程以半小時計，機車當日上限30元，並於隔日3時另計。',
        '小型車：每小時30元,平日入場24小時內最高上限360元。機車：每次20元，入場24小時後、離場另計。',
      ]) {
        expectReading(note, FeeVerdict.manual, reason: '重設時間');
      }
      // Midnight is what daily_cap and per-visit already mean.
      expectReading(
        '計次：機車50元/次，隔日另計，以00時為基準。',
        FeeVerdict.convertible,
        fee: {'scooter': visit(50)},
      );
    });

    test('rates that differ by time of day', () {
      expectReading('機車：日間10元/時(08-20)，夜間5元/時(20-08)', FeeVerdict.manual);
    });
  });

  group('需人工確認：官方資料的寫法', () {
    test('an hourly price without its period', () {
      expectReading(
        '小型車計時50元;小型車月租4000元;機車計時30元;機車月租600元;',
        FeeVerdict.manual,
        reason: '無法辨識',
      );
    });

    test('"重型機車" may include ordinary heavy scooters', () {
      expectReading(
        '小型車計時30元;小型車計時40元;小型車月租4000元;身障車月租2000元;機車計次20元;機車月租300元;身障機車月租150元;重型機車計時30元;重型機車計時40元;重型機車月租1500元;',
        FeeVerdict.manual,
        reason: '重型機車',
      );
    });

    test('a price that names no vehicle', () {
      expectReading('每小時20元', FeeVerdict.manual, reason: '未註明');
      expectReading('計次30元/6小時', FeeVerdict.manual);
      expectReading(
        '計時:周一至周四不含例假日，25元/半小時；週五至週日含例假日，30元/半小時；當日最高300元',
        FeeVerdict.manual,
      );
    });

    test('a price with no vehicle beside a motorcycle one is a suggestion', () {
      expectReading(
        '計時收費：每半小時30元(當日連續停放最高上限300元)。計次收費：機車每次30元（離場再停或跨日另計次收費）。月租收費：小型車每月2,500元；機車每月600元。電動汽車充電專用停車位充電費率：每度10元(停車費另計)。',
        FeeVerdict.manual,
        fee: {'scooter': visit(30)},
        reason: '未註明車種',
      );
    });

    test('motorcycle rates that differ by day', () {
      expectReading(
        '機車：平日80元/次，隔日另計，以0時為基準，例假日及國定假日：60元/時，全程以半小時計費。',
        FeeVerdict.manual,
      );
    });

    test('unknown motorcycle writings', () {
      expectReading(
        '汽車：半小時\$15，當日最高150；機車：一次\$30(過當日00:00重新計算)',
        FeeVerdict.manual,
      );
      expectReading(
        '小型車計時：20元/時、月租2400元；機車30/次、月租500元；大型車月租3200元',
        FeeVerdict.manual,
      );
    });

    test('towing fees mixed in', () {
      expectReading(
        '計次：小型車100元/次、機車25元/次。月租：小型車4,000元/月。違規拖吊保管費每半日計費1次，逾1小時以上未滿12小時者，以半日計費，未滿1小時免收保管費，小型車半日100元/次，機車半日25元/次。',
        FeeVerdict.manual,
        reason: '拖吊',
      );
    });
  });

  test('full-width digits and thousands separators', () {
    expectReading(
      '機車：２０元/次，隔日另計；月租1,000元/月。',
      FeeVerdict.convertible,
      fee: {'scooter': visit(20)},
    );
  });

  // Every writing in the checked-in import files, which staging holds.
  test('the import corpus: certain readings only, all valid', () {
    var convertible = 0;
    for (final path in [
      'data/imports/official/spots.json',
      'data/imports/google-mymaps/spots.json',
    ]) {
      final spots = jsonDecode(File(path).readAsStringSync()) as List;
      for (final spot in spots.cast<Map<String, dynamic>>()) {
        final note = spot['fee_note'] as String? ?? '';
        final reading = readFeeNote(
          note,
          spaceType: spot['space_type'] as String?,
        );
        if (reading.fee case final fee?) {
          expect(fee.isEmpty, isFalse, reason: note);
          expect(Fee.fromJson(fee.toJson()), fee, reason: note);
        }
        switch (reading.verdict) {
          case FeeVerdict.convertible:
            convertible++;
            expect(reading.fee, isNotNull, reason: note);
            expect(note, isNot(contains('請依現場公告')));
          case FeeVerdict.unknown:
            expect(reading.fee, isNull, reason: note);
          case FeeVerdict.manual:
            break;
        }
      }
    }
    // Most writings convert; the rest stay for a person or unconfirmed.
    expect(convertible, greaterThan(600));
  });
}

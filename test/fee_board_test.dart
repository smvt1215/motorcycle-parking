import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:motorcycle_parking/models/fee.dart';
import 'package:motorcycle_parking/ui/adaptive/adaptive.dart';
import 'package:motorcycle_parking/ui/fee_board.dart';
import 'package:motorcycle_parking/ui/vehicle_marks.dart';

/// Every line of one vehicle on the board, in reading order.
List<FeeLine> linesOf(FeeVehicleBoard b) => [
  ?b.headline,
  ...b.lines,
  for (final g in b.groups)
    for (final r in g.rows) ...r.lines,
  ?b.footer,
];

String texts(FeeVehicleBoard b) => linesOf(b).map((l) => l.text).join('|');

FeeVehicleBoard boardOf(Map<String, Object?> json, FeeVehicle v) =>
    feeBoardOf(Fee.fromJson(json)).firstWhere((b) => b.vehicle == v);

void main() {
  test('計次 0 元寫每次 0 元與延長金額，不寫免費（§2.3，#188 第 2 層）', () {
    final toll = boardOf({
      'heavy': {
        'mode': 'per_visit',
        'amount': 0,
        'renew': 'none',
        'extension_amount': 40,
      },
    }, FeeVehicle.heavy);
    expect(toll.headline!.text, '每次 0 元');
    expect(toll.lines, [
      const FeeLine('停多久都只收一次'),
      const FeeLine('延長每次 40 元', icon: Icons.add_circle_outline),
    ]);
    expect(texts(toll), isNot(contains('免費')));
    // Only a free rate reads 免費.
    expect(
      texts(
        boardOf({
          'scooter': {'mode': 'free'},
        }, FeeVehicle.scooter),
      ),
      '免費',
    );
  });

  test('計次的跨日：舊資料沒填時不顯示、不推定（Un-1）', () {
    String lines(Map<String, Object?> rate) =>
        texts(boardOf({'car': rate}, FeeVehicle.car));
    expect(lines({'mode': 'per_visit', 'amount': 40}), '每次 40 元');
    expect(
      lines({'mode': 'per_visit', 'amount': 40, 'renew': 'midnight'}),
      '每次 40 元|隔日另計',
    );
    expect(
      lines({'mode': 'per_visit', 'amount': 40, 'renew': 'none'}),
      '每次 40 元|停多久都只收一次',
    );
  });

  test('不適用的車種不上公告牌', () {
    final boards = feeBoardOf(
      Fee.fromJson({
        'scooter': {'mode': 'free'},
        'heavy': {'mode': 'not_applicable'},
        'car': {'mode': 'not_applicable'},
      }),
    );
    expect([for (final b in boards) b.vehicle], [FeeVehicle.scooter]);
  });

  test('比照只顯示算好的金額，被比照的車種未確認時寫未提供（#140）', () {
    final double = boardOf({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      'heavy': {'mode': 'same_as_scooter'},
    }, FeeVehicle.heavy);
    expect(double.headline!.text, '每小時 10 元');
    expect(texts(double), isNot(contains('比照')));
    final missing = boardOf({
      'heavy': {'mode': 'same_as_car'},
    }, FeeVehicle.heavy);
    expect(missing.headline!.text, '費率未提供');
    expect(missing.headline!.tone, FeeTone.unconfirmed);
  });

  test('時段費率：平日／假日分組，指定星期才逐日，未涵蓋寫未確認', () {
    final b = boardOf({
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
            'days': ['sat'],
            'rate': {'mode': 'per_visit', 'amount': 30, 'renew': 'none'},
          },
        ],
      },
    }, FeeVehicle.scooter);
    expect([for (final g in b.groups) g.label], ['平日', '週六', '週日']);
    expect([for (final r in b.groups[0].rows) r.time], ['08:00–20:00', '其他時間']);
    expect(b.groups[0].rows[1].lines.single.tone, FeeTone.unconfirmed);
    expect(b.groups[2].rows.single.time, '全天');
    expect(b.groups[2].rows.single.lines.single.text, '費率未確認');
    // One per-visit period: no cross-period line.
    expect(b.footer, isNull);

    final everyDay = boardOf({
      'car': {
        'mode': 'by_time',
        'periods': [
          {
            'days': 'all',
            'from': '08:00',
            'to': '20:00',
            'rate': {'mode': 'per_visit', 'amount': 30, 'renew': 'none'},
          },
          {
            'days': 'all',
            'from': '20:00',
            'to': '08:00',
            'rate': {'mode': 'per_visit', 'amount': 50, 'renew': 'midnight'},
          },
        ],
      },
    }, FeeVehicle.car);
    // Every day, fully covered: no day label, no 其他時間 (canvas).
    expect(everyDay.groups.single.label, isNull);
    expect(
      [for (final r in everyDay.groups.single.rows) r.time],
      ['08:00–20:00', '20:00–隔日 08:00'],
    );
    // An old rate without cross_period says nothing of it (Un-1).
    expect(everyDay.footer, isNull);
  });

  test('跨午夜時段算開始那天：分組與其他時間依實際涵蓋（決定 47）', () {
    Map<String, Object?> period(Object days, String from, String to) => {
      'days': days,
      'from': from,
      'to': to,
      'rate': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
    };
    final weekday = boardOf({
      'scooter': {
        'mode': 'by_time',
        'periods': [
          period('weekday', '08:00', '20:00'),
          period('weekday', '20:00', '08:00'),
        ],
      },
    }, FeeVehicle.scooter);
    // The night period sits under 平日, the day it starts.
    expect([for (final g in weekday.groups) g.label], ['平日', '假日']);
    // Monday before 08:00 belongs to Sunday night, which has no rate.
    expect(
      [for (final r in weekday.groups[0].rows) r.time],
      ['08:00–20:00', '20:00–隔日 08:00', '其他時間'],
    );
    // Saturday until 08:00 is Friday night's: not 全天 unconfirmed.
    expect(weekday.groups[1].rows.single.time, '其他時間');
    final week = boardOf({
      'scooter': {
        'mode': 'by_time',
        'periods': [
          period('all', '08:00', '20:00'),
          period('all', '20:00', '08:00'),
        ],
      },
    }, FeeVehicle.scooter);
    expect(week.groups.single.rows.map((r) => r.time), isNot(contains('其他時間')));
  });

  test('未涵蓋的時間與日子寫成編輯器提示', () {
    const rate = Rate(FeeMode.free);
    expect(
      feeGaps(const [
        FeePeriod(days: 'weekday', from: '08:00', to: '20:00', rate: rate),
      ]),
      // Decision 47: a gap is its start day's, so Friday night runs into
      // the weekend and Monday's small hours follow Sunday.
      [
        '週一 00:00–08:00',
        '週一、週二、週三、週四 20:00–隔日 08:00',
        '週五 20:00–隔日 00:00',
        '假日 全天',
      ],
    );
    // Every night filled: what is left is the weekend, whose small hours
    // Friday's night period already covers.
    expect(
      feeGaps(const [
        FeePeriod(days: 'weekday', from: '08:00', to: '20:00', rate: rate),
        FeePeriod(days: 'weekday', from: '20:00', to: '08:00', rate: rate),
      ]),
      ['週一 00:00–08:00', '週六 08:00–隔日 00:00', '週日 全天'],
    );
    expect(
      feeGaps(const [
        FeePeriod(days: 'all', from: '08:00', to: '20:00', rate: rate),
        FeePeriod(days: 'weekday', from: '20:00', to: '08:00', rate: rate),
      ]),
      ['假日 20:00–隔日 08:00'],
    );
    expect(
      feeGaps(const [
        FeePeriod(days: 'all', from: '00:00', to: '20:00', rate: rate),
      ]),
      ['20:00–隔日 00:00'],
    );
    expect(feeGaps(const [FeePeriod(days: 'all', rate: rate)]), isEmpty);
  });

  test('未涵蓋時間的精簡說法（決定 55）', () {
    const rate = Rate(FeeMode.free);
    FeePeriod p(String days, String from, String to) =>
        FeePeriod(days: days, from: from, to: to, rate: rate);
    // The decision's own example.
    expect(feeGapsBrief([p('weekday', '08:00', '20:00')]), ['平日夜間', '假日全天']);
    // Every day by day: the nights are left.
    expect(feeGapsBrief([p('all', '08:00', '20:00')]), ['每天夜間']);
    // Nights only: the days are left.
    expect(feeGapsBrief([p('all', '20:00', '08:00')]), ['每天白天']);
    // Out of the usual hours: the times themselves.
    expect(feeGapsBrief([p('all', '10:00', '16:00')]), ['16:00–隔日 10:00']);
    // A morning gap from 07:00 is day, not night.
    expect(feeGapsBrief([p('all', '09:00', '07:00')]), ['每天白天']);
    expect(feeGapsBrief([p('all', '06:00', '00:00')]), ['每天夜間']);
    expect(feeGapsBrief(const [FeePeriod(days: 'all', rate: rate)]), isEmpty);
  });

  test('公告牌每列寫「費率未確認」，底下只說一次請依現場公告（決定 54）', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
    });
    final boards = feeBoardOf(fee, vehicles: FeeVehicle.values);
    expect(
      [for (final b in boards) b.headline?.text],
      ['每小時 10 元', feeUnconfirmed, feeUnconfirmed],
    );
    expect(feeBoardHasUnconfirmed(boards), isTrue);
    expect(feeBoardHasUnconfirmed(feeBoardOf(fee)..removeLast()), isFalse);
  });

  testWidgets('公告牌底部的請依現場公告只出現一次', (tester) async {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeeBoard(fee: fee, vehicles: FeeVehicle.values),
        ),
      ),
    );
    expect(find.textContaining(feeUnconfirmed), findsNWidgets(2));
    expect(find.text(feeBoardPostedNote), findsOneWidget);
    expect(find.textContaining('請依現場公告'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FeeBoard(fee: fee, vehicles: const [FeeVehicle.scooter]),
        ),
      ),
    );
    expect(find.text(feeBoardPostedNote), findsNothing);
  });

  test('車種順序：指定的車種第一，大型重機未知時也列出', () {
    final fee = Fee.fromJson({
      'scooter': {'mode': 'hourly', 'amount': 10, 'per_minutes': 60},
      'car': {'mode': 'hourly', 'amount': 40, 'per_minutes': 60},
    });
    expect(
      [for (final b in feeBoardOf(fee)) b.vehicle],
      [FeeVehicle.scooter, FeeVehicle.heavy, FeeVehicle.car],
    );
    expect(
      [for (final b in feeBoardOf(fee, first: FeeVehicle.car)) b.vehicle],
      [FeeVehicle.car, FeeVehicle.scooter, FeeVehicle.heavy],
    );
    expect(feeBoardOf(const Fee()), isEmpty);
  });

  test('公告牌與 feeNoteOf 共用案例一致：已知車種相同、每行文字都出自句子', () {
    final cases = jsonDecode(
      File('supabase/functions/_shared/parking_contract_cases.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
    for (final c
        in (cases['fee_notes']! as List).cast<Map<String, Object?>>()) {
      final name = c['name'] as String;
      final fee = Fee.fromJson(c['fee']);
      final note = c['note'] as String;
      final boards = feeBoardOf(fee);
      if (note == defaultFeeNote) {
        expect(boards, isEmpty, reason: name);
        continue;
      }
      for (final b in boards) {
        final sentence = fee.textOf(b.vehicle.wire);
        if (sentence == null) {
          expect(linesOf(b).single.tone, FeeTone.unconfirmed, reason: name);
          continue;
        }
        for (final line in linesOf(b)) {
          if (line.tone == FeeTone.unconfirmed && line.text == feeUnconfirmed) {
            continue;
          }
          // Board lines are pieces of the sentence, never other words.
          final piece = line.text.replaceAll(RegExp(r'（[^）]*）$'), '');
          expect(sentence, contains(piece), reason: '$name: ${line.text}');
        }
        if (!sentence.contains('免費')) {
          expect(texts(b), isNot(contains('免費')), reason: name);
        }
      }
    }
  });

  for (final dark in [false, true]) {
    testWidgets('公告牌在 320 px、1.6 倍字級、${dark ? '深色' : '淺色'}不溢出且維持白底', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: FeeBoard(
                first: FeeVehicle.heavy,
                fee: Fee.fromJson({
                  'heavy': {
                    'mode': 'per_visit',
                    'amount': 0,
                    'renew': 'none',
                    'extension_amount': 40,
                  },
                  'car': {
                    'mode': 'by_time',
                    'periods': [
                      {
                        'days': 'weekday',
                        'from': '20:00',
                        'to': '08:00',
                        'rate': {
                          'mode': 'per_visit',
                          'amount': 50,
                          'renew': 'midnight',
                        },
                      },
                      {
                        'days': 'weekday',
                        'from': '08:00',
                        'to': '20:00',
                        'rate': {'mode': 'per_visit', 'amount': 30},
                      },
                    ],
                    'cross_period': 'each_period',
                  },
                }),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('延長每次 40 元', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('20:00–隔日 08:00'), findsOneWidget);
      expect(
        find.textContaining('跨時段分別計費', findRichText: true),
        findsOneWidget,
      );
      expect(find.textContaining('免費', findRichText: true), findsNothing);
      final box = tester.widget<Container>(
        find.byKey(const ValueKey('fee-board')),
      );
      expect((box.decoration! as BoxDecoration).color, const Color(0xffffffff));
      // The rider's vehicle comes first.
      expect(
        tester.getTopLeft(find.text('大型重機')).dy,
        lessThan(tester.getTopLeft(find.text('汽車')).dy),
      );
    });
  }
}

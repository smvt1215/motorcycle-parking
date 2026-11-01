import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:motorcycle_parking/admin/import/fee_reading.dart';

import '../../tool/convert_fees.dart';
import '../../tool/fee_assumptions.dart';

const _actor = '40000000-0000-4000-8000-000000000001';

SpotRow row(
  String id,
  String note, {
  String? spaceType,
  bool official = false,
}) => SpotRow(
  sourceId: official ? 'official:$id' : id,
  name: '測試點 $id',
  city: '臺北市',
  district: '中正區',
  spaceType: spaceType ?? 'offStreet',
  feeNote: note,
);

final rows = [
  // 可轉換
  row('a1', '機車計次20元;', official: true),
  row('a2', '機車每小時10元，每日上限50元', official: true),
  row('a3', '每小時 30 元', spaceType: 'heavyOnly'),
  row('a4', '免費（大型重機比照機車費率）'),
  // 無法判斷
  row('b1', '請依現場公告'),
  row('b2', '未知'),
  row('b3', '小型車每小時40元', official: true),
  // 需人工確認
  row('c1', '每小時 30 元；每日 150 元（大型重機比照汽車費率）'),
  row('c2', '機車平日20元/次，假日30元/次', official: true),
];

class FakeStore implements FeeStore {
  FakeStore(this.rows, {this.failOn});
  final List<SpotRow> rows;

  /// The call (0-based) that fails, as a network error would.
  final int? failOn;
  final calls =
      <({String actor, List<Map<String, Object?>> items, String note})>[];

  @override
  Future<List<SpotRow>> backlog() async => rows;

  @override
  Future<Map<String, Object?>> convert(
    String actor,
    List<Map<String, Object?>> items,
    String note,
  ) async {
    calls.add((actor: actor, items: items, note: note));
    if (calls.length - 1 == failOn) {
      throw const HttpException('寫入失敗：HTTP 500');
    }
    return {
      'converted': items.length - 1,
      'skipped': [
        {'source_id': items.first['source_id'], 'reason': '費率說明已變更，請重新讀取'},
      ],
    };
  }
}

void main() {
  group('解析：沿用 readFeeNote，只轉換能確定的寫法', () {
    final conversions = readAll(rows);
    Map<String, FeeVerdict> verdicts() => {
      for (final c in conversions) c.row.sourceId: c.reading.verdict,
    };

    test('verdicts', () {
      expect(verdicts(), {
        'official:a1': FeeVerdict.convertible,
        'official:a2': FeeVerdict.convertible,
        'a3': FeeVerdict.convertible,
        'a4': FeeVerdict.convertible,
        'b1': FeeVerdict.unknown,
        'b2': FeeVerdict.unknown,
        'official:b3': FeeVerdict.unknown,
        'c1': FeeVerdict.manual,
        'official:c2': FeeVerdict.manual,
      });
    });

    test('the space type decides whose rate an unlabelled note is', () {
      final heavy = conversions.firstWhere((c) => c.row.sourceId == 'a3');
      expect(heavy.reading.fee!.toJson(), {
        'heavy': {'mode': 'hourly', 'amount': 30, 'per_minutes': 60},
      });
      final unlabelled = readAll([row('x', '每小時 30 元')]).single;
      expect(unlabelled.reading.verdict, FeeVerdict.manual);
    });

    test('only convertible spots are sent, with what they were read from', () {
      final items = applyItems(conversions);
      expect(items.map((i) => i['source_id']), [
        'official:a1',
        'official:a2',
        'a3',
        'a4',
      ]);
      expect(items.first, {
        'source_id': 'official:a1',
        'fee_note': '機車計次20元;',
        'space_type': 'offStreet',
        'fee': {
          'scooter': {'mode': 'per_visit', 'amount': 20},
        },
      });
    });

    test('a manual suggestion is never sent', () {
      final manual = conversions.firstWhere((c) => c.row.sourceId == 'c1');
      expect(manual.reading.fee, isNotNull);
      expect(applyItems([manual]), isEmpty);
    });
  });

  group('報告格式', () {
    final report = previewReport(
      readAll(rows),
      at: DateTime.utc(2026, 11, 1, 3),
      source: 'example.supabase.co',
      sample: 3,
    );

    test('totals and verdict counts', () {
      expect(report, startsWith('# 費率轉換預覽（fee_note → fee）'));
      expect(report, contains('- 產生時間：2026-11-01T03:00:00.000Z'));
      expect(report, contains('- 資料來源：example.supabase.co'));
      expect(report, contains('| 沒有結構化費率的點位 | 9 |'));
      expect(report, contains('| 其中官方點／社群點 | 4／5 |'));
      expect(report, contains('| 不同的 fee_note 寫法 | 9 |'));
      expect(report, contains('| 可轉換 | 4 |'));
      expect(report, contains('| 需人工確認（本次不寫入） | 2 |'));
      expect(report, contains('| 無法判斷（維持未確認） | 3 |'));
    });

    test('grouped by reason with an example', () {
      expect(report, contains('### 無法判斷（維持未確認）（3）'));
      expect(report, contains('| 沒有寫明費率 | 2 | 2 | 未知 |'));
      expect(report, contains('| 只有汽車費率 | 1 | 1 | 小型車每小時40元 |'));
    });

    test('converted shapes', () {
      expect(report, contains('## 可轉換的結果形狀'));
      expect(report, contains('| 機車 計時＋當日上限 | 1 |'));
      expect(report, contains('| 大型重機 計時 | 1 |'));
    });

    test('a sample of convertible spots, note → fee, stable for a seed', () {
      expect(report, contains('## 隨機抽樣（可轉換 3 筆，種子 235）'));
      final sampleRows = report
          .split('\n')
          .where((l) => RegExp(r'^\| \d+ \|').hasMatch(l))
          .toList();
      expect(sampleRows, hasLength(3));
      for (final line in sampleRows) {
        expect(line, contains('`{'));
      }
      final again = previewReport(
        readAll(rows.reversed),
        at: DateTime.utc(2026, 11, 1, 3),
        source: 'example.supabase.co',
        sample: 3,
      );
      expect(again, report);
      final other = previewReport(
        readAll(rows),
        at: DateTime.utc(2026, 11, 1, 3),
        source: 'example.supabase.co',
        sample: 4,
        seed: 1,
      );
      expect(other, contains('（可轉換 4 筆，種子 1）'));
    });

    test('pipes and line breaks in notes do not break the table', () {
      final r = previewReport(
        readAll([row('p', '機車|20元/次\n汽車40元/次', official: true)]),
        at: DateTime.utc(2026),
        source: 's',
      );
      expect(r, contains(r'機車\|20元/次 汽車40元/次'));
    });
  });

  group('參數：--apply 需要明確旗標', () {
    test('the default is a preview', () {
      final o = Options.parse([]);
      expect(o.apply, isFalse);
      expect(o.sample, 20);
    });

    test('--apply needs an admin uuid and a note', () {
      expect(() => Options.parse(['--apply']), throwsA(isA<UsageException>()));
      expect(
        () => Options.parse(['--apply', '--actor', 'me', '--note', 'x']),
        throwsA(isA<UsageException>()),
      );
      expect(
        () => Options.parse(['--apply', '--actor', _actor]),
        throwsA(isA<UsageException>()),
      );
      expect(
        () => Options.parse(['--apply', '--actor', _actor, '--note', '  ']),
        throwsA(isA<UsageException>()),
      );
      final o = Options.parse([
        '--apply',
        '--actor',
        _actor,
        '--note',
        ' #235 ',
      ]);
      expect((o.apply, o.actor, o.note), (true, _actor, '#235'));
    });

    test('anything unclear is refused rather than guessed', () {
      for (final args in [
        ['--aply'],
        ['apply'],
        ['--actor', _actor],
        ['--note', 'x'],
        ['--sample'],
        ['--sample', '-1'],
        ['--out', '--apply'],
        ['--apply', '--actor', _actor, '--note', 'x', '--input', 'f.json'],
      ]) {
        expect(
          () => Options.parse(args),
          throwsA(isA<UsageException>()),
          reason: '$args',
        );
      }
    });
  });

  group('執行', () {
    final env = {
      'SUPABASE_URL': 'https://example.supabase.co',
      'SUPABASE_SERVICE_ROLE_KEY': 'secret-key',
    };
    DateTime at() => DateTime.utc(2026, 11, 1);

    test('a preview never writes', () async {
      final store = FakeStore(rows);
      final out = StringBuffer();
      final code = await run(
        [],
        env: env,
        connect: (url, key) => store,
        now: at,
        stdoutSink: out,
        stderrSink: StringBuffer(),
      );
      expect(code, 0);
      expect(store.calls, isEmpty);
      expect(out.toString(), contains('| 可轉換 | 4 |'));
      expect(out.toString(), isNot(contains('secret-key')));
      expect(out.toString(), isNot(contains('執行紀錄')));
    });

    test('--apply writes the convertible ones and logs the result', () async {
      final store = FakeStore(rows);
      final out = StringBuffer();
      final code = await run(
        ['--apply', '--actor', _actor, '--note', '#235 staging'],
        env: env,
        connect: (url, key) => store,
        now: at,
        stdoutSink: out,
        stderrSink: StringBuffer(),
      );
      expect(code, 0);
      expect(store.calls, hasLength(1));
      expect(store.calls.single.actor, _actor);
      expect(store.calls.single.note, '#235 staging');
      expect(store.calls.single.items, hasLength(4));
      expect(out.toString(), contains('# 費率轉換執行紀錄'));
      expect(out.toString(), contains('- 可轉換：4；寫入：3；略過：1'));
      expect(out.toString(), contains('| official:a1 | 費率說明已變更，請重新讀取 |'));
      expect(out.toString(), isNot(contains('secret-key')));
    });

    test('batches of at most 500', () async {
      final many = [
        for (var i = 0; i < 1001; i++) row('m$i', '機車計次20元;', official: true),
      ];
      final store = FakeStore(many);
      await run(
        ['--apply', '--actor', _actor, '--note', 'x'],
        env: env,
        connect: (url, key) => store,
        now: at,
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );
      expect(store.calls.map((c) => c.items.length), [500, 500, 1]);
    });

    test('a failed batch stops the run and keeps the log', () async {
      final many = [
        for (var i = 0; i < 1001; i++) row('m$i', '機車計次20元;', official: true),
      ];
      final store = FakeStore(many, failOn: 1);
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await run(
        ['--apply', '--actor', _actor, '--note', 'x'],
        env: env,
        connect: (url, key) => store,
        now: at,
        stdoutSink: out,
        stderrSink: err,
      );
      expect(code, 1);
      expect(store.calls, hasLength(2));
      expect(out.toString(), contains('- 可轉換：1001；寫入：499；略過：1'));
      expect(out.toString(), contains('第 2 批（第 501 筆起）失敗，之後未送出'));
      expect(err.toString(), contains('寫入未完成'));
    });

    test('missing credentials or bad flags stop before reading', () async {
      var connected = false;
      final err = StringBuffer();
      expect(
        await run(
          [],
          env: const {},
          connect: (url, key) {
            connected = true;
            return FakeStore(rows);
          },
          stdoutSink: StringBuffer(),
          stderrSink: err,
        ),
        78,
      );
      expect(err.toString(), contains('SUPABASE_SERVICE_ROLE_KEY'));
      expect(
        await run(
          ['--apply'],
          env: env,
          connect: (url, key) {
            connected = true;
            return FakeStore(rows);
          },
          stdoutSink: StringBuffer(),
          stderrSink: StringBuffer(),
        ),
        64,
      );
      expect(connected, isFalse);
    });

    test('--input previews a file without credentials', () async {
      final dir = Directory.systemTemp.createTempSync('convert_fees_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final input = File('${dir.path}/rows.json')
        ..writeAsStringSync(jsonEncode([for (final r in rows) r.toJson()]));
      final report = File('${dir.path}/preview.md');
      final code = await run(
        ['--input', input.path, '--out', report.path],
        env: const {},
        now: at,
        stdoutSink: StringBuffer(),
        stderrSink: StringBuffer(),
      );
      expect(code, 0);
      expect(report.readAsStringSync(), contains('- 資料來源：檔案 rows.json'));
      expect(report.readAsStringSync(), contains('| 可轉換 | 4 |'));
    });
  });

  group('推定規則（--assume）：逐類核准，預設不推定', () {
    final assumable = [
      row('m1', '每 4 小時 30 元', spaceType: 'paidMotorcycle'),
      row('m2', '每 4 小時 30 元'),
      row('o1', '免費', official: true),
      row('k1', '免費', spaceType: 'car'),
      row('s1', '臨停：20元/時，月租：3000元/月。機車免費。', official: true),
      row('h1', '每小時50元。大型重機每小時30元', official: true),
      row('e1', '免費（大型重機停汽車區）'),
      row('e2', '免費（大型重機另訂費率）'),
      ...rows,
    ];

    test('every 需人工確認 suggestion falls in at most one category', () {
      final categories = {
        for (final c in readAll(assumable))
          c.row.sourceId: assumptionOf(
            c.reading,
            spaceType: c.row.spaceType,
            official: c.row.official,
          ),
      };
      expect(categories, {
        'm1': 'motorcycle-bay-unlabelled',
        'm2': null, // an unlabelled community lot may be the car rate
        'official:o1': 'official-lot-unlabelled',
        'k1': 'car-bay-unlabelled',
        'official:s1': 'official-scooter-beside-unlabelled',
        'official:h1': 'official-heavy-beside-unlabelled',
        'e1': 'community-heavy-car-area',
        'e2': 'community-heavy-own-rate',
        'official:a1': null,
        'official:a2': null,
        'a3': null,
        'a4': null,
        'b1': null,
        'b2': null,
        'official:b3': null,
        'c1': 'community-heavy-as-car',
        'official:c2': null, // no suggestion
      });
    });

    test('nothing is assumed without --assume', () {
      final ids = applyItems(readAll(assumable))
          .map((i) => i['source_id'])
          .toList();
      expect(ids, ['official:a1', 'official:a2', 'a3', 'a4']);
      expect(
        readFeeNote('每 4 小時 30 元', spaceType: 'paidMotorcycle').verdict,
        FeeVerdict.manual,
      );
    });

    test('only the listed categories are converted, with the suggestion', () {
      final conversions = readAll(
        assumable,
        assume: {'motorcycle-bay-unlabelled', 'official-lot-unlabelled'},
      );
      final written = {
        for (final c in conversions)
          if (c.convertible) c.row.sourceId: c.basis,
      };
      expect(written, {
        'm1': '依推定 motorcycle-bay-unlabelled',
        'official:o1': '依推定 official-lot-unlabelled',
        'official:a1': '直接可轉換',
        'official:a2': '直接可轉換',
        'a3': '直接可轉換',
        'a4': '直接可轉換',
      });
      final m1 = applyItems(conversions.where((c) => c.row.sourceId == 'm1'))
          .single;
      expect(m1['fee'], {
        'scooter': {'mode': 'hourly', 'amount': 30, 'per_minutes': 240},
      });
    });

    test('--assume takes known categories only, repeatable', () {
      final o = Options.parse([
        '--assume',
        'motorcycle-bay-unlabelled',
        '--assume',
        'car-bay-unlabelled',
      ]);
      expect(o.assume, {'motorcycle-bay-unlabelled', 'car-bay-unlabelled'});
      expect(Options.parse([]).assume, isEmpty);
      for (final args in [
        ['--assume'],
        ['--assume', 'all'],
        ['--assume', 'motorcycle-bay'],
      ]) {
        expect(
          () => Options.parse(args),
          throwsA(isA<UsageException>()),
          reason: '$args',
        );
      }
      expect(
        () => Options.parse([
          '--apply',
          '--actor',
          _actor,
          '--note',
          'x' * 490,
          '--assume',
          'motorcycle-bay-unlabelled',
        ]),
        throwsA(isA<UsageException>()),
      );
    });

    test('the report marks each spot direct or assumed', () {
      final assume = {'motorcycle-bay-unlabelled'};
      final report = previewReport(
        readAll(assumable, assume: assume),
        at: DateTime.utc(2026, 11, 1),
        source: 's',
        assume: assume,
      );
      expect(report, contains('- 推定類別（--assume）：motorcycle-bay-unlabelled'));
      expect(report, contains('| 將寫入：直接可轉換 | 4 |'));
      expect(
        report,
        contains('| 將寫入：依推定 motorcycle-bay-unlabelled（機車格的費率未註明車種） | 1 |'),
      );
      expect(report, contains('## 將寫入的點位（5 筆）'));
      expect(
        report,
        contains('| m1 | 社群 臺北市 中正區 測試點 m1 | 依推定 motorcycle-bay-unlabelled |'),
      );
      expect(report, contains('| a3 | 社群 臺北市 中正區 測試點 a3 | 直接可轉換 |'));
      final plain = previewReport(
        readAll(assumable),
        at: DateTime.utc(2026, 11, 1),
        source: 's',
      );
      expect(plain, contains('- 推定類別（--assume）：無（預設不推定）'));
      expect(plain, isNot(contains('依推定')));
    });

    test('--apply writes each category in its own batches, noted', () async {
      final store = FakeStore(assumable);
      final out = StringBuffer();
      final code = await run(
        [
          '--apply',
          '--actor',
          _actor,
          '--note',
          '#235 staging',
          '--assume',
          'official-lot-unlabelled',
          '--assume',
          'motorcycle-bay-unlabelled',
        ],
        env: const {
          'SUPABASE_URL': 'https://example.supabase.co',
          'SUPABASE_SERVICE_ROLE_KEY': 'k',
        },
        connect: (url, key) => store,
        now: () => DateTime.utc(2026, 11, 1),
        stdoutSink: out,
        stderrSink: StringBuffer(),
      );
      expect(code, 0);
      expect(store.calls.map((c) => c.note), [
        '#235 staging',
        '#235 staging（依推定 motorcycle-bay-unlabelled）',
        '#235 staging（依推定 official-lot-unlabelled）',
      ]);
      expect(
        store.calls.map((c) => [for (final i in c.items) i['source_id']]),
        [
          ['official:a1', 'official:a2', 'a3', 'a4'],
          ['m1'],
          ['official:o1'],
        ],
      );
      // FakeStore skips the first item of every call.
      expect(out.toString(), contains('- 可轉換：6；寫入：3；略過：3'));
      expect(out.toString(), contains('  - 直接可轉換：寫入 3'));
      expect(
        out.toString(),
        contains('  - 依推定 motorcycle-bay-unlabelled：寫入 0'),
      );
    });
  });

  group('RestFeeStore', () {
    test(
      'reads both tables without a fee, page by page, with the key',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((req) async {
          requests.add(req);
          final table = req.url.pathSegments.last;
          final offset = int.parse(req.url.queryParameters['offset']!);
          final body = switch ((table, offset)) {
            ('community_spots', 0) => [
              for (var i = 0; i < 1000; i++)
                {
                  'id': 'c$i',
                  'name': 'n',
                  'space_type': 'offStreet',
                  'fee_note': '未知',
                  'status': i == 0 ? 'hidden' : 'active',
                },
            ],
            ('community_spots', 1000) => [
              {
                'id': 'c-last',
                'name': 'n',
                'fee_note': '免費（大型重機比照機車費率）',
                'status': 'active',
              },
            ],
            ('official_heavy_spots', 0) => [
              {
                'id': 'o1',
                'name': '官方',
                'fee_note': '機車計次20元;',
                'hidden': true,
              },
            ],
            _ => <Map<String, Object?>>[],
          };
          return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
        });
        final rows = await RestFeeStore(
          'https://x.supabase.co',
          'k',
          client,
        ).backlog();
        expect(rows, hasLength(1002));
        expect(rows.first.hidden, isTrue);
        expect(rows.last.sourceId, 'official:o1');
        expect(rows.last.hidden, isTrue);
        // Each table until an empty page, offsets by rows received.
        expect(
          requests.map(
            (r) =>
                '${r.url.pathSegments.last}@${r.url.queryParameters['offset']}',
          ),
          [
            'community_spots@0',
            'community_spots@1000',
            'community_spots@1001',
            'official_heavy_spots@0',
            'official_heavy_spots@1',
          ],
        );
        for (final r in requests) {
          expect(r.method, 'GET');
          expect(r.url.queryParameters['fee'], 'is.null');
          expect(r.headers['apikey'], 'k');
        }
      },
    );

    test('converts through admin_convert_fees_as', () async {
      late http.Request sent;
      final client = MockClient((req) async {
        sent = req;
        return http.Response('{"converted":1,"skipped":[]}', 200);
      });
      final result = await RestFeeStore('https://x.supabase.co', 'k', client)
          .convert(_actor, [
            {'source_id': 'a'},
          ], 'n');
      expect(result['converted'], 1);
      expect(sent.url.path, '/rest/v1/rpc/admin_convert_fees_as');
      expect(jsonDecode(sent.body), {
        'p_actor': _actor,
        'p_items': [
          {'source_id': 'a'},
        ],
        'p_note': 'n',
      });
    });

    test('an HTTP error stops the run', () async {
      final client = MockClient((req) async => http.Response('{}', 401));
      expect(
        RestFeeStore('https://x.supabase.co', 'k', client).backlog(),
        throwsA(isA<HttpException>()),
      );
    });
  });
}

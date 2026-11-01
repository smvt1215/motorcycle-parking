/// Converts existing spots' `fee_note` text into the structured `fee`
/// (#235), with the one reader there is: lib/admin/import/fee_reading.dart.
///
/// By default it only reads and writes a preview report; nothing is written
/// to the database unless `--apply` is given, and then only the spots the
/// reader marks 可轉換, through `admin_convert_fees_as` (service role, on
/// behalf of the admin named by `--actor`, audited per spot). Notes the
/// reader cannot be certain of (請依現場公告, 未知, rates by day or hour…)
/// stay unconfirmed.
///
/// ```sh
/// export SUPABASE_URL=https://<ref>.supabase.co
/// export SUPABASE_SERVICE_ROLE_KEY=...   # never written to a file
/// dart run tool/convert_fees.dart --out preview.md
/// dart run tool/convert_fees.dart --apply --actor <admin uuid> \
///   --note '#235 staging' --out run.md
/// ```
///
/// `--input rows.json` reads the spots from a file (the shape [SpotRow.fromJson]
/// takes) instead of the database, for a preview only.
///
/// `--assume <category>` (repeatable) also converts the 需人工確認 spots of a
/// 推定規則 category an admin approved (tool/fee_assumptions.dart), with the
/// reader's suggestion; none is assumed by default. The report marks each
/// spot 直接可轉換 or `依推定 <category>`, and `--apply` writes each category in
/// its own batches, with the category in the audit note.
/// `--exclude <source_id>` (repeatable) keeps a spot out of the conversion
/// whatever it reads as, for one a person will fix by hand; the report lists
/// them.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:motorcycle_parking/admin/import/fee_reading.dart';
import 'package:motorcycle_parking/models/fee.dart';

import 'fee_assumptions.dart';

final usage =
    '''
用法：dart run tool/convert_fees.dart [選項]

預設只讀取並產生預覽報告，不寫入資料庫。

  --out <檔案>       報告寫到這個檔案（預設印到標準輸出）
  --input <檔案>     從 JSON 檔讀取點位，不連資料庫（只能預覽）
  --sample <N>       抽樣筆數（預設 20）
  --seed <N>         抽樣亂數種子（預設 235）
  --assume <類別>    也轉換該推定類別的「需人工確認」點位，採解析建議值；
                     可重複給多個類別，預設不推定。類別：
${feeAssumptions.map((a) => '                       ${a.id}：${a.name}').join('\n')}
  --exclude <id>     不轉換這個點位（source_id，官方點為 official:<id>），可重複
  --apply            寫入可轉換的費率（需同時給 --actor 與 --note）
  --actor <uuid>     執行寫入的管理者帳號 id（稽核紀錄的 actor）
  --note <文字>      稽核紀錄的說明，例如 "#235 staging"
  -h, --help         顯示說明

環境變數：SUPABASE_URL、SUPABASE_SERVICE_ROLE_KEY（只從環境變數讀，不寫入任何檔案）。''';

/// The RPC's batch limit (`convert_fees_for`).
const batchSize = 500;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class UsageException implements Exception {
  UsageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Options {
  const Options({
    this.apply = false,
    this.actor,
    this.note,
    this.out,
    this.input,
    this.sample = 20,
    this.seed = 235,
    this.help = false,
    this.assume = const {},
    this.exclude = const {},
  });

  /// Spots (`--exclude <source_id>`) never converted in this run.
  final Set<String> exclude;
  final bool apply;

  /// The 推定規則 categories (`--assume`) whose suggestions are converted too.
  final Set<String> assume;
  final String? actor, note, out, input;
  final int sample, seed;
  final bool help;

  /// Parses [args]; throws [UsageException] for anything unclear, so a
  /// mistyped flag never turns into a write.
  static Options parse(List<String> args) {
    var apply = false, help = false;
    String? actor, note, out, input;
    var sample = 20, seed = 235;
    final assume = <String>{};
    final exclude = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      String value() {
        if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
          throw UsageException('$arg 需要一個值');
        }
        return args[++i];
      }

      int number() {
        final v = value();
        final n = int.tryParse(v);
        if (n == null || n < 0) throw UsageException('$arg 需要非負整數：$v');
        return n;
      }

      switch (arg) {
        case '--apply':
          apply = true;
        case '--actor':
          actor = value();
        case '--note':
          note = value();
        case '--out':
          out = value();
        case '--input':
          input = value();
        case '--sample':
          sample = number();
        case '--seed':
          seed = number();
        case '--assume':
          final id = value();
          if (!feeAssumptionIds.contains(id)) {
            throw UsageException(
              '不認得的推定類別：$id（可用：${feeAssumptionIds.join('、')}）',
            );
          }
          assume.add(id);
        case '--exclude':
          final id = value().trim();
          if (id.isEmpty) throw UsageException('--exclude 需要點位 id');
          exclude.add(id);
        case '-h' || '--help':
          help = true;
        default:
          throw UsageException('不認得的參數：$arg');
      }
    }
    if (apply) {
      if (actor == null || !_uuid.hasMatch(actor)) {
        throw UsageException('--apply 需要 --actor <管理者帳號 uuid>');
      }
      if (note == null || note.trim().isEmpty || note.trim().length > 500) {
        throw UsageException('--apply 需要 --note <1–500 字的說明>');
      }
      if (input != null) {
        throw UsageException('--apply 必須讀取資料庫的現況，不能搭配 --input');
      }
      // The audit note carries the category, so it must still fit.
      for (final id in assume) {
        if (auditNote(note.trim(), id).length > 500) {
          throw UsageException('--note 加上推定類別「$id」後超過 500 字');
        }
      }
    } else if (actor != null || note != null) {
      throw UsageException('--actor、--note 只在 --apply 時使用');
    }
    return Options(
      apply: apply,
      actor: actor,
      note: note?.trim(),
      out: out,
      input: input,
      sample: sample,
      seed: seed,
      help: help,
      assume: assume,
      exclude: exclude,
    );
  }
}

/// A spot with a fee note and no structured fee yet.
class SpotRow {
  const SpotRow({
    required this.sourceId,
    required this.name,
    required this.feeNote,
    this.city,
    this.district,
    this.spaceType,
    this.hidden = false,
  });

  /// `official:<id>` for official spots, the bare id for community ones,
  /// as the RPC takes it.
  final String sourceId;
  final String name;
  final String? city, district, spaceType;
  final String feeNote;
  final bool hidden;

  bool get official => sourceId.startsWith('official:');

  static SpotRow fromJson(Map<String, Object?> json) => SpotRow(
    sourceId: json['source_id']! as String,
    name: (json['name'] as String?) ?? '',
    city: json['city'] as String?,
    district: json['district'] as String?,
    spaceType: json['space_type'] as String?,
    feeNote: (json['fee_note'] as String?) ?? '',
    hidden: json['hidden'] == true,
  );

  Map<String, Object?> toJson() => {
    'source_id': sourceId,
    'name': name,
    'city': city,
    'district': district,
    'space_type': spaceType,
    'fee_note': feeNote,
    'hidden': hidden,
  };
}

class Conversion {
  Conversion(this.row, {Set<String> assume = const {}, this.excluded = false})
    : reading = readFeeNote(row.feeNote, spaceType: row.spaceType) {
    write = excluded
        ? null
        : feeToWrite(
            reading,
            spaceType: row.spaceType,
            official: row.official,
            assumed: assume,
          );
  }
  final SpotRow row;
  final FeeReading reading;

  /// Kept out by `--exclude`: nothing is written, whatever it reads as.
  final bool excluded;

  /// The fee to write and the 推定規則 category it rests on (null when the
  /// reader is certain); null when nothing is written.
  late final ({Fee fee, String? category})? write;

  /// Written: certain, or the suggestion of an approved category.
  bool get convertible => write != null;
  String? get category => write?.category;

  /// 直接可轉換, or `依推定 <category>`.
  String get basis => category == null ? '直接可轉換' : '依推定 $category';
}

List<Conversion> readAll(
  Iterable<SpotRow> rows, {
  Set<String> assume = const {},
  Set<String> exclude = const {},
}) => [
  for (final row in rows)
    Conversion(row, assume: assume, excluded: exclude.contains(row.sourceId)),
];

/// What `--apply` sends for [conversions]: only the convertible ones, with
/// the note and space type they were read from so the RPC skips a spot that
/// changed since.
List<Map<String, Object?>> applyItems(Iterable<Conversion> conversions) => [
  for (final c in conversions)
    if (c.write case final w?)
      {
        'source_id': c.row.sourceId,
        'fee_note': c.row.feeNote,
        'space_type': c.row.spaceType,
        'fee': w.fee.toJson(),
      },
];

/// The audit note of a batch: the admin's note, and the 推定規則 category
/// when the batch rests on one.
String auditNote(String note, String? category) =>
    category == null ? note : '$note（依推定 $category）';

const verdictLabel = {
  FeeVerdict.convertible: '可轉換',
  FeeVerdict.manual: '需人工確認（本次不寫入）',
  FeeVerdict.unknown: '無法判斷（維持未確認）',
};

/// The shape of a converted fee, e.g. `機車 計時＋上限｜大型重機 免費`.
String feeShape(Fee fee) {
  String rate(Rate r) {
    final json = r.toJson();
    return switch (json['mode']) {
      'hourly' when json['daily_cap'] != null => '計時＋當日上限',
      'hourly' => '計時',
      'per_visit' when json['renew'] == 'midnight' => '計次（隔日另計）',
      'per_visit' => '計次',
      'free' => '免費',
      final mode => '$mode',
    };
  }

  return [
    if (fee.scooter case final r?) '機車 ${rate(r)}',
    if (fee.heavy case final r?) '大型重機 ${rate(r)}',
    if (fee.car case final r?) '汽車 ${rate(r)}',
  ].join('｜');
}

String _cell(String text) =>
    text.replaceAll('|', r'\|').replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

String _clip(String text, [int max = 80]) => text.runes.length <= max
    ? text
    : '${String.fromCharCodes(text.runes.take(max))}…';

/// The preview report in Markdown: totals, counts by verdict, by reason (the
/// writing), by converted shape, and [sample] random convertible spots,
/// note → fee. [source] says where the rows came from (no secrets).
String previewReport(
  List<Conversion> conversions, {
  required DateTime at,
  required String source,
  int sample = 20,
  int seed = 235,
  Set<String> assume = const {},
  Set<String> exclude = const {},
}) {
  final out = StringBuffer();
  final total = conversions.length;
  int count(FeeVerdict v) =>
      conversions.where((c) => c.reading.verdict == v).length;
  final official = conversions.where((c) => c.row.official).length;
  final hidden = conversions.where((c) => c.row.hidden).length;
  final distinct = conversions.map((c) => c.row.feeNote).toSet().length;

  out
    ..writeln('# 費率轉換預覽（fee_note → fee）')
    ..writeln()
    ..writeln('- 產生時間：${at.toUtc().toIso8601String()}')
    ..writeln('- 資料來源：$source')
    ..writeln('- 解析規則：lib/admin/import/fee_reading.dart（readFeeNote）')
    ..writeln(
      '- 推定類別（--assume）：${assume.isEmpty ? '無（預設不推定）' : [for (final a in feeAssumptions)
              if (assume.contains(a.id)) a.id].join('、')}',
    )
    ..writeln('- 本報告為唯讀預覽，未寫入資料庫。')
    ..writeln()
    ..writeln('## 總覽')
    ..writeln()
    ..writeln('| 項目 | 筆數 |')
    ..writeln('|---|---:|')
    ..writeln('| 沒有結構化費率的點位 | $total |')
    ..writeln('| 其中官方點／社群點 | $official／${total - official} |')
    ..writeln('| 其中已隱藏 | $hidden |')
    ..writeln('| 不同的 fee_note 寫法 | $distinct |');
  for (final v in FeeVerdict.values) {
    out.writeln('| ${verdictLabel[v]} | ${count(v)} |');
  }
  final direct = conversions.where((c) => c.convertible && c.category == null);
  out.writeln('| 將寫入：直接可轉換 | ${direct.length} |');
  for (final a in feeAssumptions) {
    if (!assume.contains(a.id)) continue;
    final n = conversions.where((c) => c.category == a.id).length;
    out.writeln('| 將寫入：依推定 ${a.id}（${_cell(a.name)}） | $n |');
  }
  final excluded = conversions.where((c) => c.excluded).toList()
    ..sort((a, b) => a.row.sourceId.compareTo(b.row.sourceId));
  final present = {for (final c in conversions) c.row.sourceId};
  final missing = [...exclude.where((id) => !present.contains(id))]..sort();
  if (exclude.isNotEmpty) {
    out.writeln('| 排除（--exclude，不轉換） | ${excluded.length} |');
  }

  if (exclude.isNotEmpty) {
    out
      ..writeln()
      ..writeln('## 排除的點位（--exclude，${excluded.length} 筆）')
      ..writeln()
      ..writeln('| 點位 id | 點位 | 原文（fee_note） | 解析判斷 |')
      ..writeln('|---|---|---|---|');
    for (final c in excluded) {
      out.writeln(
        '| ${c.row.sourceId} | ${_cell(c.row.name)} | '
        '${_cell(_clip(c.row.feeNote))} | ${_cell(c.reading.reason)} |',
      );
    }
    if (missing.isNotEmpty) {
      out
        ..writeln()
        ..writeln('**找不到、未排除任何點位的 --exclude：${missing.join('、')}**');
    }
  }

  out
    ..writeln()
    ..writeln('## 依寫法分組')
    ..writeln()
    ..writeln('同一判斷理由視為同一種寫法；例句取該組最常見的原文。')
    ..writeln();
  for (final v in FeeVerdict.values) {
    final group = conversions.where((c) => c.reading.verdict == v).toList();
    if (group.isEmpty) continue;
    out
      ..writeln('### ${verdictLabel[v]}（${group.length}）')
      ..writeln()
      ..writeln('| 理由 | 筆數 | 寫法數 | 例句 |')
      ..writeln('|---|---:|---:|---|');
    final byReason = <String, List<Conversion>>{};
    for (final c in group) {
      (byReason[c.reading.reason] ??= []).add(c);
    }
    final reasons = byReason.entries.toList()
      ..sort((a, b) {
        final n = b.value.length.compareTo(a.value.length);
        return n != 0 ? n : a.key.compareTo(b.key);
      });
    for (final MapEntry(key: reason, value: rows) in reasons) {
      final notes = <String, int>{};
      for (final c in rows) {
        notes[c.row.feeNote] = (notes[c.row.feeNote] ?? 0) + 1;
      }
      final top = notes.entries.toList()
        ..sort((a, b) {
          final n = b.value.compareTo(a.value);
          return n != 0 ? n : a.key.compareTo(b.key);
        });
      out.writeln(
        '| ${_cell(reason)} | ${rows.length} | ${notes.length} | '
        '${_cell(_clip(top.first.key))} |',
      );
    }
    out.writeln();
  }

  final convertible = conversions.where((c) => c.convertible).toList();
  if (convertible.isNotEmpty) {
    final shapes = <String, int>{};
    for (final c in convertible) {
      final shape = feeShape(c.write!.fee);
      shapes[shape] = (shapes[shape] ?? 0) + 1;
    }
    final sorted = shapes.entries.toList()
      ..sort((a, b) {
        final n = b.value.compareTo(a.value);
        return n != 0 ? n : a.key.compareTo(b.key);
      });
    out
      ..writeln('## 可轉換的結果形狀')
      ..writeln()
      ..writeln('| 形狀 | 筆數 |')
      ..writeln('|---|---:|');
    for (final MapEntry(key: shape, value: n) in sorted) {
      out.writeln('| ${_cell(shape)} | $n |');
    }
    out.writeln();
  }

  // Sorted first so the same rows and seed give the same sample.
  final pool = [...convertible]
    ..sort((a, b) => a.row.sourceId.compareTo(b.row.sourceId))
    ..shuffle(Random(seed));
  final picked = pool.take(sample).toList();
  String where(Conversion c) => [
    c.row.official ? '官方' : '社群',
    c.row.city,
    c.row.district,
  ].whereType<String>().join(' ');
  out
    ..writeln('## 隨機抽樣（可轉換 ${picked.length} 筆，種子 $seed）')
    ..writeln()
    ..writeln('| # | 點位 | 依據 | 原文（fee_note） | 轉換結果 | 轉換後 fee_note |')
    ..writeln('|---:|---|---|---|---|---|');
  for (final (i, c) in picked.indexed) {
    final fee = c.write!.fee;
    out.writeln(
      '| ${i + 1} | ${_cell('${where(c)} ${c.row.name}')} | ${c.basis} | '
      '${_cell(c.row.feeNote)} | `${jsonEncode(fee.toJson())}` | '
      '${_cell(feeNoteOf(fee))} |',
    );
  }

  // Every spot to be written, so an admin can check each assumed one.
  final listed = [...convertible]
    ..sort((a, b) {
      final n = (a.category ?? '').compareTo(b.category ?? '');
      return n != 0 ? n : a.row.sourceId.compareTo(b.row.sourceId);
    });
  out
    ..writeln()
    ..writeln('## 將寫入的點位（${listed.length} 筆）')
    ..writeln()
    ..writeln('| 點位 id | 點位 | 依據 | 原文（fee_note） | 轉換結果 |')
    ..writeln('|---|---|---|---|---|');
  for (final c in listed) {
    out.writeln(
      '| ${c.row.sourceId} | ${_cell('${where(c)} ${c.row.name}')} | '
      '${c.basis} | ${_cell(_clip(c.row.feeNote))} | '
      '`${jsonEncode(c.write!.fee.toJson())}` |',
    );
  }
  return out.toString();
}

/// The database side, behind an interface so tests never touch a network.
abstract interface class FeeStore {
  Future<List<SpotRow>> backlog();
  Future<Map<String, Object?>> convert(
    String actor,
    List<Map<String, Object?>> items,
    String note,
  );
}

/// PostgREST with the service role key (bypasses RLS, reads hidden spots
/// too, like admin_fee_backlog).
class RestFeeStore implements FeeStore {
  RestFeeStore(this.url, this.key, [http.Client? client])
    : client = client ?? http.Client();
  final String url, key;
  final http.Client client;
  static const _page = 1000;

  Map<String, String> get _headers => {
    'apikey': key,
    'Authorization': 'Bearer $key',
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  Future<List<Map<String, Object?>>> _all(String table, String select) async {
    final rows = <Map<String, Object?>>[];
    for (var offset = 0; ;) {
      final uri = Uri.parse('$url/rest/v1/$table').replace(
        queryParameters: {
          'select': select,
          'fee': 'is.null',
          'order': 'id',
          'limit': '$_page',
          'offset': '$offset',
        },
      );
      final res = await client.get(uri, headers: _headers);
      if (res.statusCode != 200) {
        throw HttpException(
          '讀取 $table 失敗：HTTP ${res.statusCode} ${_clip(utf8.decode(res.bodyBytes), 300)}',
        );
      }
      final page = (jsonDecode(utf8.decode(res.bodyBytes)) as List<Object?>)
          .cast<Map<String, Object?>>();
      rows.addAll(page);
      // Until an empty page: the server may cap a page below [_page].
      if (page.isEmpty) return rows;
      offset += page.length;
    }
  }

  @override
  Future<List<SpotRow>> backlog() async {
    final community = await _all(
      'community_spots',
      'id,name,city,district,space_type,fee_note,status',
    );
    final official = await _all(
      'official_heavy_spots',
      'id,name,city,district,space_type,fee_note,hidden',
    );
    return [
      for (final r in community)
        SpotRow.fromJson({
          ...r,
          'source_id': r['id'],
          'hidden': r['status'] == 'hidden',
        }),
      for (final r in official)
        SpotRow.fromJson({...r, 'source_id': 'official:${r['id']}'}),
    ];
  }

  @override
  Future<Map<String, Object?>> convert(
    String actor,
    List<Map<String, Object?>> items,
    String note,
  ) async {
    final res = await client.post(
      Uri.parse('$url/rest/v1/rpc/admin_convert_fees_as'),
      headers: _headers,
      body: jsonEncode({'p_actor': actor, 'p_items': items, 'p_note': note}),
    );
    if (res.statusCode != 200) {
      throw HttpException(
        '寫入失敗：HTTP ${res.statusCode} ${_clip(utf8.decode(res.bodyBytes), 300)}',
      );
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>;
  }
}

/// Writes the convertible fees in batches; the run log in Markdown, and
/// whether every batch went through. A failed batch stops the run, and the
/// log still lists what the earlier batches wrote. The certain fees go
/// first, then each 推定規則 category in its own batches, so every audit row
/// says which category, if any, its fee rests on ([auditNote]).
Future<({String log, bool ok})> applyReport(
  FeeStore store,
  List<Conversion> conversions, {
  required String actor,
  required String note,
  required DateTime at,
}) async {
  final groups = <String?, List<Conversion>>{null: []};
  for (final a in feeAssumptions) {
    groups[a.id] = [];
  }
  for (final c in conversions) {
    if (c.convertible) groups[c.category]!.add(c);
  }
  final total = groups.values.fold(0, (n, g) => n + g.length);
  var converted = 0, sent = 0, batchNo = 0;
  final written = <String?, int>{};
  final skipped = <Map<String, Object?>>[];
  String? failure;
  send:
  for (final MapEntry(key: category, value: group) in groups.entries) {
    final items = applyItems(group);
    for (var i = 0; i < items.length; i += batchSize) {
      final batch = items.sublist(i, min(i + batchSize, items.length));
      batchNo++;
      try {
        final result = await store.convert(
          actor,
          batch,
          auditNote(note, category),
        );
        final n = (result['converted']! as num).toInt();
        converted += n;
        written[category] = (written[category] ?? 0) + n;
        skipped.addAll(
          (result['skipped']! as List<Object?>).cast<Map<String, Object?>>(),
        );
      } on Exception catch (e) {
        failure = '第 $batchNo 批（第 ${sent + 1} 筆起）失敗，之後未送出：$e';
        break send;
      }
      sent += batch.length;
    }
  }
  final out = StringBuffer()
    ..writeln('# 費率轉換執行紀錄')
    ..writeln()
    ..writeln('- 執行時間：${at.toUtc().toIso8601String()}')
    ..writeln('- 執行者（actor）：$actor')
    ..writeln('- 說明：${_cell(note)}')
    ..writeln('- 可轉換：$total；寫入：$converted；略過：${skipped.length}');
  for (final MapEntry(key: category, value: n) in written.entries) {
    out.writeln('  - ${category == null ? '直接可轉換' : '依推定 $category'}：寫入 $n');
  }
  out.writeln();
  if (failure != null) out.writeln('**${_cell(failure)}**\n');
  if (skipped.isNotEmpty) {
    out
      ..writeln('| 點位 | 略過原因 |')
      ..writeln('|---|---|');
    for (final s in skipped) {
      out.writeln('| ${s['source_id']} | ${_cell('${s['reason']}')} |');
    }
  }
  return (log: out.toString(), ok: failure == null);
}

Future<int> run(
  List<String> args, {
  required Map<String, String> env,
  FeeStore Function(String url, String key)? connect,
  DateTime Function()? now,
  StringSink? stdoutSink,
  StringSink? stderrSink,
}) async {
  final outSink = stdoutSink ?? stdout;
  final errSink = stderrSink ?? stderr;
  final clock = now ?? DateTime.now;
  final Options options;
  try {
    options = Options.parse(args);
  } on UsageException catch (e) {
    errSink
      ..writeln(e.message)
      ..writeln()
      ..writeln(usage);
    return 64;
  }
  if (options.help) {
    outSink.writeln(usage);
    return 0;
  }

  final List<SpotRow> rows;
  final String source;
  FeeStore? store;
  if (options.input case final path?) {
    final json = jsonDecode(File(path).readAsStringSync()) as List<Object?>;
    rows = [
      for (final r in json.cast<Map<String, Object?>>()) SpotRow.fromJson(r),
    ];
    source = '檔案 ${path.split('/').last}';
  } else {
    final url = env['SUPABASE_URL'] ?? '';
    final key = env['SUPABASE_SERVICE_ROLE_KEY'] ?? '';
    if (url.isEmpty || key.isEmpty) {
      errSink.writeln('需要環境變數 SUPABASE_URL 與 SUPABASE_SERVICE_ROLE_KEY');
      return 78;
    }
    store = (connect ?? RestFeeStore.new)(url, key);
    rows = await store.backlog();
    source = Uri.parse(url).host;
  }

  final conversions = readAll(
    rows,
    assume: options.assume,
    exclude: options.exclude,
  );
  var report = previewReport(
    conversions,
    at: clock(),
    source: source,
    sample: options.sample,
    seed: options.seed,
    assume: options.assume,
    exclude: options.exclude,
  );
  var ok = true;
  if (options.apply) {
    final result = await applyReport(
      store!,
      conversions,
      actor: options.actor!,
      note: options.note!,
      at: clock(),
    );
    report += '\n${result.log}';
    ok = result.ok;
  }
  if (options.out case final path?) {
    File(path).writeAsStringSync(report);
    errSink.writeln('報告已寫入 $path');
  } else {
    outSink.write(report);
  }
  if (!ok) errSink.writeln('寫入未完成，請看報告的執行紀錄');
  return ok ? 0 : 1;
}

Future<void> main(List<String> args) async {
  exitCode = await run(args, env: Platform.environment);
}

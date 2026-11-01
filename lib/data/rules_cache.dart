import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/parking.dart';

/// A rule as read (bundled file, backend row or cache) with its parsed form;
/// the raw row is what the cache stores, since [CityRule] has no `toJson`.
typedef RuleEntry = ({Map<String, dynamic> row, CityRule rule});

List<RuleEntry> parseRuleRows(Iterable<Map<String, dynamic>> rows) => [
  for (final row in rows) (row: row, rule: CityRule.fromJson(row)),
];

/// The rules shipped with the app (`assets/rules/parking_rules.json`).
Future<List<RuleEntry>> bundledRuleEntries() async {
  final raw = jsonDecode(
    await rootBundle.loadString('assets/rules/parking_rules.json'),
  ) as List<dynamic>;
  return parseRuleRows(raw.cast<Map<String, dynamic>>());
}

/// [base] with [over] laid on top, one rule per city and vehicle. An entry
/// of [over] replaces one of [base] when its version is the same or newer.
/// Admins maintain the remote rows and the bundled copy is the fallback, so
/// a tie keeps the admin's edit (a migration leaves such a row alone rather
/// than overwrite it); the cache, a past download, takes the same side.
List<RuleEntry> overlayRules(List<RuleEntry> base, Iterable<RuleEntry> over) {
  final rules = [...base];
  for (final entry in over) {
    final r = entry.rule;
    final i = rules.indexWhere(
      (old) => old.rule.city == r.city && old.rule.vehicle == r.vehicle,
    );
    if (i < 0) {
      rules.add(entry);
    } else if (r.version >= rules[i].rule.version) {
      rules[i] = entry;
    }
  }
  return rules;
}

/// The rules last downloaded, as [RulesCache.read] returns them.
class CachedRules {
  const CachedRules(this.entries, this.downloadedAt);
  final List<RuleEntry> entries;
  final DateTime downloadedAt;
}

/// The rules to use without the backend, with the download time of the
/// cached copy when any of its rules is among them.
class OfflineRules {
  const OfflineRules(this.rules, this.cachedAt);
  final List<CityRule> rules;
  final DateTime? cachedAt;
}

/// The cache over the bundled file, rule by rule (city + vehicle), the newer
/// version winning as in [overlayRules]. Without a usable cache, the bundled
/// file alone.
Future<OfflineRules> offlineRules(RulesCache? cache) async {
  final bundled = await bundledRuleEntries();
  final cached = await cache?.read();
  if (cached == null) {
    return OfflineRules([for (final e in bundled) e.rule], null);
  }
  final merged = overlayRules(bundled, cached.entries);
  final fromCache = {for (final e in cached.entries) e.rule};
  final used = merged.any((e) => fromCache.contains(e.rule));
  return OfflineRules([
    for (final e in merged) e.rule,
  ], used ? cached.downloadedAt : null);
}

/// The merged rules of the last successful download, kept in the app's
/// support directory for offline launches (#202).
///
/// The file holds `{"schema": 1, "downloaded_at": "UTC ISO 8601", "rules":
/// [rows]}`. It is written to a temporary file first and renamed over the
/// old one, so a crash mid-write leaves the previous copy intact.
class RulesCache {
  RulesCache({
    Future<Directory> Function()? directory,
    DateTime Function()? clock,
  }) : _directory = directory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now;

  static const schema = 1;
  static const fileName = 'city_rules_cache.json';

  final Future<Directory> Function() _directory;
  final DateTime Function() _clock;

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  /// The write in progress; the next one waits for it, so two downloads
  /// finishing together never touch the same temporary file.
  Future<void> _writing = Future.value();
  int _writes = 0;

  /// Stores [rows]; a failure is logged and otherwise ignored, since the
  /// rules in memory are already good. Writes run one after another.
  Future<void> write(List<Map<String, dynamic>> rows) =>
      _writing = _writing.then((_) => _write(rows, _writes++));

  Future<void> _write(List<Map<String, dynamic>> rows, int n) async {
    File? temp;
    try {
      final file = await _file();
      temp = File('${file.path}.$n.tmp');
      await temp.parent.create(recursive: true);
      await temp.writeAsString(
        jsonEncode({
          'schema': schema,
          'downloaded_at': _clock().toUtc().toIso8601String(),
          'rules': rows,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (e) {
      debugPrint('規則快取寫入失敗：$e');
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
    }
  }

  /// The cached rules, or null when there are none or they cannot be read.
  /// A file that is not valid JSON, has another schema or holds a rule that
  /// does not parse is deleted, so the next download writes a fresh one.
  Future<CachedRules?> read() async {
    final File file;
    final String text;
    try {
      file = await _file();
      if (!await file.exists()) return null;
      text = await file.readAsString();
    } catch (e) {
      debugPrint('規則快取讀取失敗：$e');
      return null;
    }
    try {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (json['schema'] != schema) {
        throw FormatException('schema ${json['schema']}');
      }
      final downloadedAt = DateTime.parse(json['downloaded_at'] as String);
      final rows = (json['rules'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      return CachedRules(parseRuleRows(rows), downloadedAt);
    } catch (e) {
      debugPrint('規則快取損毀，已刪除：$e');
      try {
        await file.delete();
      } catch (_) {}
      return null;
    }
  }
}

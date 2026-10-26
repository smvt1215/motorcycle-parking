import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/parking.dart';
import '../admin_gateway.dart';
import 'rule_models.dart';

/// The rule file bundled in the app, which riders use offline and before
/// the database answers.
Future<List<dynamic>> bundledRules() async =>
    jsonDecode(await rootBundle.loadString('assets/rules/parking_rules.json'))
        as List<dynamic>;

typedef RuleKey = (String city, VehicleType vehicle);

class RulesController extends ChangeNotifier {
  RulesController(this.gateway, {this.bundled = bundledRules});
  final AdminGateway? gateway;
  final Future<List<dynamic>> Function() bundled;

  Map<RuleKey, Map<String, dynamic>> rows = {};
  Map<RuleKey, int> bundledVersions = {};
  bool loading = false;
  bool loaded = false;
  String? loadError;

  RuleKey? selected;

  /// The rule as published, and the admin's edit of it.
  RuleDraft? base;
  RuleDraft? draft;
  bool publishing = false;
  String? publishError;

  /// Tried to publish; the form shows its errors only after that.
  bool attempted = false;

  /// Someone else published the rule after it was opened here.
  bool stale = false;

  /// Bumped whenever the form is refilled, so its text fields reset.
  int formSeq = 0;

  /// The preview judges the rule on its effective date instead of today.
  bool previewEffective = false;
  String previewDistrict = otherDistrict;

  /// Street spaces whose district field the admin opened.
  Set<SpaceType> districtFields = {};

  int _generation = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Every city and vehicle, published or not.
  List<RuleSummary> get summaries => [
    for (final city in ruleCities)
      for (final vehicle in VehicleType.values)
        RuleSummary(
          city: city,
          vehicle: vehicle,
          version: rows[(city, vehicle)]?['version'] as int?,
          restriction: rows[(city, vehicle)]?['restriction'] as String?,
          bundledVersion: bundledVersions[(city, vehicle)],
        ),
  ];

  int get unsyncedCount => summaries.where((s) => s.unsynced).length;

  bool get dirty {
    final d = draft, b = base;
    if (d == null || b == null) return false;
    return !d.sameAs(b);
  }

  Map<String, String> get errors => draft?.errors() ?? const {};
  Map<String, String> get shownErrors => attempted ? errors : const {};

  /// Fields whose published value would change.
  bool changed(String key) {
    final d = draft, b = base;
    if (d == null || b == null || d.isNew) return false;
    final x = d.toValues()[key], y = b.toValues()[key];
    return jsonEncode(x) != jsonEncode(y);
  }

  /// Street spaces whose access or districts would change.
  bool changedType(SpaceType type) {
    final d = draft, b = base;
    if (d == null || b == null || d.isNew) return false;
    return d.access[type] != b.access[type] ||
        (d.access[type] != StreetAccess.closed &&
            !listEquals(
              d.typeDistricts[type] ?? const [],
              b.typeDistricts[type] ?? const [],
            ));
  }

  void reset() {
    _generation++;
    rows = {};
    loaded = false;
    loading = false;
    loadError = null;
    selected = null;
    base = draft = null;
    publishing = false;
    publishError = null;
    stale = false;
    _notify();
  }

  Future<void> load() async {
    // A reload mid-publish would drop the publish's result; wait for it.
    if (gateway == null || publishing) return;
    final generation = ++_generation;
    loading = true;
    loadError = null;
    _notify();
    try {
      final remote = await gateway!.cityRules();
      if (generation != _generation) return;
      rows = {
        for (final r in remote)
          if (VehicleType.values.asNameMap()[r['vehicle']] case final v?)
            (r['city'] as String, v): r,
      };
      loaded = true;
      if (selected case final key?) _fill(key);
      // The sync marks follow when the bundled file arrives; the rules never
      // wait for it.
      _loadBundled(generation);
    } catch (_) {
      if (generation == _generation) loadError = '規則載入失敗，請檢查網路後重新載入。';
    } finally {
      if (generation == _generation) loading = false;
      _notify();
    }
  }

  Future<void> _loadBundled(int generation) async {
    try {
      final local = await bundled();
      if (generation != _generation) return;
      bundledVersions = {
        for (final r in local.cast<Map<String, dynamic>>())
          if (VehicleType.values.asNameMap()[r['vehicle']] case final v?)
            (r['city'] as String, v): r['version'] as int,
      };
      _notify();
    } catch (_) {
      // Without the file no rule is marked; publishing still works.
    }
  }

  void _fill(RuleKey key) {
    selected = key;
    base = RuleDraft.fromRow(key.$1, key.$2, rows[key]);
    draft = base!.copy();
    previewDistrict = otherDistrict;
    previewEffective = false;
    districtFields = {};
    attempted = false;
    publishError = null;
    stale = false;
    formSeq++;
  }

  /// Opens one rule; a rule not published yet starts empty.
  void select(String city, VehicleType vehicle) {
    if (selected == (city, vehicle) && draft != null) return;
    _fill((city, vehicle));
    _notify();
  }

  void close() {
    selected = null;
    base = draft = null;
    _notify();
  }

  void discard() {
    if (selected case final key?) _fill(key);
    _notify();
  }

  /// Changes the draft; [edit] mutates it in place.
  void update(void Function(RuleDraft d) edit) {
    final d = draft;
    if (d == null) return;
    edit(d);
    _notify();
  }

  void openDistricts(SpaceType type) {
    districtFields = {...districtFields, type};
    _notify();
  }

  void setPreview({bool? effective, String? district}) {
    if (effective != null) previewEffective = effective;
    if (district != null) previewDistrict = district;
    _notify();
  }

  /// When the preview judges the rule.
  DateTime get previewDate {
    final date = parseDate(draft?.effectiveDate ?? '');
    final today = DateTime.now();
    final day = DateTime(today.year, today.month, today.day);
    return previewEffective && date != null && date.isAfter(day) ? date : day;
  }

  String _message(Object e) {
    final message = e is PostgrestException ? e.message : '';
    if (message.contains('changed since it was opened')) {
      stale = true;
      return '這條規則在你開啟後已由其他人發布新版本，尚未發布。請重新載入後再編輯。';
    }
    if (message.contains('need a restriction')) return '有條件開放的格位需要選限制類型。';
    if (message.contains('rule unchanged')) return '內容和目前版本相同，不需要發布。';
    return '發布失敗，內容仍保留在表單中。請檢查欄位後重試。';
  }

  /// Publishes the draft as the next version; the published row on success.
  Future<Map<String, dynamic>?> publish(String note) async {
    final d = draft, key = selected;
    if (gateway == null || d == null || key == null || publishing) return null;
    if (errors.isNotEmpty) {
      attempted = true;
      publishError = '請先修正標示的欄位。';
      _notify();
      return null;
    }
    return _write(key, d.toValues(), d.version, note);
  }

  /// Restores [previous]'s content as a new version over [published].
  Future<Map<String, dynamic>?> undo(RuleDraft previous, int published) async {
    final key = (previous.city, previous.vehicle);
    if (gateway == null || publishing) return null;
    if (previous.isNew) return null;
    return _write(
      key,
      previous.toValues(),
      published,
      '復原為第 ${previous.version} 版的內容',
    );
  }

  Future<Map<String, dynamic>?> _write(
    RuleKey key,
    Map<String, dynamic> values,
    int? baseVersion,
    String note,
  ) async {
    final generation = _generation;
    publishing = true;
    publishError = null;
    _notify();
    try {
      final row = await gateway!.publishCityRule(
        key.$1,
        key.$2.name,
        values,
        baseVersion,
        note,
      );
      if (generation != _generation) return null;
      rows = {...rows, key: row};
      if (selected == key) _fill(key);
      return row;
    } catch (e) {
      if (generation == _generation) publishError = _message(e);
      return null;
    } finally {
      if (generation == _generation) publishing = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

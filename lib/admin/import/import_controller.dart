import 'dart:convert';

import 'package:material_ui/material_ui.dart' show ChangeNotifier;
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../admin_gateway.dart';
import 'fee_reading.dart';
import 'import_models.dart';

/// The RPCs take at most this many spots a call.
const importChunk = 500;

String _today() => DateTime.now().toIso8601String().substring(0, 10);

String _failure(Object error) => error is PostgrestException
    ? error.code == '42501'
          ? '需要管理員權限與第二步驗證，請重新登入。'
          : '伺服器拒絕了這次操作：${error.message}'
    : '連線失敗，請確認網路後再試一次。';

/// `/imports`: a spots.json file, its preview, and what to import.
class ImportController extends ChangeNotifier {
  ImportController(this.gateway);
  final AdminGateway? gateway;

  String? fileName;

  /// The file's entries by id (first occurrence), with the fees read in.
  final Map<String, Map<String, dynamic>> _spots = {};
  List<ImportEntry> entries = const [];

  /// How many entries got a structured fee read from their fee note.
  int feesRead = 0;
  bool loading = false, applying = false;
  String? error;
  ImportResult? result;
  ImportStatus? filter;
  final Set<String> selected = {};

  /// Administrator fields to replace, per source id; the rest are kept.
  final Map<String, Set<String>> overwrite = {};
  String effectiveDate = _today();

  int count(ImportStatus status) =>
      entries.where((e) => e.status == status).length;

  List<ImportEntry> get visible => filter == null
      ? entries
      : entries.where((e) => e.status == filter).toList();

  /// New official spots need an effective date.
  bool get needsDate => entries.any(
    (e) =>
        e.official &&
        e.status == ImportStatus.added &&
        selected.contains(e.sourceId),
  );

  bool get validDate =>
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(effectiveDate) &&
      DateTime.tryParse(effectiveDate) != null;

  void reset() {
    fileName = null;
    _spots.clear();
    entries = const [];
    feesRead = 0;
    loading = applying = false;
    error = null;
    result = null;
    filter = null;
    selected.clear();
    overwrite.clear();
    effectiveDate = _today();
    notifyListeners();
  }

  /// Reads [text] as tool/import_mymaps.py's spots.json and previews it.
  Future<void> load(String name, String text) async {
    reset();
    fileName = name;
    Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      error = '「$name」不是 JSON 檔案。請選擇 import_mymaps.py 產生的 spots.json。';
      notifyListeners();
      return;
    }
    if (json is! List ||
        json.isEmpty ||
        json.any((s) => s is! Map<String, dynamic>)) {
      error = '「$name」不是停車點清單。請選擇 import_mymaps.py 產生的 spots.json。';
      notifyListeners();
      return;
    }
    var unnamed = 0;
    final file = json.cast<Map<String, dynamic>>().toList();
    for (final spot in file) {
      // Fees come from the one reader the fee page uses; only certain ones.
      if (spot['fee'] == null && spot['fee_note'] is String) {
        final reading = readFeeNote(
          spot['fee_note'] as String,
          spaceType: spot['space_type'] as String?,
        );
        if (reading.verdict == FeeVerdict.convertible) {
          spot['fee'] = reading.fee!.toJson();
          feesRead++;
        }
      }
      final id = spot['id'];
      _spots.putIfAbsent(id is String ? id : '#${unnamed++}', () => spot);
    }
    await _preview(file);
    // New and updated spots start chosen; conflicts too, keeping the
    // administrator's fields until one is chosen to overwrite.
    selected.addAll([
      for (final e in entries)
        if (e.status.applicable) e.sourceId,
    ]);
    notifyListeners();
  }

  List<Map<String, dynamic>>? _file;

  Future<void> _preview([List<Map<String, dynamic>>? file]) async {
    _file = file ?? _file;
    loading = true;
    notifyListeners();
    try {
      final all = <ImportEntry>[];
      for (var i = 0; i < _file!.length; i += importChunk) {
        all.addAll(
          await gateway!.previewImport(
            _file!.sublist(i, (i + importChunk).clamp(0, _file!.length)),
          ),
        );
      }
      entries = all;
      selected.removeWhere(
        (id) => !entries.any((e) => e.sourceId == id && e.status.applicable),
      );
    } catch (e) {
      error = _failure(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void setFilter(ImportStatus? status) {
    filter = status;
    notifyListeners();
  }

  void toggle(String sourceId, bool chosen) {
    chosen ? selected.add(sourceId) : selected.remove(sourceId);
    notifyListeners();
  }

  /// Chooses or clears every applicable entry the filter shows.
  void toggleVisible(bool chosen) {
    for (final e in visible.where((e) => e.status.applicable)) {
      chosen ? selected.add(e.sourceId) : selected.remove(e.sourceId);
    }
    notifyListeners();
  }

  void setOverwrite(String sourceId, String field, bool replace) {
    final fields = overwrite.putIfAbsent(sourceId, () => {});
    replace ? fields.add(field) : fields.remove(field);
    notifyListeners();
  }

  void setEffectiveDate(String value) {
    effectiveDate = value.trim();
    notifyListeners();
  }

  /// Imports the chosen entries, then previews the file again.
  Future<void> apply(String note) async {
    if (applying || selected.isEmpty || (needsDate && !validDate)) return;
    applying = true;
    error = null;
    result = null;
    notifyListeners();
    final chosen = [
      for (final e in entries)
        if (selected.contains(e.sourceId) && e.status.applicable) e,
    ];
    var total = const ImportResult();
    try {
      for (var i = 0; i < chosen.length; i += importChunk) {
        final part = chosen.sublist(
          i,
          (i + importChunk).clamp(0, chosen.length),
        );
        total += await gateway!.applyImport(
          [for (final e in part) _spots[e.sourceId]!],
          {
            for (final e in part)
              e.sourceId: {
                'base_updated_at': e.baseUpdatedAt,
                'overwrite': [...?overwrite[e.sourceId]],
              },
          },
          effectiveDate,
          note.trim(),
        );
      }
    } catch (e) {
      error = '${_failure(e)}已匯入的部分不受影響，重新試算後可繼續。';
    }
    result = total;
    applying = false;
    selected.clear();
    overwrite.clear();
    await _preview();
  }
}

/// `/imports/fees`: existing fee notes read into structured fees.
class FeeConversionController extends ChangeNotifier {
  FeeConversionController(this.gateway);
  final AdminGateway? gateway;

  List<FeeGroup> groups = const [];
  bool loaded = false, loading = false, converting = false;
  String? error;
  ImportResult? result;
  FeeVerdict verdict = FeeVerdict.convertible;

  /// Group keys chosen for writing.
  final Set<String> selected = {};

  List<FeeGroup> get visible =>
      groups.where((g) => g.reading.verdict == verdict).toList();

  int spots(FeeVerdict v) => groups
      .where((g) => g.reading.verdict == v)
      .fold(0, (n, g) => n + g.spots.length);

  /// Groups that can be written: certain ones and suggestions.
  bool writable(FeeGroup g) => g.reading.fee != null;

  int get selectedSpots => groups
      .where((g) => selected.contains(g.key))
      .fold(0, (n, g) => n + g.spots.length);

  void reset() {
    groups = const [];
    loaded = loading = converting = false;
    error = null;
    result = null;
    verdict = FeeVerdict.convertible;
    selected.clear();
    notifyListeners();
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      groups = groupFees(await gateway!.feeBacklog());
      loaded = true;
      // Certain readings start chosen; suggestions wait for a person.
      selected
        ..clear()
        ..addAll([
          for (final g in groups)
            if (g.reading.verdict == FeeVerdict.convertible) g.key,
        ]);
    } catch (e) {
      error = _failure(e);
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void show(FeeVerdict v) {
    verdict = v;
    notifyListeners();
  }

  void toggle(FeeGroup group, bool chosen) {
    if (!writable(group)) return;
    chosen ? selected.add(group.key) : selected.remove(group.key);
    notifyListeners();
  }

  void toggleVisible(bool chosen) {
    for (final g in visible.where(writable)) {
      chosen ? selected.add(g.key) : selected.remove(g.key);
    }
    notifyListeners();
  }

  /// Writes the chosen groups' fees, then reads the backlog again.
  Future<void> convert(String note) async {
    if (converting || selected.isEmpty) return;
    converting = true;
    error = null;
    result = null;
    notifyListeners();
    final items = [
      for (final g in groups)
        if (selected.contains(g.key))
          for (final s in g.spots)
            {
              'source_id': s.sourceId,
              'fee_note': s.feeNote,
              'fee': g.reading.fee!.toJson(),
            },
    ];
    var total = const ImportResult();
    try {
      for (var i = 0; i < items.length; i += importChunk) {
        total += await gateway!.convertFees(
          items.sublist(i, (i + importChunk).clamp(0, items.length)),
          note.trim(),
        );
      }
    } catch (e) {
      error = '${_failure(e)}已寫入的部分不受影響，重新讀取後可繼續。';
    }
    result = total;
    converting = false;
    await load();
  }
}

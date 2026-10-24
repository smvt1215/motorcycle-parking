import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin_gateway.dart';
import 'spot_models.dart';

class SpotsController extends ChangeNotifier {
  SpotsController(this.gateway);
  final AdminGateway? gateway;

  String query = '';
  SpotKind? kind;
  String? state;
  List<SpotSummary> results = [];
  bool searching = false;
  bool searched = false;
  String? searchError;

  SpotRecord? record;
  bool opening = false;
  String? openError;

  /// Editable values of [record] as the admin changes them.
  Map<String, dynamic> draft = {};
  bool saving = false;
  String? saveError;

  /// Someone else saved the spot after it was opened here.
  bool stale = false;

  int _generation = 0;
  int _searchSeq = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<SpotField> get fields => record == null
      ? const []
      : spotFields.where((f) => f.appliesTo(record!.kind)).toList();

  Map<String, dynamic> get changes =>
      record == null ? const {} : changedValues(draft, record!.values);
  bool get dirty => changes.isNotEmpty;
  bool changed(String key) => changes.containsKey(key);

  /// Errors of changed fields only, as the RPC checks only what it receives:
  /// an old imported row must not block an unrelated edit.
  Map<String, String> get errors => {
    for (final f in fields)
      if (changed(f.key)) f.key: ?validateSpotField(f, draft[f.key]),
  };

  Future<void> search() async {
    if (gateway == null) return;
    final generation = _generation;
    final seq = ++_searchSeq;
    searching = true;
    searchError = null;
    _notify();
    try {
      final rows = await gateway!.searchSpots(query, kind: kind, state: state);
      // A newer search (the admin kept typing) wins.
      if (generation != _generation || seq != _searchSeq) return;
      results = rows;
      searched = true;
    } catch (_) {
      if (generation == _generation && seq == _searchSeq) {
        searchError = '點位搜尋失敗，請檢查連線後重試。';
      }
    } finally {
      if (generation == _generation && seq == _searchSeq) searching = false;
      _notify();
    }
  }

  void setFilters({SpotKind? kind, String? state}) {
    this.kind = kind;
    this.state = state;
    search();
  }

  /// Loads [sourceId] into the form, dropping any unsaved draft.
  Future<void> open(String sourceId) async {
    if (gateway == null) return;
    final generation = _generation;
    opening = true;
    openError = null;
    saveError = null;
    stale = false;
    _notify();
    try {
      final loaded = await gateway!.spot(sourceId);
      if (generation != _generation) return;
      _load(loaded);
      if (loaded == null) openError = '找不到這個點位，可能已刪除或網址有誤。';
    } catch (_) {
      if (generation == _generation) openError = '點位載入失敗，請檢查連線後重試。';
    } finally {
      if (generation == _generation) opening = false;
      _notify();
    }
  }

  void _load(SpotRecord? loaded) {
    record = loaded;
    draft = {
      for (final f in fields)
        if (loaded != null) f.key: loaded.values[f.key],
    };
  }

  void close() {
    record = null;
    draft = {};
    saveError = null;
    openError = null;
    stale = false;
    _notify();
  }

  void set(String key, Object? value) {
    draft = {...draft, key: value};
    _notify();
  }

  void discard() {
    _load(record);
    saveError = null;
    _notify();
  }

  String _message(Object e, String fallback) {
    final message = e is PostgrestException ? e.message : '';
    if (message.contains('changed since it was opened')) {
      stale = true;
      return '這個點位在你開啟後已被其他人修改，尚未儲存。請重新載入後再編輯。';
    }
    return fallback;
  }

  /// Saves the changed fields; true when written.
  Future<bool> save(String note) async {
    final current = record;
    if (gateway == null || current == null || saving) return false;
    if (errors.isNotEmpty) {
      saveError = '請先修正標示的欄位。';
      _notify();
      return false;
    }
    final values = changes;
    if (values.isEmpty) return true;
    final generation = _generation;
    saving = true;
    saveError = null;
    _notify();
    try {
      final saved = await gateway!.updateSpot(
        current.sourceId,
        values,
        current.updatedAt,
        note,
      );
      if (generation != _generation) return false;
      _load(saved);
      _refreshRow(saved);
      return true;
    } catch (e) {
      if (generation == _generation) {
        saveError = _message(e, '儲存失敗，修改仍保留在表單中。請檢查後重試。');
      }
      return false;
    } finally {
      if (generation == _generation) saving = false;
      _notify();
    }
  }

  /// Hides or restores the open spot. Unsaved edits are kept in the form.
  Future<bool> setHidden(bool hide) async {
    final current = record;
    if (gateway == null || current == null || saving) return false;
    final generation = _generation;
    saving = true;
    saveError = null;
    _notify();
    try {
      await gateway!.setSpotHidden(current.sourceId, hide, '');
      final fresh = await gateway!.spot(current.sourceId);
      if (generation != _generation || fresh == null) return false;
      final edits = changes;
      _load(fresh);
      draft = {...draft, ...edits};
      _refreshRow(fresh);
      return true;
    } catch (e) {
      if (generation == _generation) {
        saveError = hide ? '隱藏失敗，請重試。' : '恢復顯示失敗，請重試。';
      }
      return false;
    } finally {
      if (generation == _generation) saving = false;
      _notify();
    }
  }

  /// Promotes the open community spot; returns the new official id.
  Future<String?> promote(Map<String, dynamic> values, String note) async {
    final current = record;
    if (gateway == null || current == null || current.official || saving) {
      return null;
    }
    final generation = _generation;
    saving = true;
    saveError = null;
    _notify();
    try {
      final id = await gateway!.promoteSpot(
        current.sourceId,
        values,
        current.updatedAt,
        note,
      );
      if (generation != _generation) return null;
      await search();
      return id;
    } catch (e) {
      if (generation == _generation) {
        saveError = _message(e, '改為官方點失敗，請檢查官方來源後重試。');
      }
      return null;
    } finally {
      if (generation == _generation) saving = false;
      _notify();
    }
  }

  void _refreshRow(SpotRecord saved) {
    final v = saved.values;
    results = [
      for (final r in results)
        if (r.sourceId == saved.sourceId)
          SpotSummary(
            sourceId: r.sourceId,
            kind: r.kind,
            name: v['name'] as String? ?? r.name,
            city: v['city'] as String? ?? r.city,
            district: v['district'] as String? ?? r.district,
            address: v['address'] as String? ?? r.address,
            spaceType: v['space_type'] as String? ?? r.spaceType,
            state: saved.official
                ? (saved.hidden ? 'hidden' : 'visible')
                : v['status'] as String? ?? r.state,
            updatedAt:
                DateTime.tryParse(v['updated_at'] as String? ?? '') ??
                r.updatedAt,
          )
        else
          r,
    ];
  }

  /// Drops everything private when access is lost or the admin signs out.
  void reset() {
    _generation++;
    results = [];
    searched = false;
    searching = false;
    searchError = null;
    record = null;
    draft = {};
    opening = false;
    openError = null;
    saving = false;
    saveError = null;
    stale = false;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

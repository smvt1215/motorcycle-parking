import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/town_lookup.dart';
import '../../domain/location_check.dart';
import '../../models/fee.dart';
import '../admin_gateway.dart';
import 'lot_models.dart';
import 'spot_models.dart';

class SpotsController extends ChangeNotifier {
  SpotsController(this.gateway, {this.onChanged});
  final AdminGateway? gateway;

  /// Called after a write here changed a spot, so other pages showing it
  /// (the review queue) read it again (決定 49).
  final VoidCallback? onChanged;

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

  /// A save was tried; a new spot shows its missing fields only after that.
  bool attempted = false;

  /// Someone else saved the spot after it was opened here.
  bool stale = false;

  /// What the position in the form is near and in; see [locate].
  List<NearbySpot> nearby = [];
  Town? town;
  bool locating = false;

  /// Bumped when [locate] fills the county and district, so their text
  /// fields show the new values.
  int filled = 0;
  String? locateError;
  int _locateSeq = 0;

  int _generation = 0;

  /// Bumped by every [open] and [startNew]; only the latest one may fill the
  /// form.
  int _openSeq = 0;
  int _searchSeq = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  List<SpotField> get fields => record == null
      ? const []
      : spotFields.where((f) => f.appliesTo(record!.kind)).toList();

  /// What [save] writes: changed fields of an existing spot, every filled
  /// field of a new one.
  Map<String, dynamic> get changes {
    var changed = _edits;
    // The draft holds a Fee while it is edited; the RPC takes its JSON.
    if (changed.containsKey('fee')) {
      changed['fee'] = (changed['fee'] as Fee?)?.toJson();
    }
    // A lot's fee is its plans': see lotChanges.
    if (lot && record?.isNew != true) {
      changed = lotChanges(changed, draft);
    } else if (lot) {
      changed = lotChanges(changed, draft)
        ..['fee_plans'] = jsonList(draft['fee_plans']).isEmpty
            ? null
            : draft['fee_plans'];
      changed.removeWhere((k, v) => v == null);
    }
    return changed;
  }

  /// Whether the form edits a lot: its rates live in plans its zones and
  /// its whole fee pick (design §2.6); a street spot keeps one fee.
  bool get lot => draft['space_type'] == 'offStreet';

  List<Json> get plans => jsonList(draft['fee_plans']);
  List<Json> get zones => jsonList(draft['parking_zones']);

  /// The spot's temporary closure (#116) as JSON, or none.
  void setClosure(Json? closure) => set('closure', closure);

  /// Adds a plan; returns its id.
  String addPlan(String name, Fee fee) {
    final id = nextPlanId(plans);
    draft = {
      ...draft,
      'fee_plans': [
        ...plans,
        {'id': id, 'name': name.trim(), 'fee': fee.toJson()},
      ],
    };
    _notify();
    return id;
  }

  /// Renames or re-prices plan [id]; every zone using it follows, and the
  /// whole fee when it uses it.
  void setPlan(String id, String name, Fee fee) {
    final next = [
      for (final p in plans)
        if (p['id'] == id)
          {...p, 'name': name.trim(), 'fee': fee.toJson()}
        else
          p,
    ];
    draft = {
      ...draft,
      'fee_plans': next,
      'parking_zones': zonesFollowingPlans(zones, next),
      if (draft['fee_plan'] == id) ...{'fee': fee, 'fee_note': feeNoteOf(fee)},
    };
    _notify();
  }

  /// Removes plan [id]; the form allows it only when nothing uses it.
  void deletePlan(String id) {
    if (planInUse(id, draft['fee_plan'], draft['parking_zones']) != null) {
      return;
    }
    draft = {
      ...draft,
      'fee_plans': [
        for (final p in plans)
          if (p['id'] != id) p,
      ],
    };
    _notify();
  }

  /// The plan the whole lot's fee uses, or none.
  void setTopPlan(String? id) {
    final plan = planById(plans, id);
    final fee = plan == null ? null : Fee.fromJson(plan['fee']);
    draft = {
      ...draft,
      'fee_plan': plan == null ? null : id,
      'fee': fee,
      'fee_note': fee == null
          ? (storedFee(record?.values['fee']) == null
                ? record?.values['fee_note'] ?? feeNoteOf(null)
                : feeNoteOf(null))
          : feeNoteOf(fee),
    };
    _notify();
  }

  void setZone(int index, Json zone) {
    final next = [...zones];
    if (index < 0 || index >= next.length) return;
    next[index] = zone;
    draft = {...draft, 'parking_zones': next};
    _notify();
  }

  /// Adds a zone; [like] gives it another zone's name and area (a second
  /// bay in that area).
  void addZone({Json? like}) {
    draft = {
      ...draft,
      'parking_zones': [
        ...zones,
        like == null
            ? {'name': '新區域'}
            // A second bay in the area rests on the area's notice too.
            : {
                'name': like['name'],
                'area': ?like['area'],
                if (rawBasis(like) case final basis?)
                  'condition': {'basis': basis},
              },
      ],
    };
    _notify();
  }

  void removeZone(int index) {
    final next = [...zones];
    if (index < 0 || index >= next.length) return;
    next.removeAt(index);
    draft = {...draft, 'parking_zones': next};
    _notify();
  }

  /// Renames an area card, changes its area or its basis: every zone in it.
  void setCard(
    AreaCard card, {
    String? name,
    Object? area = _keep,
    Object? basis = _keep,
  }) {
    final next = [...zones];
    for (final i in card.indexes) {
      var z = {...next[i]};
      if (name != null) z['name'] = name;
      if (area != _keep) {
        if (area == null) {
          z.remove('area');
        } else {
          z['area'] = area;
        }
      }
      if (basis != _keep) z = zoneWithBasis(z, basis as Json?);
      next[i] = z;
    }
    draft = {...draft, 'parking_zones': next};
    _notify();
  }

  static const _keep = Object();

  /// [changes] as the draft holds them, a fee still a [Fee].
  Map<String, dynamic> get _edits {
    final r = record;
    if (r == null) return {};
    return r.isNew
        ? {
            for (final e in draft.entries)
              if (e.value != null && e.value != '') e.key: e.value,
          }
        : changedValues(draft, {
            ...r.values,
            'fee': storedFee(r.values['fee']),
            // As [_load] reads them, so an untouched lot is not dirty.
            'parking_zones': r.values['parking_zones'] ?? const <Object?>[],
            'zones_complete': r.values['zones_complete'] == true,
          });
  }

  /// Whether the form's fee is structured; its text then follows it.
  bool get feeStructured => draft['fee'] != null;

  /// Sets the fee and keeps `fee_note` its text, as the app's reports do
  /// (lib/models/fee.dart `feeNoteOf`). With no vehicle known the spot has
  /// no structured fee and the text is free again: the stored text when the
  /// spot had no fee, else the default note. Incomplete or invalid amounts
  /// leave the text alone until they are fixed.
  void setFee(Fee value) {
    final r = record;
    if (r == null) return;
    final fee = value.isEmpty ? null : value;
    final hadFee = !r.isNew && storedFee(r.values['fee']) != null;
    // Complete and in range; an unreadable amount keeps the old text.
    final complete = fee?.valid ?? true;
    draft = {
      ...draft,
      'fee': fee,
      'fee_note': fee == null
          ? (hadFee ? feeNoteOf(null) : r.values['fee_note'])
          : complete
          ? feeNoteOf(fee)
          : draft['fee_note'],
    };
    _notify();
  }

  bool get dirty => record?.isNew == true || changes.isNotEmpty;

  /// Marked as changed in the form; a new spot has nothing to compare to.
  bool changed(String key) => record?.isNew != true && _edits.containsKey(key);

  /// Errors of changed fields only, as the RPC checks only what it receives:
  /// an old imported row must not block an unrelated edit. A new spot has
  /// nothing to keep, so every field is checked.
  Map<String, String> get errors => {
    for (final f in fields)
      if (record!.isNew || changed(f.key))
        f.key: ?validateSpotField(
          f,
          draft[f.key],
          fee: draft['fee'] is Fee ? draft['fee'] as Fee : null,
        ),
    if (lot && (record!.isNew || _edits.containsKey('fee_plans')))
      'fee_plans': ?plansProblem(plans),
    if (lot && (record!.isNew || _edits.containsKey('parking_zones')))
      'parking_zones': ?zones.map(zoneProblem).nonNulls.firstOrNull,
  };

  /// Errors the form shows: a fresh new spot is not scolded before a save.
  Map<String, String> get shownErrors =>
      record?.isNew == true && !attempted ? const {} : errors;

  /// The one section of the form that is open (decision 57); null when all
  /// are folded. A new spot starts at its position, an existing one at its
  /// name.
  SpotGroup? openGroup;

  void toggleGroup(SpotGroup group) {
    openGroup = openGroup == group ? null : group;
    _notify();
  }

  /// The section an error belongs to: the plans and areas are the lot's
  /// rates.
  static SpotGroup? groupOf(String key) => switch (key) {
    'fee_plans' || 'parking_zones' => SpotGroup.fees,
    _ => spotFields.where((f) => f.key == key).firstOrNull?.group,
  };

  /// Sections holding an error the form shows.
  Set<SpotGroup> get groupsWithErrors => {
    for (final key in shownErrors.keys) ?groupOf(key),
  };

  /// Distance, duplicates and county change of the position in the form.
  LocationNotes get notes {
    final r = record;
    final lat = draft['lat'], lng = draft['lng'];
    if (r == null || lat is! num || lng is! num) return const LocationNotes();
    final origin = r.isNew ? null : r.values;
    return checkLocation(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      originLat: (origin?['lat'] as num?)?.toDouble(),
      originLng: (origin?['lng'] as num?)?.toDouble(),
      spaceType: draft['space_type'] as String?,
      selfId: r.sourceId,
      nearby: nearby,
      originCity: origin?['city'] as String?,
      newCity: draft['city'] as String?,
    );
  }

  /// Starts a new spot of [kind] at a position; nothing is written until
  /// [save].
  void startNew(SpotKind kind, double lat, double lng) {
    // Supersedes a spot still loading; searches and access are unaffected.
    _openSeq++;
    opening = false;
    openError = null;
    saveError = null;
    stale = false;
    _load(
      SpotRecord.create(kind, {
        'lat': lat,
        'lng': lng,
        'fee_note': '請依現場公告',
        if (kind == SpotKind.community) 'status': 'pending',
      }),
    );
    draft = {...draft, ...record!.values};
    _notify();
    locate();
  }

  /// Looks up the county, district and nearby spots of the form's position.
  /// The county and district follow the position, as the rules do.
  Future<void> locate() async {
    final lat = draft['lat'], lng = draft['lng'];
    if (gateway == null || lat is! num || lng is! num) return;
    final generation = _generation;
    final seq = ++_locateSeq;
    final target = record;
    final at = (lat.toDouble(), lng.toDouble());
    // A response applies only to the record and position it was asked for:
    // the form may have moved on, or the spot moved again, meanwhile.
    bool current() =>
        generation == _generation &&
        seq == _locateSeq &&
        identical(record, target) &&
        draft['lat'] == lat &&
        draft['lng'] == lng;
    locating = true;
    locateError = null;
    _notify();
    try {
      final found = await gateway!.town(at.$1, at.$2);
      final near = await gateway!.nearbySpots(at.$1, at.$2);
      if (!current()) return;
      town = found;
      nearby = near;
      if (found == null) {
        locateError = '這個位置查不到縣市，可能在海上或台灣以外，請確認位置。';
      } else {
        draft = {...draft, 'city': found.city, 'district': found.district};
        filled++;
        _locatedFor = (at.$1, at.$2, found.city, found.district);
      }
    } catch (_) {
      if (current()) locateError = '縣市與行政區查詢失敗，請手動確認或稍後重試。';
    } finally {
      if (seq == _locateSeq) locating = false;
      _notify();
    }
  }

  /// The form's position has a county and district looked up for it: the
  /// stored one of an existing spot, or the last successful [locate] (or
  /// [confirmManualTown]). Editing the county or district afterwards undoes
  /// it, as moving the spot does.
  bool get positionResolved {
    final lat = draft['lat'], lng = draft['lng'];
    if (lat is! num || lng is! num) return false;
    final at = (lat.toDouble(), lng.toDouble());
    final r = record;
    // Back at the stored position, the stored county and district hold only
    // if the form still has them; a lookup for elsewhere may have changed them.
    if (r != null &&
        !r.isNew &&
        r.values['lat'] == lat &&
        r.values['lng'] == lng &&
        draft['city'] == r.values['city'] &&
        draft['district'] == r.values['district']) {
      return true;
    }
    return _locatedFor == (at.$1, at.$2, draft['city'], draft['district']);
  }

  /// Position, county and district of the last lookup or confirmation.
  (double, double, Object?, Object?)? _locatedFor;

  /// When the lookup service is down or finds nothing, the admin confirms
  /// the county and district typed in the form for the current position.
  /// Moving the spot again needs a new lookup or confirmation.
  bool confirmManualTown() {
    final lat = draft['lat'], lng = draft['lng'];
    final city = draft['city'];
    if (lat is! num || lng is! num || city is! String || city.trim().isEmpty) {
      return false;
    }
    _locatedFor = (lat.toDouble(), lng.toDouble(), city, draft['district']);
    locateError = null;
    saveError = null;
    _notify();
    return true;
  }

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
    final seq = ++_openSeq;
    bool current() => generation == _generation && seq == _openSeq;
    opening = true;
    openError = null;
    saveError = null;
    stale = false;
    _notify();
    try {
      final loaded = await gateway!.spot(sourceId);
      if (!current()) return;
      _load(loaded);
      if (loaded == null) openError = '找不到這個點位，可能已刪除或網址有誤。';
    } catch (_) {
      if (current()) openError = '點位載入失敗，請檢查連線後重試。';
    } finally {
      if (current()) opening = false;
      _notify();
    }
  }

  /// Bumped for every form shown, including each new spot: fields keyed by
  /// it start over instead of keeping the last form's text.
  int formSeq = 0;

  void _load(SpotRecord? loaded) {
    // Saving or reloading the same spot keeps the section in view.
    final same =
        loaded != null && !loaded.isNew && loaded.sourceId == record?.sourceId;
    record = loaded;
    formSeq++;
    attempted = false;
    openGroup = loaded == null
        ? null
        : same
        ? openGroup
        : loaded.isNew
        ? SpotGroup.location
        : SpotGroup.basic;
    // Lookups still running belong to the previous form.
    _locateSeq++;
    locating = false;
    _locatedFor = null;
    nearby = [];
    town = null;
    locateError = null;
    draft = {
      for (final f in fields)
        if (loaded != null)
          f.key: f.input == SpotInput.fee
              ? storedFee(loaded.values[f.key])
              : loaded.values[f.key],
      if (loaded != null) ...{
        'fee_plans': copyJson(loaded.values['fee_plans']),
        'fee_plan': loaded.values['fee_plan'],
        'parking_zones': copyJson(loaded.values['parking_zones'] ?? const []),
        'zones_complete': loaded.values['zones_complete'] == true,
        'closure': copyJson(loaded.values['closure']),
      },
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

  /// An address search result fills the address or road field; like a
  /// lookup, the field's text box shows the new value.
  void fillFromSearch(String key, String value) {
    draft = {...draft, key: value};
    filled++;
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
    // 202610270080: a plan the spot or a zone still uses cannot go.
    if (message.contains('fee plan in use')) {
      final which = planInUseRefusal((e as PostgrestException).details);
      return '計費規則仍在使用，尚未儲存：${which ?? '有分區在用，先改掉引用'}。';
    }
    if (message.contains('invalid closure')) {
      return '暫時無法停車的資料不正確，尚未儲存。請確認預計恢復日期不早於開始日期。';
    }
    if (message.contains('invalid parking_zones')) {
      return '區域與格位的資料不正確，尚未儲存。請檢查每個格位的可停車種。';
    }
    return fallback;
  }

  /// Saves the changed fields; true when written.
  Future<bool> save(String note) async {
    final current = record;
    if (gateway == null || current == null || saving) return false;
    if (errors.isNotEmpty) {
      attempted = true;
      saveError = '請先修正標示的欄位。';
      // Open the first section that needs fixing, so its field is seen.
      final bad = {for (final key in errors.keys) ?groupOf(key)};
      if (!bad.contains(openGroup)) {
        openGroup =
            SpotGroup.values.where(bad.contains).firstOrNull ?? openGroup;
      }
      _notify();
      return false;
    }
    final generation = _generation;
    // Locked before the first wait: a second click must not start a second
    // save (a new spot would be created twice).
    saving = true;
    saveError = null;
    _notify();
    try {
      // A moved spot is saved with the county and district of where it is
      // now, so the right rules apply; finish that lookup first.
      if (!positionResolved) {
        await locate();
        if (!identical(record, current)) return false;
        if (!positionResolved) {
          saveError =
              '新位置的縣市與行政區尚未查到，無法儲存。請重試查詢，或確認表單中的縣市與行政區後按「使用手動填寫的縣市與行政區」。';
          return false;
        }
      }
      final values = changes;
      if (values.isEmpty) return true;
      final saved = current.isNew
          ? await gateway!.createSpot(current.newKind!, values, note)
          : await gateway!.updateSpot(
              current.sourceId,
              values,
              current.updatedAt,
              note,
            );
      if (generation != _generation) return false;
      _load(saved);
      _refreshRow(saved);
      // A new spot is not in the list yet; search again to show it.
      if (current.isNew && searched) unawaited(search());
      onChanged?.call();
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

  /// Records that an admin checked the open community spot's stored vehicle
  /// access: the RPC restates the values unchanged, and the database marks
  /// each restated vehicle verified. Unsaved edits must be saved first.
  Future<bool> verifyVehicles() async {
    final current = record;
    if (gateway == null ||
        current == null ||
        current.isNew ||
        current.official ||
        saving ||
        dirty) {
      return false;
    }
    final flags = current.verifiableFlags;
    if (flags.isEmpty) return false;
    final generation = _generation;
    saving = true;
    saveError = null;
    _notify();
    try {
      final saved = await gateway!.updateSpot(
        current.sourceId,
        flags,
        current.updatedAt,
        '核驗目前車種',
      );
      if (generation != _generation) return false;
      _load(saved);
      _refreshRow(saved);
      onChanged?.call();
      return true;
    } catch (e) {
      if (generation == _generation) {
        saveError = _message(e, '核驗失敗，請重試。');
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
      final edits = _edits;
      _load(fresh);
      draft = {...draft, ...edits};
      _refreshRow(fresh);
      onChanged?.call();
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
      onChanged?.call();
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

  /// Another page wrote [changed] spots (a review decision, an import): the
  /// list reads again, and so does the open spot when it is one of them. A
  /// form with unsaved edits is kept as it is.
  Future<void> refresh(Set<String> changed) async {
    final open = record;
    await Future.wait([
      if (searched) search(),
      if (open != null &&
          !open.isNew &&
          !dirty &&
          !saving &&
          changed.contains(open.sourceId))
        _reload(open.sourceId),
    ]);
  }

  /// Reads the open spot again in the background. The form stays usable
  /// meanwhile, so the answer is dropped if the admin started editing,
  /// saving or opened another form while it was on its way.
  Future<void> _reload(String sourceId) async {
    final generation = _generation;
    final seq = _openSeq;
    final shown = formSeq;
    try {
      final fresh = await gateway!.spot(sourceId);
      if (fresh == null ||
          generation != _generation ||
          seq != _openSeq ||
          shown != formSeq ||
          record?.sourceId != sourceId ||
          dirty ||
          saving) {
        return;
      }
      _load(fresh);
      _notify();
    } catch (_) {
      // The form keeps what it shows; the next open reads it again.
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

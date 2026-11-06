import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' as api_v1;

/// One hidden rider (#280, P17a, P17c). Matching uses only
/// [handle], the backend's public contributor handle; the rest is what the
/// rider saw when hiding, so the list can say who it was after a rename.
@immutable
class HiddenRider {
  const HiddenRider({
    required this.handle,
    required this.name,
    required this.spotName,
    required this.hiddenAt,
  });

  /// The public handle (`contributor_handle`); never an account id.
  final String handle;

  /// The public name shown when hidden; empty when there was none.
  final String name;

  /// The spot the rider was hidden from.
  final String spotName;
  final DateTime hiddenAt;

  Map<String, dynamic> toJson() => {
    'handle': handle,
    'name': name,
    'spot_name': spotName,
    'hidden_at': hiddenAt.toIso8601String(),
  };

  /// A row of `api_v1.hidden_riders_list()`, or null when unreadable.
  static HiddenRider? fromApi(Object? row) => row is Map<String, dynamic>
      ? fromJson({
          'handle': row['handle'],
          'name': row['name_at_hide'],
          'spot_name': row['spot_name_at_hide'],
          'hidden_at': row['hidden_at'],
        })
      : null;

  /// As `api_v1.hidden_riders_merge` takes it.
  Map<String, dynamic> toApi() => {
    'handle': handle,
    'name_at_hide': name,
    'spot_name_at_hide': spotName,
    'hidden_at': hiddenAt.toUtc().toIso8601String(),
  };

  /// A stored row, or null when it is unreadable (a newer or damaged copy
  /// must not drop the whole list).
  static HiddenRider? fromJson(Object? row) {
    if (row is! Map<String, dynamic>) return null;
    final handle = row['handle'];
    if (handle is! String || handle.isEmpty) return null;
    final at = row['hidden_at'];
    return HiddenRider(
      handle: handle,
      name: row['name'] is String ? row['name'] as String : '',
      spotName: row['spot_name'] is String ? row['spot_name'] as String : '',
      hiddenAt:
          (at is String ? DateTime.tryParse(at) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HiddenRider &&
      other.handle == handle &&
      other.name == name &&
      other.spotName == spotName &&
      other.hiddenAt == hiddenAt;

  @override
  int get hashCode => Object.hash(handle, name, spotName, hiddenAt);
}

/// The most riders one list holds, on the device and in the account.
const hiddenRidersLimit = 500;

/// The longest name and spot name the account list takes; longer ones
/// are cut when stored, so a merge is never refused for them.
const hiddenRiderNameMax = 40, hiddenRiderSpotNameMax = 100;

/// [text] trimmed and cut to [max] characters (code points, as the
/// database counts them).
String _cut(String text, int max) {
  final t = text.trim();
  return t.runes.length <= max ? t : String.fromCharCodes(t.runes.take(max));
}

/// Thrown when hiding would pass [hiddenRidersLimit].
class HiddenRidersFull extends StateError {
  HiddenRidersFull() : super('hidden riders limit');
}

/// Newest first (P17c: 最近隱藏的在上面).
List<HiddenRider> _sorted(Iterable<HiddenRider> riders) =>
    [...riders]..sort((a, b) => b.hiddenAt.compareTo(a.hiddenAt));

/// [a] and [b] together; one handle keeps its earliest hidden date.
List<HiddenRider> unionRiders(
  Iterable<HiddenRider> a,
  Iterable<HiddenRider> b,
) {
  final byHandle = <String, HiddenRider>{};
  for (final r in [...a, ...b]) {
    final kept = byHandle[r.handle];
    if (kept == null || r.hiddenAt.isBefore(kept.hiddenAt)) {
      byHandle[r.handle] = r;
    }
  }
  return _sorted(byHandle.values);
}

/// Where a hidden list lives: this device or the account.
abstract interface class HiddenRidersStore {
  Future<List<HiddenRider>> list();

  /// Adds [items] (a union; one handle keeps its earliest date) and
  /// returns the whole list.
  Future<List<HiddenRider>> merge(List<HiddenRider> items);
  Future<void> remove(String handle);
}

/// The device's copy in [SharedPreferences].
class LocalHiddenRidersStore implements HiddenRidersStore {
  LocalHiddenRidersStore(this.prefs);
  static const storageKey = 'hiddenRiders';
  final SharedPreferences prefs;

  /// Read at once, for the first frame.
  List<HiddenRider> read() {
    try {
      final raw = prefs.getString(storageKey);
      if (raw == null) return [];
      return _sorted([
        for (final row in jsonDecode(raw) as List<dynamic>)
          ?HiddenRider.fromJson(row),
      ]);
    } catch (_) {
      return [];
    }
  }

  Future<void> write(List<HiddenRider> riders) => prefs.setString(
    storageKey,
    jsonEncode([for (final r in riders) r.toJson()]),
  );

  Future<void> clear() => prefs.remove(storageKey);

  @override
  Future<List<HiddenRider>> list() async => read();

  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async {
    final all = unionRiders(read(), items);
    await write(all);
    return all;
  }

  @override
  Future<void> remove(String handle) => write([
    for (final r in read())
      if (r.handle != handle) r,
  ]);
}

/// The account's list through `api_v1` (#280 L2): only these three RPCs
/// reach it.
class RemoteHiddenRidersStore implements HiddenRidersStore {
  RemoteHiddenRidersStore(SupabaseClient client)
    : api = api_v1.ApiV1Client(client);
  final api_v1.ApiV1Client api;

  /// [call], with `hidden_riders.too_many` as [HiddenRidersFull].
  static Future<api_v1.HiddenRiders> _guard(
    Future<api_v1.HiddenRiders> Function() call,
  ) async {
    try {
      return await call();
    } on api_v1.ApiV1Exception catch (e) {
      if (e.message == 'hidden_riders.too_many') throw HiddenRidersFull();
      rethrow;
    }
  }

  static List<HiddenRider> _items(api_v1.HiddenRiders body) => _sorted([
    for (final r in body.items)
      ?HiddenRider.fromJson({
        'handle': r.handle,
        'name': r.nameAtHide,
        'spot_name': r.spotNameAtHide,
        'hidden_at': r.hiddenAt,
      }),
  ]);

  @override
  Future<List<HiddenRider>> list() async =>
      _items(await _guard(api.hiddenRidersList));

  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async => _items(
    await _guard(
      () => api.hiddenRidersMerge(
        items: [
          for (final r in items)
            api_v1.HiddenRider(
              handle: r.handle,
              nameAtHide: r.name,
              spotNameAtHide: r.spotName,
              hiddenAt: r.hiddenAt.toUtc().toIso8601String(),
            ),
        ],
      ),
    ),
  );

  @override
  Future<void> remove(String handle) async {
    await _guard(() => api.hiddenRidersRemove(handle: handle));
  }
}

/// The hidden riders (#280). Signed out, the list lives on this device;
/// signed in, it follows the account ([remote]) with this device keeping a
/// copy, so the map never waits on the network. Changes made while the
/// account cannot be reached are kept and sent on the next [sync].
class HiddenRiders extends ChangeNotifier {
  HiddenRiders(this.prefs, {DateTime Function()? clock, this.remote})
    : clock = clock ?? DateTime.now,
      local = LocalHiddenRidersStore(prefs) {
    _riders = local.read();
    _pendingAdds = {...?prefs.getStringList(_pendingAddsKey)};
    _pendingRemoves = {...?prefs.getStringList(_pendingRemovesKey)};
  }

  static const storageKey = LocalHiddenRidersStore.storageKey;
  static const _pendingAddsKey = 'hiddenRidersPendingAdds';
  static const _pendingRemovesKey = 'hiddenRidersPendingRemoves';

  /// The account the device's copy belongs to; absent for a guest list.
  static const ownerKey = 'hiddenRidersAccount';
  final SharedPreferences prefs;
  final DateTime Function() clock;
  final LocalHiddenRidersStore local;

  /// The account's list; null keeps everything on this device.
  final HiddenRidersStore? remote;
  late List<HiddenRider> _riders;

  /// The signed-in account whose list this follows; null signed out.
  String? _account;
  bool get followsAccount => _account != null && remote != null;

  /// Bumped on every sign-in and sign-out: an answer for an older one is
  /// dropped, so one account's list never lands in another's.
  int _generation = 0;

  /// Handles added or removed here that the account has not taken yet;
  /// kept across launches.
  late Set<String> _pendingAdds, _pendingRemoves;
  Future<void>? _syncing;

  /// A change arrived while a sync ran: it runs another round.
  bool _dirty = false;

  /// The account refused the last merge: it would pass
  /// [hiddenRidersLimit] (`hidden_riders.too_many`). The device list is
  /// kept and sent again on the next [sync].
  bool get accountFull => _accountFull;
  bool _accountFull = false;

  bool _disposed = false;

  /// Sign-in and sync finish on their own time, possibly after the store
  /// that owns this list is gone.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _save() async {
    _notify();
    await local.write(_riders);
  }

  Future<void> _savePending() async {
    await prefs.setStringList(_pendingAddsKey, [..._pendingAdds]);
    await prefs.setStringList(_pendingRemovesKey, [..._pendingRemoves]);
  }

  /// Every hidden rider, newest first.
  List<HiddenRider> get riders => List.unmodifiable(_riders);
  bool get isEmpty => _riders.isEmpty;
  int get length => _riders.length;

  /// Whether [handle] is hidden; a missing handle never is.
  bool isHidden(String? handle) =>
      handle != null &&
      handle.isNotEmpty &&
      _riders.any((r) => r.handle == handle);

  HiddenRider? byHandle(String? handle) => handle == null
      ? null
      : _riders.where((r) => r.handle == handle).firstOrNull;

  /// Hides [handle], remembering [name] and [spotName] as seen now. Hiding
  /// again keeps the first row. Throws [HiddenRidersFull] past
  /// [hiddenRidersLimit].
  Future<HiddenRider> hide({
    required String handle,
    required String name,
    required String spotName,
  }) async {
    if (byHandle(handle) case final existing?) return existing;
    if (_riders.length >= hiddenRidersLimit) throw HiddenRidersFull();
    final rider = HiddenRider(
      handle: handle,
      name: _cut(name, hiddenRiderNameMax),
      spotName: _cut(spotName, hiddenRiderSpotNameMax),
      hiddenAt: clock(),
    );
    await _add(rider);
    return rider;
  }

  /// Puts [rider] back as it was (復原 after 解除隱藏).
  Future<void> restore(HiddenRider rider) async {
    if (isHidden(rider.handle)) return;
    await _add(rider);
  }

  Future<void> _add(HiddenRider rider) async {
    _riders = _sorted([..._riders, rider]);
    await _save();
    if (!followsAccount) return;
    _pendingRemoves.remove(rider.handle);
    _pendingAdds.add(rider.handle);
    await _savePending();
    unawaited(sync());
  }

  /// Unhides [handle]; returns the removed row for 復原, or null.
  Future<HiddenRider?> unhide(String handle) async {
    final removed = byHandle(handle);
    if (removed == null) return null;
    await _drop({handle});
    return removed;
  }

  Future<void> _drop(Set<String> handles) async {
    _riders = [
      for (final r in _riders)
        if (!handles.contains(r.handle)) r,
    ];
    await _save();
    if (!followsAccount) return;
    _pendingAdds.removeAll(handles);
    _pendingRemoves.addAll(handles);
    await _savePending();
    unawaited(sync());
  }

  /// Drops the signed-in rider's own handles: a guest may have hidden
  /// themself before signing in (P17a: 自己的點).
  Future<void> forget(Iterable<String> handles) async {
    final own = {...handles};
    if (!_riders.any((r) => own.contains(r.handle))) return;
    await _drop({
      for (final r in _riders)
        if (own.contains(r.handle)) r.handle,
    });
  }

  /// Signed in as [account]. A guest list joins the account's once (a
  /// union, each handle keeping its earliest date); the device's copy of
  /// this same account (a relaunch) only sends what is still pending,
  /// then takes the account's list, so riders unhidden on another device
  /// stay unhidden. A copy left by another account is dropped.
  Future<void> signedIn(String account) async {
    if (remote == null || _account == account) return;
    _generation++;
    _syncing = null;
    _account = account;
    final owner = prefs.getString(ownerKey);
    if (owner == null) {
      // A guest list goes up once.
      _pendingAdds.addAll(_riders.map((r) => r.handle));
    } else if (owner != account) {
      _riders = [];
      _pendingAdds.clear();
      _pendingRemoves.clear();
      await _save();
    }
    await prefs.setString(ownerKey, account);
    await _savePending();
    await sync();
  }

  /// Signed out: the device's copy is cleared so the next person on a
  /// shared device neither sees nor keeps it; the account still has it.
  /// A sync still running for the account is dropped.
  Future<void> signedOut() async {
    if (remote == null) return;
    if (_account == null && prefs.getString(ownerKey) == null) return;
    _generation++;
    _syncing = null;
    _account = null;
    _accountFull = false;
    _pendingAdds.clear();
    _pendingRemoves.clear();
    _riders = [];
    _notify();
    await prefs.remove(ownerKey);
    await _savePending();
    await local.clear();
  }

  /// Sends what the account has not taken yet, then reads its list; runs
  /// again while changes keep arriving. Never throws; one run at a time
  /// per sign-in.
  Future<void> sync() {
    if (_syncing case final running?) {
      _dirty = true;
      return running;
    }
    late final Future<void> run;
    run = _syncAll(_generation).whenComplete(() {
      if (identical(_syncing, run)) _syncing = null;
    });
    return _syncing = run;
  }

  Future<void> _syncAll(int generation) async {
    do {
      _dirty = false;
      if (!await _sync(generation)) return;
    } while (_dirty && generation == _generation);
  }

  /// One round; false when it failed or the account changed.
  Future<bool> _sync(int generation) async {
    final store = remote;
    bool current() => generation == _generation && _account != null;
    if (store == null || !current()) return false;
    try {
      for (final handle in [..._pendingRemoves]) {
        await store.remove(handle);
        if (!current()) return false;
        _pendingRemoves.remove(handle);
      }
      final adds = [
        for (final r in _riders)
          if (_pendingAdds.contains(r.handle)) r,
      ];
      final all = adds.isEmpty ? await store.list() : await store.merge(adds);
      if (!current()) return false;
      // The account has these now, whatever happened here meanwhile: a
      // later removal is pending on its own.
      _pendingAdds.removeAll(adds.map((r) => r.handle));
      // Changes made while this ran stay on top of the account's answer.
      _riders = _sorted([
        for (final r in unionRiders(all, [
          for (final r in _riders)
            if (_pendingAdds.contains(r.handle)) r,
        ]))
          if (!_pendingRemoves.contains(r.handle)) r,
      ]);
      _accountFull = false;
      await _save();
      await _savePending();
      return true;
    } on HiddenRidersFull {
      if (!current()) return false;
      _accountFull = true;
      _notify();
      await _savePending();
      return false;
    } catch (_) {
      // Offline: keep the device list and what is pending.
      if (current()) await _savePending();
      return false;
    }
  }
}

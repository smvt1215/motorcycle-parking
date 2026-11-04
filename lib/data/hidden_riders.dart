import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show ApiV1Exception;

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
  RemoteHiddenRidersStore(this.client);
  final SupabaseClient client;

  // TODO(#280): use the generated ApiV1Client methods once
  // hidden_riders_* are in supabase/api/v1/api_v1.json (backend #315).
  Future<Object?> _call(String name, [Map<String, dynamic>? params]) async {
    try {
      return await client.schema('api_v1').rpc<Object?>(name, params: params);
    } on PostgrestException catch (e) {
      // The API's stable code is the message (#195 §2.4).
      if (e.message == 'hidden_riders.too_many') throw HiddenRidersFull();
      throw ApiV1Exception(
        code: e.code,
        message: e.message,
        details: e.details,
      );
    }
  }

  /// `{items: [...], limit: 500}`, as all three RPCs answer.
  static List<HiddenRider> _items(Object? body) => _sorted([
    if (body case {'items': final List<dynamic> rows})
      for (final row in rows) ?HiddenRider.fromApi(row),
  ]);

  @override
  Future<List<HiddenRider>> list() async =>
      _items(await _call('hidden_riders_list'));

  @override
  Future<List<HiddenRider>> merge(List<HiddenRider> items) async => _items(
    await _call('hidden_riders_merge', {
      'items': [for (final r in items) r.toApi()],
    }),
  );

  @override
  Future<void> remove(String handle) async {
    await _call('hidden_riders_remove', {'handle': handle});
  }
}

/// Whether the account list is used; off until the #280 L2 RPCs ship.
const hiddenRidersSyncEnabled = bool.fromEnvironment('HIDDEN_RIDERS_SYNC');

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
  final SharedPreferences prefs;
  final DateTime Function() clock;
  final LocalHiddenRidersStore local;

  /// The account's list; null keeps everything on this device.
  final HiddenRidersStore? remote;
  late List<HiddenRider> _riders;

  /// Signed in to an account whose list this follows.
  bool _account = false;
  bool get followsAccount => _account && remote != null;

  /// Handles added or removed here that the account has not taken yet.
  late Set<String> _pendingAdds, _pendingRemoves;
  Future<void>? _syncing;

  /// The account refused the last merge: it would pass
  /// [hiddenRidersLimit] (`hidden_riders.too_many`). The device list is
  /// kept and sent again on the next [sync].
  bool get accountFull => _accountFull;
  bool _accountFull = false;

  Future<void> _save() async {
    notifyListeners();
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

  /// Signed in: this device's list joins the account's (a union, each
  /// handle keeping its earliest date), and the account's list rules from
  /// then on. A failure keeps the device list and tries again next time.
  Future<void> signedIn() async {
    if (remote == null || _account) return;
    _account = true;
    // Everything kept as a guest goes up once.
    _pendingAdds.addAll(_riders.map((r) => r.handle));
    await _savePending();
    await sync();
  }

  /// Signed out: the device's copy is cleared so the next person on a
  /// shared device neither sees nor keeps it; the account still has it.
  Future<void> signedOut() async {
    if (remote == null || !_account) return;
    _account = false;
    _accountFull = false;
    _pendingAdds.clear();
    _pendingRemoves.clear();
    await _savePending();
    _riders = [];
    notifyListeners();
    await local.clear();
  }

  /// Sends what the account has not taken yet, then reads its list. Never
  /// throws; one run at a time.
  Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    final store = remote;
    if (store == null || !_account) return;
    try {
      for (final handle in [..._pendingRemoves]) {
        await store.remove(handle);
        _pendingRemoves.remove(handle);
      }
      final adds = [
        for (final r in _riders)
          if (_pendingAdds.contains(r.handle)) r,
      ];
      final all = adds.isEmpty ? await store.list() : await store.merge(adds);
      _pendingAdds.removeAll(adds.map((r) => r.handle));
      if (!_account) return;
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
    } on HiddenRidersFull {
      _accountFull = true;
      notifyListeners();
    } catch (_) {
      // Offline or the RPCs are not there yet: keep the device list.
    } finally {
      await _savePending();
    }
  }
}

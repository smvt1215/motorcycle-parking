import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../admin_gateway.dart';
import 'user_models.dart';

class UsersController extends ChangeNotifier {
  UsersController(this.gateway);
  final AdminGateway? gateway;

  String query = '';
  List<AdminUser> results = [];
  bool searching = false;
  bool searched = false;
  String? searchError;

  AdminUserDetail? detail;
  String? openId;
  bool opening = false;
  String? openError;

  /// A ban change or name clear is being written.
  bool writing = false;
  String? writeError;

  /// Loading the account's older points.
  bool spotsLoading = false;
  String? spotsError;
  bool _spotsExhausted = false;

  /// More of the account's points exist than are listed.
  bool get hasMoreSpots {
    final d = detail;
    return d != null && !_spotsExhausted && d.spots.length < d.reports['spots'];
  }

  int _generation = 0;

  /// Bumped by every change to [detail] made here, so a slower background
  /// reload never replaces a newer state with its older snapshot.
  int _version = 0;
  int _searchSeq = 0;
  int _openSeq = 0;
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Access was lost or changed: nothing of the last admin stays.
  void reset() {
    _generation++;
    query = '';
    results = [];
    searching = false;
    searched = false;
    searchError = null;
    detail = null;
    openId = null;
    opening = false;
    openError = null;
    writing = false;
    writeError = null;
    _resetSpots();
    _notify();
  }

  void _resetSpots() {
    _version++;
    spotsLoading = false;
    spotsError = null;
    _spotsExhausted = false;
  }

  Future<void> search() async {
    if (gateway == null) return;
    final generation = _generation;
    final seq = ++_searchSeq;
    bool current() => generation == _generation && seq == _searchSeq;
    searching = true;
    searchError = null;
    _notify();
    try {
      final rows = await gateway!.searchUsers(query.trim());
      if (!current()) return;
      results = rows;
      searched = true;
    } catch (_) {
      if (current()) searchError = '使用者搜尋失敗，請檢查連線後重試。';
    } finally {
      if (current()) searching = false;
      _notify();
    }
  }

  Future<void> open(String id) async {
    if (gateway == null) return;
    final generation = _generation;
    final seq = ++_openSeq;
    bool current() => generation == _generation && seq == _openSeq;
    openId = id;
    opening = true;
    openError = null;
    writeError = null;
    detail = null;
    _resetSpots();
    _notify();
    try {
      final loaded = await gateway!.userDetail(id);
      if (!current()) return;
      detail = loaded;
      if (loaded == null) openError = '找不到這個帳號，可能已刪除或網址有誤。';
    } catch (_) {
      if (current()) openError = '帳號資料載入失敗，請檢查連線後重試。';
    } finally {
      if (current()) opening = false;
      _notify();
    }
  }

  void close() {
    _openSeq++;
    openId = null;
    detail = null;
    opening = false;
    openError = null;
    writeError = null;
    _resetSpots();
    _notify();
  }

  /// Bans for [length], or lifts the ban when it is null; true when written.
  Future<bool> setBan(BanLength? length, String reason) async {
    final current = detail;
    if (gateway == null || current == null || writing) return false;
    final generation = _generation;
    writing = true;
    writeError = null;
    _notify();
    try {
      final until = await gateway!.setUserBan(
        current.user.id,
        length: length,
        reason: reason,
      );
      if (generation != _generation) return false;
      final user = current.user.withBan(until);
      final shown = detail;
      if (shown?.user.id == user.id) detail = shown!.copyWith(user: user);
      results = [for (final u in results) u.id == user.id ? user : u];
      // The history row comes from the audit log; reload it quietly.
      _reloadHistory(user.id, generation, ++_version);
      return true;
    } catch (e) {
      if (generation == _generation) writeError = _banMessage(e);
      return false;
    } finally {
      if (generation == _generation) writing = false;
      _notify();
    }
  }

  /// Takes the account and its history from a fresh read, only if nothing
  /// changed here since [version]; the listed points stay as they are.
  Future<void> _reloadHistory(String id, int generation, int version) async {
    try {
      final loaded = await gateway!.userDetail(id);
      final shown = detail;
      if (generation != _generation ||
          version != _version ||
          shown?.user.id != id ||
          loaded == null) {
        return;
      }
      detail = shown!.copyWith(user: loaded.user, history: loaded.history);
      _notify();
    } catch (_) {
      // The page keeps the ban it just applied; history shows on next open.
    }
  }

  /// Clears the public name on one of the account's points.
  Future<bool> clearName(String spotId, String note) async {
    final current = detail;
    if (gateway == null || current == null || writing) return false;
    final generation = _generation;
    writing = true;
    writeError = null;
    _notify();
    try {
      await gateway!.clearContributorName(spotId, note);
      if (generation != _generation) return false;
      final shown = detail;
      if (shown?.user.id == current.user.id) {
        _version++;
        detail = shown!.copyWith(
          spots: [
            for (final s in shown.spots) s.id == spotId ? s.cleared() : s,
          ],
        );
      }
      return true;
    } catch (e) {
      if (generation == _generation) {
        writeError = e is PostgrestException && e.code == '42501'
            ? '需要通過兩步驟驗證的管理者帳號才能清除名稱，請重新登入後再試。'
            : '名稱清除失敗，請檢查連線後重試。';
      }
      return false;
    } finally {
      if (generation == _generation) writing = false;
      _notify();
    }
  }

  /// Appends the next page of the account's points.
  Future<void> loadMoreSpots() async {
    final current = detail;
    if (gateway == null || current == null || spotsLoading) return;
    final generation = _generation;
    final seq = _openSeq;
    final id = current.user.id;
    spotsLoading = true;
    spotsError = null;
    _notify();
    try {
      final page = await gateway!.userSpots(id, current.spots.length);
      final shown = detail;
      if (generation != _generation ||
          seq != _openSeq ||
          shown?.user.id != id) {
        return;
      }
      final known = {for (final s in shown!.spots) s.id};
      final added = [
        for (final s in page)
          if (!known.contains(s.id)) s,
      ];
      if (added.isEmpty) _spotsExhausted = true;
      detail = shown.copyWith(spots: [...shown.spots, ...added]);
    } catch (_) {
      if (generation == _generation && seq == _openSeq) {
        spotsError = '更早的點位載入失敗，請檢查連線後重試。';
      }
    } finally {
      if (generation == _generation && seq == _openSeq) spotsLoading = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String _banMessage(Object e) {
  if (e is! FunctionException) return '停權狀態沒有變更，請檢查連線後重試。';
  final error = e.details is Map ? (e.details as Map)['error'] : null;
  return switch ((e.status, error)) {
    (403, 'administrators cannot be banned here') => '管理者帳號不能在這裡停權。',
    (401 || 403, _) => '登入已過期或尚未通過兩步驟驗證，請重新登入後再試。',
    (404, _) => '找不到這個帳號，可能已刪除。',
    (400, 'you cannot ban your own account') => '不能停權自己的帳號。',
    (400, _) => '停權資料不完整，請填寫原因後再試。',
    (500, 'audit failed; the change was undone') => '稽核紀錄寫入失敗，停權狀態已還原，請稍後重試。',
    (500, _) => '稽核紀錄寫入失敗且無法還原，請重新載入確認目前的停權狀態。',
    _ => '停權狀態沒有變更，請稍後重試。',
  };
}

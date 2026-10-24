import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_gateway.dart';

enum AdminStage { loading, signedOut, denied, mfa, ready, unavailable }

class AdminController extends ChangeNotifier {
  AdminController(this.gateway, {this.configurationError}) {
    _subscription = gateway?.changes.listen(
      _authChanged,
      onError: (Object _) {
        error = '登入狀態更新失敗，請重試；若仍無法登入，請登出後再試。';
        _notify();
      },
    );
  }

  final AdminGateway? gateway;
  final String? configurationError;
  StreamSubscription<void>? _subscription;
  AdminStage stage = AdminStage.loading;
  AdminAccess access = const AdminAccess();
  List<Factor> factors = [];
  AuthMFAEnrollResponse? enrollment;
  String? selectedFactorId;
  AuthMFAChallengeResponse? challenge;
  String? error;
  String? countError;
  int? pendingCount;
  bool busy = false;
  bool refreshing = false;
  bool _disposed = false;
  int _generation = 0;

  List<Factor> get verifiedFactors => factors
      .where(
        (f) =>
            f.status == FactorStatus.verified &&
            (f.factorType == FactorType.totp ||
                f.factorType == FactorType.phone),
      )
      .toList();
  int get authenticatorCount =>
      verifiedFactors.where((f) => f.factorType == FactorType.totp).length;
  String? get activeFactorId => enrollment?.id ?? selectedFactorId;
  FactorType? get activeFactorType {
    if (enrollment != null) return enrollment!.type;
    for (final factor in verifiedFactors) {
      if (factor.id == selectedFactorId) return factor.factorType;
    }
    return null;
  }

  AdminStage _stage(AdminAccess value) => !value.signedIn
      ? AdminStage.signedOut
      : !value.isAdmin
      ? AdminStage.denied
      : !value.aal2
      ? AdminStage.mfa
      : AdminStage.ready;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _clearPrivateState() {
    factors = [];
    enrollment = null;
    selectedFactorId = null;
    challenge = null;
    pendingCount = null;
    countError = null;
  }

  void _authChanged(void _) {
    final current = gateway!.access;
    // Token refresh notifications may arrive after listFactors has completed.
    // Reload only when the identity or authorization level actually changes.
    if (current.userId == access.userId &&
        current.isAdmin == access.isAdmin &&
        current.aal2 == access.aal2) {
      return;
    }
    if (current.userId != access.userId || !current.isAdmin || !current.aal2) {
      // Revoke access immediately, including while another request is in flight.
      if (current.userId != access.userId || !current.isAdmin) {
        _generation++;
        _clearPrivateState();
      }
      access = current;
      stage = _stage(current);
      pendingCount = null;
      _notify();
    }
    // listFactors refreshes the token itself; never recursively list on that event.
    if (!refreshing && !busy) unawaited(refresh());
  }

  Future<void> refresh() async {
    if (_disposed || refreshing) return;
    if (gateway == null) {
      stage = AdminStage.unavailable;
      _notify();
      return;
    }
    refreshing = true;
    error = null;
    final generation = _generation;
    final userId = gateway!.access.userId;
    access = gateway!.access;
    stage = _stage(access);
    _notify();
    try {
      if (access.signedIn && access.isAdmin) {
        final loaded = await gateway!.listFactors();
        if (!_isCurrent(generation, userId)) return;
        access = gateway!.access;
        stage = _stage(access);
        if (!access.isAdmin) {
          _clearPrivateState();
          return;
        }
        factors = loaded;
        if (!verifiedFactors.any((f) => f.id == selectedFactorId)) {
          selectedFactorId = verifiedFactors.firstOrNull?.id;
          challenge = null;
        }
        if (stage == AdminStage.ready) await refreshCount();
      } else {
        _clearPrivateState();
      }
    } catch (_) {
      if (_isCurrent(generation, userId)) {
        error = '無法讀取驗證方式，請檢查連線後重試。';
        // Never expose the management shell before its access check completes.
        stage = AdminStage.unavailable;
      }
    } finally {
      refreshing = false;
      _notify();
      if (!_disposed && gateway!.access.userId != userId) unawaited(refresh());
    }
  }

  bool _isCurrent(int generation, String? userId) =>
      !_disposed &&
      generation == _generation &&
      gateway!.access.userId == userId;

  Future<void> refreshCount() async {
    if (gateway == null || _stage(gateway!.access) != AdminStage.ready) return;
    final generation = _generation;
    final userId = access.userId;
    countError = null;
    try {
      final count = await gateway!.pendingCount();
      if (_isCurrent(generation, userId) &&
          _stage(gateway!.access) == AdminStage.ready) {
        pendingCount = count;
      }
    } catch (_) {
      if (_isCurrent(generation, userId)) {
        pendingCount = null;
        countError = '待審數載入失敗，請重試。';
      }
    }
    _notify();
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    if (busy || _disposed || gateway == null) return;
    busy = true;
    error = null;
    _notify();
    try {
      await action();
    } catch (_) {
      error = failure;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> signIn() => _run(() => gateway!.signIn(), '無法開啟 Google 登入，請重試。');

  Future<void> signOut() => _run(() async {
    await gateway!.signOut();
    _generation++;
    _clearPrivateState();
    access = gateway!.access;
    stage = _stage(access);
  }, '登出失敗，請檢查連線後重試。');

  void selectFactor(String id) {
    if (busy || enrollment != null) return;
    selectedFactorId = id;
    challenge = null;
    error = null;
    _notify();
  }

  Future<void> enroll(FactorType type, String name, String? phone) =>
      _run(() async {
        if (!access.isAdmin ||
            enrollment != null ||
            (stage != AdminStage.ready && verifiedFactors.isNotEmpty)) {
          return;
        }
        final generation = _generation;
        final userId = access.userId;
        final result = await gateway!.enroll(
          type: type,
          name: name,
          phone: phone,
        );
        if (!_isCurrent(generation, userId)) return;
        enrollment = result;
        challenge = null;
      }, '無法登記此驗證方式。請確認名稱未重複、未達數量上限；簡訊需先啟用供應商。');

  Future<void> sendChallenge() => _run(() async {
    final id = activeFactorId;
    final type = activeFactorType;
    if (id == null || type == null) return;
    final generation = _generation;
    final userId = access.userId;
    final result = await gateway!.challenge(id, type);
    if (_isCurrent(generation, userId) && activeFactorId == id) {
      challenge = result;
    }
  }, '無法傳送驗證碼，請稍後重試或選擇另一個驗證方式。');

  Future<void> verify(String code) => _run(() async {
    final id = activeFactorId;
    final type = activeFactorType;
    if (id == null || type == null) return;
    final generation = _generation;
    final userId = access.userId;
    if (type == FactorType.totp ||
        challenge == null ||
        !challenge!.expiresAt.isAfter(DateTime.now())) {
      if (type == FactorType.phone) {
        error = '請先傳送簡訊驗證碼；若已過期，請重新傳送。';
        return;
      }
      final result = await gateway!.challenge(id, type);
      if (!_isCurrent(generation, userId)) return;
      challenge = result;
    }
    await gateway!.verify(id, challenge!.id, code);
    if (!_isCurrent(generation, userId)) return;
    enrollment = null;
    challenge = null;
    await refresh();
  }, '驗證碼不正確或已過期，請輸入最新的驗證碼後重試。');

  Future<void> cancelEnrollment() => _run(() async {
    final id = enrollment?.id;
    if (id == null) return;
    await gateway!.cancelEnrollment(id);
    enrollment = null;
    challenge = null;
    await refresh();
  }, '無法取消登記，請重試。');

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}

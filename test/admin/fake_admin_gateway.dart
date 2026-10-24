import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';

Factor factor(
  String id, {
  FactorType type = FactorType.totp,
  FactorStatus status = FactorStatus.verified,
}) => Factor(
  id: id,
  friendlyName: id,
  factorType: type,
  status: status,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const adminAal1 = AdminAccess(
  userId: 'admin',
  email: 'admin@example.test',
  isAdmin: true,
);
const adminAal2 = AdminAccess(
  userId: 'admin',
  email: 'admin@example.test',
  isAdmin: true,
  aal2: true,
);

class FakeAdminGateway implements AdminGateway {
  FakeAdminGateway({this.access = const AdminAccess()});
  @override
  AdminAccess access;
  final events = StreamController<void>.broadcast();
  List<Factor> factors = [factor('手機驗證器'), factor('備援驗證器')];
  int count = 7;
  int countRequests = 0;
  int factorRequests = 0;
  int challengeRequests = 0;
  bool failCount = false;
  bool failVerify = false;
  bool failFactors = false;
  bool failEnroll = false;
  Completer<int>? delayedCount;
  Completer<List<Factor>>? delayedFactors;
  final List<String> verifiedWith = [];
  final List<String> cancelled = [];

  @override
  Stream<void> get changes => events.stream;

  void emit(AdminAccess value) {
    access = value;
    events.add(null);
  }

  @override
  Future<void> signIn() async {}

  @override
  Future<void> signOut() async => emit(const AdminAccess());

  @override
  Future<List<Factor>> listFactors() async {
    factorRequests++;
    // The real SDK emits a token refresh while listing factors.
    events.add(null);
    if (failFactors) throw StateError('offline');
    return delayedFactors?.future ?? factors;
  }

  @override
  Future<AuthMFAEnrollResponse> enroll({
    required FactorType type,
    required String name,
    String? phone,
  }) async {
    if (failEnroll) throw StateError('provider disabled');
    return AuthMFAEnrollResponse(
      id: 'new-factor',
      type: type,
      totp: type == FactorType.totp
          ? const TOTPEnrollment(
              qrCode: 'data:image/svg+xml;utf-8,<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100"/></svg>',
              secret: 'TESTONLYSECRET',
              uri: 'otpauth://totp/test',
            )
          : null,
      phone: phone == null ? null : PhoneEnrollment(phone: phone),
    );
  }

  @override
  Future<AuthMFAChallengeResponse> challenge(
    String factorId,
    FactorType type,
  ) async {
    challengeRequests++;
    return AuthMFAChallengeResponse(
      id: 'challenge-$challengeRequests',
      expiresAt: DateTime.now().add(const Duration(minutes: 5)),
    );
  }

  @override
  Future<void> verify(String factorId, String challengeId, String code) async {
    verifiedWith.add('$factorId/$challengeId/$code');
    if (failVerify) throw StateError('wrong code');
    if (factorId == 'new-factor') factors = [...factors, factor(factorId)];
    emit(adminAal2);
  }

  @override
  Future<void> cancelEnrollment(String factorId) async =>
      cancelled.add(factorId);

  @override
  Future<int> pendingCount() async {
    countRequests++;
    if (failCount) throw StateError('offline');
    return delayedCount?.future ?? count;
  }

  Future<void> dispose() => events.close();
}

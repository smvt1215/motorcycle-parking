import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';

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

const communityId = '11111111-1111-4111-8111-111111111111';
const officialId = 'official:22222222-2222-4222-8222-222222222222';

final reportTime = DateTime.utc(2026, 10, 24, 9);

List<ReviewReport> sampleReports() => [
  ReviewReport(
    id: 'r-type',
    sourceId: communityId,
    reason: '格位類型：建議「重機專用格」',
    field: '格位類型',
    proposed: {'space_type': 'heavyOnly'},
    note: '地面有「大型重機」字樣',
    createdAt: reportTime,
    baseSpot: const {'space_type': 'freeMotorcycle'},
  ),
  ReviewReport(
    id: 'r-access',
    sourceId: officialId,
    reason: '機車停放資格：建議「普通機車可停 · 大型重機不可停」',
    field: 'eligibility',
    proposed: {'heavy_allowed': false},
    createdAt: reportTime.add(const Duration(hours: 1)),
  ),
  ReviewReport(
    id: 'r-gone',
    sourceId: communityId,
    reason: autoHiddenReason,
    createdAt: reportTime.add(const Duration(hours: 2)),
  ),
  ReviewReport(
    id: 'r-legacy',
    sourceId: officialId,
    reason: '收費資訊：改為每次 30 元',
    createdAt: reportTime.add(const Duration(hours: 3)),
  ),
];

Map<String, ReviewSpot> sampleSpots() => {
  communityId: const ReviewSpot(
    sourceId: communityId,
    official: false,
    values: {
      'name': '中山北路二段路邊機車格',
      'lat': 25.0581,
      'lng': 121.5226,
      'city': '臺北市',
      'district': '中山區',
      'space_type': 'paidMotorcycle',
      'fee_note': '每小時 20 元',
      'note': '',
      'scooter_allowed': true,
      'heavy_allowed': null,
      'status': 'hidden',
    },
  ),
  officialId: const ReviewSpot(
    sourceId: officialId,
    official: true,
    values: {
      'name': '新北市政府行政大樓地下停車場',
      'lat': 25.0124,
      'lng': 121.4651,
      'city': '新北市',
      'district': '板橋區',
      'space_type': 'offStreet',
      'fee_note': '依機車費率',
      'note': '',
      'scooter_allowed': true,
      'heavy_allowed': true,
      'source_name': '新北市政府',
    },
  ),
};

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
  List<ReviewReport> reports = sampleReports();
  Map<String, ReviewSpot> spots = sampleSpots();
  final List<(String, String, Map<String, dynamic>, String)> resolved = [];
  int reportRequests = 0;
  bool failReports = false;
  bool failSpots = false;

  /// Holds reviewSpots open, to race a load against a write.
  Completer<void>? delayedSpots;
  Object? resolveError;

  /// Holds resolveReport open until completed, to race it against sign-out.
  Completer<void>? delayedResolve;
  final List<(String, bool)> hiddenChanges = [];

  /// Report ids whose spot changed after they were sent.
  final Set<String> changedSpots = {};
  final List<bool> forced = [];
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
    if (factors.any((f) => f.friendlyName == name)) {
      throw StateError('duplicate name');
    }
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
  Future<void> cancelEnrollment(String factorId) async {
    cancelled.add(factorId);
    factors = factors.where((f) => f.id != factorId).toList();
  }

  @override
  Future<int> pendingCount() async {
    countRequests++;
    if (failCount) throw StateError('offline');
    return delayedCount?.future ?? count;
  }

  @override
  Future<List<ReviewReport>> pendingReports() async {
    reportRequests++;
    if (failReports) throw StateError('offline');
    return reports;
  }

  @override
  Future<Map<String, ReviewSpot>> reviewSpots(
    Iterable<String> sourceIds,
  ) async {
    await delayedSpots?.future;
    if (failSpots) throw StateError('offline');
    return {
      for (final id in sourceIds)
        if (spots[id] != null) id: spots[id]!,
    };
  }

  @override
  Future<void> resolveReport(
    String id,
    String decision,
    Map<String, dynamic> patch,
    String note, {
    bool force = false,
  }) async {
    await delayedResolve?.future;
    if (resolveError != null) throw resolveError!;
    if (changedSpots.contains(id) && patch.isNotEmpty && !force) {
      throw const PostgrestException(message: 'spot changed since the report');
    }
    forced.add(force);
    resolved.add((id, decision, patch, note));
    reports = reports.where((r) => r.id != id).toList();
    count--;
  }

  @override
  Future<List<ReviewSpot>> hiddenSpots() async => [
    for (final spot in spots.values)
      if (spot.hidden) spot,
  ];

  @override
  Future<void> setSpotHidden(String sourceId, bool hidden, String note) async {
    hiddenChanges.add((sourceId, hidden));
    final spot = spots[sourceId]!;
    spots[sourceId] = ReviewSpot(
      sourceId: sourceId,
      official: spot.official,
      values: {
        ...spot.values,
        if (spot.official)
          'hidden': hidden
        else
          'status': hidden ? 'hidden' : 'pending',
      },
    );
  }

  Future<void> dispose() => events.close();
}

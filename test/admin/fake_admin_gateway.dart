import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:motorcycle_parking/admin/import/import_models.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/domain/location_check.dart';

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
    if (spotRows[sourceId] case final row?) {
      spotRows[sourceId] = {
        ...row,
        if (sourceId.startsWith('official:'))
          'hidden': hidden
        else
          'status': hidden ? 'hidden' : 'pending',
        'updated_at': _bump(),
      };
    }
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

  /// Spots page data: full rows by source id, as the tables return them.
  Map<String, Map<String, dynamic>> spotRows = {
    communityId: {
      ...sampleSpots()[communityId]!.values,
      'id': communityId,
      'source': 'community',
      'status': 'pending',
      'facility_type': null,
      'parking_access': null,
      'address': '中山北路二段 1 號',
      'road_segment': '',
      'entrance_note': '',
      'parking_guide': '',
      'special_rules': '',
      'scooter_total': null,
      'updated_at': '2026-10-24T09:00:00.000001+00:00',
    },
    officialId: {
      ...sampleSpots()[officialId]!.values,
      'id': officialId.substring('official:'.length),
      'hidden': false,
      'source_url': 'https://example.test/notice',
      'source_id': 'ntpc-001',
      'effective_date': '2026-01-01',
      'license_note': '',
      'facility_type': 'underground',
      'parking_access': 'scooterHeavy',
      'address': '新北市板橋區中山路一段 161 號',
      'road_segment': '',
      'entrance_note': '',
      'parking_guide': '',
      'special_rules': '',
      'scooter_total': 300,
      'updated_at': '2026-10-24T09:00:00.000002+00:00',
    },
  };
  final List<(String, Map<String, dynamic>, String, String)> spotUpdates = [];
  final List<(String, Map<String, dynamic>, String)> promotions = [];
  bool failSearch = false;
  int _version = 10;

  @override
  Future<List<SpotSummary>> searchSpots(
    String query, {
    SpotKind? kind,
    String? state,
  }) async {
    if (failSearch) throw StateError('offline');
    return [
      for (final MapEntry(key: id, value: v) in spotRows.entries)
        if ((v['name'] as String).contains(query) &&
            (kind == null ||
                (id.startsWith('official:')) == (kind == SpotKind.official)))
          SpotSummary(
            sourceId: id,
            kind: id.startsWith('official:')
                ? SpotKind.official
                : SpotKind.community,
            name: v['name'] as String,
            city: v['city'] as String,
            district: v['district'] as String,
            address: v['address'] as String,
            spaceType: v['space_type'] as String,
            state: id.startsWith('official:')
                ? (v['hidden'] == true ? 'hidden' : 'visible')
                : v['status'] as String,
            updatedAt: DateTime.parse(v['updated_at'] as String),
          ),
    ];
  }

  @override
  Future<SpotRecord?> spot(String sourceId) async {
    final v = spotRows[sourceId];
    return v == null ? null : SpotRecord(sourceId: sourceId, values: {...v});
  }

  String _bump() =>
      '2026-10-25T00:00:${(_version++).toString().padLeft(2, '0')}.000000+00:00';

  @override
  Future<SpotRecord> updateSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  ) async {
    final row = spotRows[sourceId]!;
    if (row['updated_at'] != baseUpdatedAt) {
      throw const PostgrestException(
        message: 'spot changed since it was opened',
      );
    }
    spotUpdates.add((sourceId, values, baseUpdatedAt, note));
    spotRows[sourceId] = {
      ...row,
      ...values,
      'updated_at': _bump(),
      // The database trigger: a stated community flag is verified.
      if (!sourceId.startsWith('official:'))
        for (final flag in ['scooter', 'heavy'])
          if (values['${flag}_allowed'] is bool)
            '${flag}_verified_at': '2026-10-25T01:19:36Z',
    };
    return SpotRecord(sourceId: sourceId, values: {...spotRows[sourceId]!});
  }

  @override
  Future<String> promoteSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  ) async {
    final row = spotRows[sourceId]!;
    if (row['updated_at'] != baseUpdatedAt) {
      throw const PostgrestException(
        message: 'spot changed since it was opened',
      );
    }
    promotions.add((sourceId, values, note));
    const id = 'official:99999999-9999-4999-8999-999999999999';
    spotRows[id] = {
      ...row,
      'id': id.substring('official:'.length),
      'scooter_allowed': values['scooter_allowed'],
      'heavy_allowed': values['heavy_allowed'],
      ...values,
      'hidden': false,
      'source_id': null,
      'license_note': '',
      'updated_at': _bump(),
    };
    spotRows[sourceId] = {...row, 'status': 'hidden', 'updated_at': _bump()};
    return id;
  }

  final List<(SpotKind, Map<String, dynamic>, String)> created = [];
  Town? townAt = const Town('臺北市', '中山區');
  bool failTown = false;
  List<NearbySpot> nearby = const [];
  int townRequests = 0;

  /// Holds a lookup open, to race it against switching or saving.
  Completer<void>? delayedTown;

  @override
  Future<SpotRecord> createSpot(
    SpotKind kind,
    Map<String, dynamic> values,
    String note,
  ) async {
    created.add((kind, values, note));
    final id = kind == SpotKind.official
        ? 'official:88888888-8888-4888-8888-888888888888'
        : '77777777-7777-4777-8777-777777777777';
    spotRows[id] = {
      'id': id.replaceFirst('official:', ''),
      'source': 'community',
      'hidden': false,
      'status': 'pending',
      ...values,
      'updated_at': _bump(),
    };
    return SpotRecord(sourceId: id, values: {...spotRows[id]!});
  }

  @override
  Future<List<NearbySpot>> nearbySpots(double lat, double lng) async => nearby;

  @override
  Future<Town?> town(double lat, double lng) async {
    townRequests++;
    await delayedTown?.future;
    if (failTown) throw StateError('offline');
    return townAt;
  }

  /// What the preview says about known ids; any other id is new.
  Map<String, ImportEntry> importPlan = {};
  final List<List<Map<String, dynamic>>> previewed = [];
  final List<(List<Map<String, dynamic>>, Map<String, dynamic>, String, String)>
  imported = [];
  Object? importError;

  @override
  Future<List<ImportEntry>> previewImport(
    List<Map<String, dynamic>> spots,
  ) async {
    previewed.add(spots);
    if (importError case final error?) throw error;
    return [
      for (final s in spots)
        importPlan[s['id']] ??
            ImportEntry(
              sourceId: '${s['id']}',
              official: '${s['id']}'.startsWith('official:'),
              status: ImportStatus.added,
              reason: '',
              name: '${s['name']}',
              city: '${s['city'] ?? ''}',
              district: '${s['district'] ?? ''}',
            ),
    ];
  }

  @override
  Future<ImportResult> applyImport(
    List<Map<String, dynamic>> spots,
    Map<String, dynamic> choices,
    String effectiveDate,
    String note,
  ) async {
    imported.add((spots, choices, effectiveDate, note));
    var inserted = 0, updated = 0;
    for (final id in choices.keys) {
      final entry = importPlan[id];
      if (entry == null) {
        inserted++;
      } else {
        updated++;
      }
      importPlan[id] = ImportEntry(
        sourceId: id,
        official: id.startsWith('official:'),
        status: ImportStatus.unchanged,
        reason: '',
        name: entry?.name ?? '',
        city: entry?.city ?? '',
        district: entry?.district ?? '',
        baseUpdatedAt: '2026-10-26T00:00:00Z',
      );
    }
    return ImportResult(inserted: inserted, updated: updated);
  }

  List<FeeBacklogItem> backlog = [];
  final List<(List<Map<String, dynamic>>, String)> conversions = [];

  @override
  Future<List<FeeBacklogItem>> feeBacklog() async => backlog;

  @override
  Future<ImportResult> convertFees(
    List<Map<String, dynamic>> items,
    String note,
  ) async {
    conversions.add((items, note));
    final ids = {for (final i in items) i['source_id']};
    backlog = [
      for (final b in backlog)
        if (!ids.contains(b.sourceId)) b,
    ];
    return ImportResult(updated: items.length);
  }

  /// What [searchAddress] returns, or throws when set.
  List<AddressCandidate> addressResults = [];
  AddressSearchException? addressError;
  final List<String> addressQueries = [];

  @override
  Future<List<AddressCandidate>> searchAddress(
    String query, {
    double? lat,
    double? lng,
  }) async {
    addressQueries.add(query);
    if (addressError case final e?) throw e;
    return addressResults;
  }

  Future<void> dispose() => events.close();

  /// `city_rules` rows, keyed `city:vehicle`.
  Map<String, Map<String, dynamic>> ruleRows = {
    for (final r in sampleRules()) '${r['city']}:${r['vehicle']}': r,
  };
  final List<(String, String, Map<String, dynamic>, int?, String)> published =
      [];
  bool failRules = false;

  @override
  Future<List<Map<String, dynamic>>> cityRules() async {
    if (failRules) throw StateError('offline');
    return [
      for (final r in ruleRows.values) {...r},
    ];
  }

  @override
  Future<Map<String, dynamic>> publishCityRule(
    String city,
    String vehicle,
    Map<String, dynamic> values,
    int? baseVersion,
    String note,
  ) async {
    final old = ruleRows['$city:$vehicle'];
    if (old?['version'] != baseVersion) {
      throw const PostgrestException(
        message: 'rule changed since it was opened',
        code: '40001',
      );
    }
    published.add((city, vehicle, values, baseVersion, note));
    final row = {
      ...?old,
      'city': city,
      'vehicle': vehicle,
      ...values,
      'version': (baseVersion ?? 0) + 1,
    };
    ruleRows['$city:$vehicle'] = row;
    return {...row};
  }
}

/// Two published rules: Taipei's heavy-bike rule and Taichung's conditional
/// one, as the bundled file has them.
List<Map<String, dynamic>> sampleRules() => [
  {
    'city': '臺北市',
    'vehicle': 'heavy',
    'allowed_space_types': ['paidMotorcycle', 'heavyOnly', 'car'],
    'conditional_space_types': ['offStreet'],
    'districts': <String>[],
    'district_space_types': <String, dynamic>{},
    'fee_note': '一般計次每次 40 元',
    'exceptions': '僅公有路邊收費機車格；免費巷弄格不適用。',
    'can_use_two_spaces': true,
    'effective_date': '2026-10-06',
    'source_url': 'https://www.gov.taipei/notice',
    'restriction': null,
    'version': 1,
  },
  {
    'city': '新北市',
    'vehicle': 'heavy',
    'allowed_space_types': ['heavyOnly', 'car', 'paidMotorcycle'],
    'conditional_space_types': ['offStreet'],
    'districts': <String>[],
    'district_space_types': {
      'freeMotorcycle': ['板橋區', '新店區'],
    },
    'fee_note': '計次每 4 小時 30 元',
    'exceptions': '免費機車格僅板橋區、新店區開放。',
    'can_use_two_spaces': true,
    'effective_date': '2026-07-01',
    'source_url': 'https://www.traffic.ntpc.gov.tw/notice',
    'restriction': null,
    'version': 2,
  },
];

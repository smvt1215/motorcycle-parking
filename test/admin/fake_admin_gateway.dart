import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:motorcycle_parking/admin/admin_gateway.dart';
import 'package:motorcycle_parking/admin/import/import_models.dart';
import 'package:motorcycle_parking/admin/review/review_models.dart';
import 'package:motorcycle_parking/admin/spots/spot_map.dart';
import 'package:motorcycle_parking/admin/spots/spot_models.dart';
import 'package:motorcycle_parking/admin/users/user_models.dart';
import 'package:motorcycle_parking/core/address_search.dart';
import 'package:motorcycle_parking/core/town_lookup.dart';
import 'package:motorcycle_parking/domain/location_check.dart';
import 'package:motorcycle_parking/domain/map_viewport.dart';
import 'package:motorcycle_parking/models/parking.dart';
import 'package:motorcycle_parking/models/spot_history.dart';

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
const riderId = '33333333-3333-4333-8333-333333333333';

Map<String, dynamic> sampleUserRow({
  String id = riderId,
  String name = '夜騎小哲',
  String? bannedUntil,
  bool admin = false,
}) => {
  'id': id,
  'display_name': name,
  'email_masked': 'ri***@example.test',
  'providers': ['google'],
  'is_admin': admin,
  'created_at': '2026-09-01T00:00:00Z',
  'last_sign_in_at': '2026-10-24T01:00:00Z',
  'banned_until': bannedUntil,
  'deleted': false,
  'reports_30d': 12,
  'last_report_at': '2026-10-24T02:00:00Z',
};

Map<String, dynamic> sampleUserDetail({String? bannedUntil, int today = 3}) => {
  'user': sampleUserRow(bannedUntil: bannedUntil),
  'limits': {
    'today': today,
    'daily_limit': 10,
    'last_7d': 9,
    'last_30d': 12,
    'networks_30d': 2,
    'shared_accounts_30d': 1,
  },
  'events': [
    {'created_at': '2026-10-24T02:00:00Z', 'network': 'a1b2c3'},
    {'created_at': '2026-10-23T02:00:00Z', 'network': 'd4e5f6'},
  ],
  'reports': {
    'spots': 2,
    'spots_hidden': 1,
    'votes_still_there': 5,
    'votes_gone': 1,
    'flags_pending': 1,
    'flags_accepted': 2,
    'flags_rejected': 3,
    'flags_closed': 0,
  },
  'spots': [
    {
      'id': communityId,
      'name': '中山北路二段路邊機車格',
      'city': '臺北市',
      'district': '中山區',
      'status': 'confirmed',
      'contributor_name': '夜騎小哲',
      'name_cleared': false,
    },
    {
      'id': '44444444-4444-4444-8444-444444444444',
      'name': '已清除名稱的點位',
      'city': '臺北市',
      'district': '大安區',
      'status': 'hidden',
      'contributor_name': '',
      'name_cleared': true,
    },
  ],
  'history': <Map<String, dynamic>>[],
};
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
    risk: ReviewRisk.medium,
  ),
  ReviewReport(
    id: 'r-access',
    sourceId: officialId,
    reason: '機車停放資格：建議「普通機車可停 · 大型重機不可停」',
    field: 'eligibility',
    proposed: {'heavy_allowed': false},
    createdAt: reportTime.add(const Duration(hours: 1)),
    risk: ReviewRisk.high,
  ),
  ReviewReport(
    id: 'r-gone',
    sourceId: communityId,
    reason: autoHiddenReason,
    createdAt: reportTime.add(const Duration(hours: 2)),
    risk: ReviewRisk.medium,
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
      'deleted_at': '2026-10-24T09:00:00Z',
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
  final List<ResolutionKind?> kinds = [];
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
    ResolutionKind? resolutionKind,
  }) async {
    await delayedResolve?.future;
    if (resolveError != null) throw resolveError!;
    if (changedSpots.contains(id) && patch.isNotEmpty && !force) {
      throw const PostgrestException(message: 'spot changed since the report');
    }
    if (decision == 'rejected' && resolutionKind == null) {
      throw const PostgrestException(
        message: 'a rejection needs a resolution kind',
      );
    }
    if (resolutionKind == ResolutionKind.other && note.trim().isEmpty) {
      throw const PostgrestException(
        message: 'resolution kind other needs a note',
      );
    }
    forced.add(force);
    kinds.add(resolutionKind);
    resolved.add((id, decision, patch, note));
    reports = reports.where((r) => r.id != id).toList();
    count--;
  }

  @override
  Future<List<ReviewSpot>> hiddenSpots() async => [
    for (final spot in spots.values)
      if (spot.hidden) spot,
  ];

  /// Official spots purged after deletion (#200).
  List<PurgedOfficialSpot> purged = [];
  final List<String> released = [];

  @override
  Future<List<PurgedOfficialSpot>> purgedOfficialSpots({
    String query = '',
  }) async => [
    for (final p in purged)
      if (query.isEmpty || p.name.contains(query) || p.sourceId.contains(query))
        p,
  ];

  @override
  Future<void> releasePurgedOfficial(String officialId, String note) async {
    released.add(officialId);
    purged = purged.where((p) => p.officialId != officialId).toList();
  }

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
        'deleted_at': hidden ? '2026-10-25T00:00:00Z' : null,
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
        'deleted_at': hidden ? '2026-10-25T00:00:00Z' : null,
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
      // Both vehicles stated (#201): an edit of old data must fill them in,
      // which the tests that need it set up themselves.
      'heavy_allowed': false,
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
      'facility_types': ['underground'],
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

  /// Thrown by the next updateSpot, e.g. 'fee plan in use'.
  Object? spotUpdateError;
  final List<(String, Map<String, dynamic>, String)> promotions = [];
  bool failSearch = false;
  int searchRequests = 0;
  int _version = 10;

  @override
  Future<List<SpotSummary>> searchSpots(
    String query, {
    SpotKind? kind,
    String? state,
  }) async {
    searchRequests++;
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
            // A spot created here may leave these out.
            address: v['address'] as String? ?? '',
            spaceType: v['space_type'] as String? ?? '',
            state: id.startsWith('official:')
                ? (v['hidden'] == true ? 'hidden' : 'visible')
                : v['status'] as String,
            updatedAt: DateTime.parse(v['updated_at'] as String),
          ),
    ];
  }

  @override
  Future<List<HistoryEntry>> spotHistory(String sourceId) async {
    historyRequests.add(sourceId);
    if (historyError case final e?) throw e;
    return HistoryEntry.list(historyRows[sourceId] ?? const []);
  }

  /// `admin_spot_history` rows by spot.
  Map<String, List<Map<String, dynamic>>> historyRows = {};
  final historyRequests = <String>[];
  Object? historyError;

  /// Holds spot() open, to race a background reload against an edit.
  Completer<void>? delayedSpot;
  int spotRequests = 0;

  @override
  Future<SpotRecord?> spot(String sourceId) async {
    spotRequests++;
    await delayedSpot?.future;
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
    if (spotUpdateError case final error?) throw error;
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

  /// Holds previews or backlog reads open, to race them against a reset.
  Completer<void>? delayedPreview;
  Completer<void>? delayedBacklog;

  @override
  Future<List<ImportEntry>> previewImport(
    List<Map<String, dynamic>> spots,
  ) async {
    previewed.add(spots);
    await delayedPreview?.future;
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
  Object? convertError;
  final List<(List<Map<String, dynamic>>, String)> conversions = [];

  @override
  Future<List<FeeBacklogItem>> feeBacklog() async {
    final answer = backlog;
    await delayedBacklog?.future;
    return answer;
  }

  @override
  Future<ImportResult> convertFees(
    List<Map<String, dynamic>> items,
    String note,
  ) async {
    conversions.add((items, note));
    if (convertError case final error?) throw error;
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

  List<Map<String, dynamic>> userRows = [sampleUserRow()];
  Map<String, Map<String, dynamic>> userDetails = {riderId: sampleUserDetail()};
  final userQueries = <String>[];
  final bans = <(String, BanLength?, String)>[];
  final clearedNames = <(String, String)>[];
  Object? banError;
  bool failUsers = false;

  @override
  Future<List<AdminUser>> searchUsers(String query) async {
    userQueries.add(query);
    if (failUsers) throw StateError('offline');
    return userRows.map(AdminUser.fromJson).toList();
  }

  @override
  Future<AdminUserDetail?> userDetail(String userId) async {
    // Snapshot now: a slow response carries the state it was asked for.
    final row = userDetails[userId];
    await delayedDetail?.future;
    return row == null ? null : AdminUserDetail.fromJson(row);
  }

  /// Points past the first page, by user id.
  Map<String, List<Map<String, dynamic>>> olderSpots = {};
  final spotPages = <(String, int)>[];

  /// Holds [userDetail] until completed, to test out-of-order reloads.
  Completer<void>? delayedDetail;

  @override
  Future<List<UserSpot>> userSpots(String userId, int offset) async {
    spotPages.add((userId, offset));
    return [
      for (final s in olderSpots[userId] ?? <Map<String, dynamic>>[])
        UserSpot.fromJson(s),
    ];
  }

  @override
  Future<DateTime?> setUserBan(
    String userId, {
    required BanLength? length,
    required String reason,
  }) async {
    if (banError != null) throw banError!;
    bans.add((userId, length, reason));
    final until = length == null ? null : '2026-11-01T00:00:00Z';
    final detail = userDetails[userId];
    if (detail != null) {
      userDetails[userId] = {
        ...detail,
        'user': {
          ...detail['user'] as Map<String, dynamic>,
          'banned_until': until,
        },
        'history': [
          {
            'action': length == null ? 'unban_user' : 'ban_user',
            'note': reason,
            'created_at': '2026-10-25T00:00:00Z',
            'banned_until': until,
          },
          ...detail['history'] as List,
        ],
      };
    }
    return until == null ? null : DateTime.parse(until).toLocal();
  }

  @override
  Future<void> clearContributorName(String spotId, String note) async {
    clearedNames.add((spotId, note));
  }

  /// Rows `admin_viewport_spots` returns, before the layer filter.
  List<Map<String, dynamic>> mapRows = sampleMapRows();
  final List<(MapViewport, bool, bool, bool)> mapRequests = [];
  bool failMap = false;

  @override
  Future<MapSpotPage> mapSpots(
    MapViewport bounds, {
    required bool community,
    required bool official,
    required bool hidden,
  }) async {
    mapRequests.add((bounds, community, official, hidden));
    if (failMap) throw StateError('offline');
    return MapSpotPage.fromRows([
      for (final row in mapRows)
        if (row['hidden'] == true
            ? hidden
            : row['source'] == 'official'
            ? official
            : community)
          row,
    ]);
  }

  int ruleRequests = 0;

  @override
  Future<List<CityRule>> cityRules() async {
    ruleRequests++;
    return const [];
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
  Future<List<Map<String, dynamic>>> cityRuleRows() async {
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

List<Map<String, dynamic>> sampleMapRows() => [
  {
    'id': communityId,
    'source': 'community',
    'name': '中山北路二段路邊機車格',
    'lat': 25.0581,
    'lng': 121.5226,
    'city': '臺北市',
    'space_type': 'paidMotorcycle',
    'status': 'pending',
    'hidden': false,
  },
  {
    'id': officialId,
    'source': 'official',
    'name': '新北市政府行政大樓地下停車場',
    'lat': 25.0124,
    'lng': 121.4651,
    'city': '新北市',
    'space_type': 'offStreet',
    'status': 'confirmed',
    'heavy_allowed': true,
    'hidden': false,
  },
  {
    'id': '33333333-3333-4333-8333-333333333333',
    'source': 'community',
    'name': '三重正義北路機車格',
    'lat': 25.06,
    'lng': 121.49,
    'city': '新北市',
    'space_type': 'freeMotorcycle',
    'status': 'hidden',
    'hidden': true,
  },
];

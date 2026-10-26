import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/town_lookup.dart';
import '../domain/location_check.dart';
import 'review/review_models.dart';
import 'spots/spot_models.dart';

class AdminAccess {
  const AdminAccess({
    this.userId,
    this.email,
    this.isAdmin = false,
    this.aal2 = false,
  });

  final String? userId;
  final String? email;
  final bool isAdmin;
  final bool aal2;
  bool get signedIn => userId != null;
}

/// The UI never receives a service role key. RLS remains the authority for data.
abstract class AdminGateway {
  AdminAccess get access;
  Stream<void> get changes;
  Future<void> signIn();
  Future<void> signOut();
  Future<List<Factor>> listFactors();
  Future<AuthMFAEnrollResponse> enroll({
    required FactorType type,
    required String name,
    String? phone,
  });
  Future<AuthMFAChallengeResponse> challenge(String factorId, FactorType type);
  Future<void> verify(String factorId, String challengeId, String code);
  Future<void> cancelEnrollment(String factorId);
  Future<int> pendingCount();

  /// Oldest first, so the queue is worked in the order riders reported.
  Future<List<ReviewReport>> pendingReports();

  /// Current values of the reported spots, keyed by `source_id`.
  Future<Map<String, ReviewSpot>> reviewSpots(Iterable<String> sourceIds);

  /// `admin_resolve_report`: applies [patch] and closes the report atomically.
  /// It refuses a spot changed since the report unless [force] is set, and a
  /// rejection without [resolutionKind].
  Future<void> resolveReport(
    String id,
    String decision,
    Map<String, dynamic> patch,
    String note, {
    bool force = false,
    ResolutionKind? resolutionKind,
  });

  /// Hidden community and official spots, most recently changed first.
  Future<List<ReviewSpot>> hiddenSpots();

  /// `admin_set_spot_hidden`: hide or restore one spot, audited.
  Future<void> setSpotHidden(String sourceId, bool hidden, String note);

  /// `admin_spots`: both tables, newest first.
  Future<List<SpotSummary>> searchSpots(
    String query, {
    SpotKind? kind,
    String? state,
  });

  /// Every editable column of one spot, with the version to edit against.
  Future<SpotRecord?> spot(String sourceId);

  /// `admin_upsert_spot`: edits [values] on the version [baseUpdatedAt].
  Future<SpotRecord> updateSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  );

  /// `admin_upsert_spot` with no id: a new spot of [kind].
  Future<SpotRecord> createSpot(
    SpotKind kind,
    Map<String, dynamic> values,
    String note,
  );

  /// Visible spots within about 30 m, for the duplicate warning.
  Future<List<NearbySpot>> nearbySpots(double lat, double lng);

  /// County or city and district of a point; null at sea.
  Future<Town?> town(double lat, double lng);

  /// `admin_promote_spot`: a community spot becomes an official one.
  Future<String> promoteSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  );
}

/// Community columns readable by clients; `user_id` is never granted.
const _communityColumns =
    'id,source,source_name,source_url,license_note,name,lat,lng,city,district,space_type,fee_note,note,'
    'scooter_total,scooter_allowed,heavy_allowed,status,updated_at,last_confirmed_at,created_at,'
    'facility_type,parking_access,address,road_segment,entrance_note,parking_guide,special_rules,'
    'scooter_verified_at,heavy_verified_at,fee';

/// Every column the review page shows or edits; a conflict refresh must
/// show the admin each current value before a forced write.
const _spotColumns =
    'id,name,lat,lng,city,district,space_type,fee_note,note,scooter_allowed,heavy_allowed,source_name,updated_at,'
    'facility_type,parking_access,entrance_note,parking_guide,fee';
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

class SupabaseAdminGateway implements AdminGateway {
  SupabaseAdminGateway(this.client);
  final SupabaseClient client;

  @override
  AdminAccess get access {
    final session = client.auth.currentSession;
    return AdminAccess(
      userId: session?.user.id,
      email: session?.user.email,
      isAdmin: session?.user.appMetadata['role'] == 'admin',
      aal2:
          session != null &&
          client.auth.mfa.getAuthenticatorAssuranceLevel().currentLevel ==
              AuthenticatorAssuranceLevels.aal2,
    );
  }

  @override
  Stream<void> get changes => client.auth.onAuthStateChange.map((_) {});

  @override
  Future<void> signIn() async {
    final launched = await client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: Uri.base.replace(fragment: '', query: '').toString(),
    );
    if (!launched) throw StateError('OAuth could not open');
  }

  @override
  Future<void> signOut() => client.auth.signOut(scope: SignOutScope.local);

  @override
  Future<List<Factor>> listFactors() async =>
      (await client.auth.mfa.listFactors()).all;

  @override
  Future<AuthMFAEnrollResponse> enroll({
    required FactorType type,
    required String name,
    String? phone,
  }) => client.auth.mfa.enroll(
    factorType: type,
    friendlyName: name,
    issuer: type == FactorType.totp ? '停車指南管理' : null,
    phone: phone,
  );

  @override
  Future<AuthMFAChallengeResponse> challenge(
    String factorId,
    FactorType type,
  ) => client.auth.mfa.challenge(
    factorId: factorId,
    channel: type == FactorType.phone ? OtpChannel.sms : null,
  );

  @override
  Future<void> verify(String factorId, String challengeId, String code) async {
    await client.auth.mfa.verify(
      factorId: factorId,
      challengeId: challengeId,
      code: code,
    );
  }

  @override
  Future<void> cancelEnrollment(String factorId) async {
    await client.auth.mfa.unenroll(factorId);
  }

  @override
  Future<int> pendingCount() => client
      .from('moderation_queue')
      .count(CountOption.exact)
      .eq('status', 'pending');

  @override
  Future<List<ReviewReport>> pendingReports() async {
    final rows = await client
        .from('moderation_queue')
        .select(
          'id,source_id,reason,field,proposed,note,created_at,base_spot,risk',
        )
        .eq('status', 'pending')
        .order('created_at')
        .limit(200);
    return rows.map(ReviewReport.fromJson).toList();
  }

  @override
  Future<Map<String, ReviewSpot>> reviewSpots(
    Iterable<String> sourceIds,
  ) async {
    final official = <String>{}, community = <String>{};
    for (final id in sourceIds) {
      if (id.startsWith('official:')) {
        final raw = id.substring('official:'.length);
        if (_uuid.hasMatch(raw)) official.add(raw);
      } else if (_uuid.hasMatch(id)) {
        community.add(id);
      }
    }
    final result = <String, ReviewSpot>{};
    if (community.isNotEmpty) {
      final rows = await client
          .from('community_spots')
          .select('$_spotColumns,status')
          .inFilter('id', community.toList());
      for (final row in rows) {
        result[row['id'] as String] = ReviewSpot(
          sourceId: row['id'] as String,
          official: false,
          values: row,
        );
      }
    }
    if (official.isNotEmpty) {
      final rows = await client
          .from('official_heavy_spots')
          .select('$_spotColumns,hidden')
          .inFilter('id', official.toList());
      for (final row in rows) {
        final id = 'official:${row['id']}';
        result[id] = ReviewSpot(sourceId: id, official: true, values: row);
      }
    }
    return result;
  }

  @override
  Future<void> resolveReport(
    String id,
    String decision,
    Map<String, dynamic> patch,
    String note, {
    bool force = false,
    ResolutionKind? resolutionKind,
  }) => client.rpc(
    'admin_resolve_report',
    params: {
      'p_id': id,
      'p_decision': decision,
      'p_patch': patch,
      'p_note': note,
      'p_force': force,
      'p_resolution_kind': resolutionKind?.name,
    },
  );

  @override
  Future<List<ReviewSpot>> hiddenSpots() async {
    final community = await client
        .from('community_spots')
        .select('$_spotColumns,status')
        .eq('status', 'hidden')
        .order('updated_at', ascending: false)
        .limit(200);
    final official = await client
        .from('official_heavy_spots')
        .select('$_spotColumns,hidden')
        .eq('hidden', true)
        .order('updated_at', ascending: false)
        .limit(200);
    final spots = [
      for (final row in community)
        ReviewSpot(sourceId: row['id'] as String, official: false, values: row),
      for (final row in official)
        ReviewSpot(
          sourceId: 'official:${row['id']}',
          official: true,
          values: row,
        ),
    ];
    final epoch = DateTime.utc(2000);
    return spots
      ..sort((a, b) => (b.updatedAt ?? epoch).compareTo(a.updatedAt ?? epoch));
  }

  @override
  Future<void> setSpotHidden(String sourceId, bool hidden, String note) =>
      client.rpc(
        'admin_set_spot_hidden',
        params: {'p_source_id': sourceId, 'p_hidden': hidden, 'p_note': note},
      );

  @override
  Future<List<SpotSummary>> searchSpots(
    String query, {
    SpotKind? kind,
    String? state,
  }) async {
    final rows = await client.rpc<List<dynamic>>(
      'admin_spots',
      params: {'p_query': query, 'p_kind': kind?.name, 'p_state': state},
    );
    return rows
        .map((r) => SpotSummary.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<SpotRecord?> spot(String sourceId) async {
    final official = sourceId.startsWith('official:');
    final id = official ? sourceId.substring('official:'.length) : sourceId;
    if (!_uuid.hasMatch(id)) return null;
    final row = await client
        .from(official ? 'official_heavy_spots' : 'community_spots')
        .select(official ? '*' : _communityColumns)
        .eq('id', id)
        .maybeSingle();
    return row == null ? null : SpotRecord(sourceId: sourceId, values: row);
  }

  @override
  Future<SpotRecord> updateSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  ) async {
    final row = await client.rpc<Map<String, dynamic>>(
      'admin_upsert_spot',
      params: {
        'p_source_id': sourceId,
        'p_values': values,
        'p_base_updated_at': baseUpdatedAt,
        'p_note': note,
      },
    );
    return SpotRecord(sourceId: sourceId, values: row);
  }

  @override
  Future<String> promoteSpot(
    String sourceId,
    Map<String, dynamic> values,
    String baseUpdatedAt,
    String note,
  ) async {
    final row = await client.rpc<Map<String, dynamic>>(
      'admin_promote_spot',
      params: {
        'p_source_id': sourceId,
        'p_values': values,
        'p_base_updated_at': baseUpdatedAt,
        'p_note': note,
      },
    );
    return row['source_id'] as String;
  }

  @override
  Future<SpotRecord> createSpot(
    SpotKind kind,
    Map<String, dynamic> values,
    String note,
  ) async {
    final row = await client.rpc<Map<String, dynamic>>(
      'admin_upsert_spot',
      params: {
        'p_source_id': null,
        'p_values': {...values, 'kind': kind.name},
        'p_note': note,
      },
    );
    return SpotRecord(sourceId: row['source_id'] as String, values: row);
  }

  @override
  Future<List<NearbySpot>> nearbySpots(double lat, double lng) async {
    // About 33 m each way; the exact 15 m check runs on the result.
    const d = 0.0003;
    final community = await client
        .from('community_spots')
        .select('id,name,space_type,lat,lng')
        .neq('status', 'hidden')
        .gte('lat', lat - d)
        .lte('lat', lat + d)
        .gte('lng', lng - d)
        .lte('lng', lng + d);
    final official = await client
        .from('official_heavy_spots')
        .select('id,name,space_type,lat,lng')
        .eq('hidden', false)
        .gte('lat', lat - d)
        .lte('lat', lat + d)
        .gte('lng', lng - d)
        .lte('lng', lng + d);
    NearbySpot spot(Map<String, dynamic> r, String id) => NearbySpot(
      sourceId: id,
      name: r['name'] as String,
      spaceType: r['space_type'] as String,
      lat: (r['lat'] as num).toDouble(),
      lng: (r['lng'] as num).toDouble(),
    );
    return [
      for (final r in community) spot(r, r['id'] as String),
      for (final r in official) spot(r, 'official:${r['id']}'),
    ];
  }

  @override
  Future<Town?> town(double lat, double lng) => lookupTown(lat, lng);
}

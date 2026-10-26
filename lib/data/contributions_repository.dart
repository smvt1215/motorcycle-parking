import 'package:supabase_flutter/supabase_flutter.dart';

/// What a contribution was: a suggestion to change a spot, a report that
/// it can no longer be parked at, or a spot the rider added.
enum ContributionKind { suggestion, gone, newSpot }

/// Where a contribution stands. Reports go through review (pending,
/// accepted, rejected, closed); added spots are on the map while they wait
/// for riders (pending), confirmed, or taken off the map (hidden).
enum ContributionStatus {
  pending,
  accepted,
  rejected,
  closed,
  confirmed,
  hidden,
  unknown,
}

/// Field keys the app sends with a suggestion, as riders read them. Older
/// builds sent the label itself, or only a reason starting with it.
const contributionFieldLabels = {
  'name': '停車點名稱',
  'space_type': '格位類型',
  'fee_note': '收費資訊',
  'eligibility': '機車停放資格',
  'guide': '入口與停車指引',
  'note': '其他備註',
  'location': '位置',
  'gone': '這裡已經不能停車',
};

const _goneLabels = {'gone', '點位已不存在', '這裡已經不能停車'};

/// One row of `my_contributions()`
/// (supabase/migrations/202610260030_my_contributions.sql).
class MyContribution {
  MyContribution({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    String? cursor,
    this.spotId,
    this.spotName,
    this.field,
    this.summary,
    this.resolvedAt,
    this.resolutionKind,
    this.spotVisible = false,
    this.lat,
    this.lng,
  }) : cursor = cursor ?? createdAt.toUtc().toIso8601String();

  factory MyContribution.fromJson(Map<String, dynamic> j) {
    final field = j['field'] as String?;
    final summary = j['summary'] as String?;
    final prefix = _prefix(summary);
    final kind = j['kind'] == 'new_spot'
        ? ContributionKind.newSpot
        : _goneLabels.contains(field) || _goneLabels.contains(prefix)
        ? ContributionKind.gone
        : ContributionKind.suggestion;
    return MyContribution(
      id: j['id'] as String,
      kind: kind,
      status:
          ContributionStatus.values.asNameMap()[j['status']] ??
          ContributionStatus.unknown,
      createdAt: DateTime.parse(j['created_at'] as String).toLocal(),
      cursor: j['created_at'] as String,
      spotId: j['spot_id'] as String?,
      spotName: j['spot_name'] as String?,
      field: field,
      summary: summary,
      resolvedAt: DateTime.tryParse(j['resolved_at'] as String? ?? '')
          ?.toLocal(),
      resolutionKind: j['resolution_kind'] as String?,
      spotVisible: j['spot_visible'] == true,
      lat: (j['lat'] as num?)?.toDouble(),
      lng: (j['lng'] as num?)?.toDouble(),
    );
  }

  final String id;
  final ContributionKind kind;
  final ContributionStatus status;
  final DateTime createdAt;

  /// `created_at` exactly as the server sent it, for the next page: web
  /// builds keep only milliseconds in a [DateTime].
  final String cursor;
  final String? spotId;
  final String? spotName;
  final String? field;

  /// The rider's own summary as sent (`reason`); null for added spots.
  final String? summary;
  final DateTime? resolvedAt;

  /// Why a rejected or closed report was not used: wrong, duplicate,
  /// insufficient, outdated, abuse or other; null when unclassified. The
  /// admin's own note is never sent to riders.
  final String? resolutionKind;

  /// Whether the spot is on the public map now, so its details can open.
  final bool spotVisible;
  final double? lat, lng;

  bool get canOpen => spotVisible && spotId != null && lat != null;

  /// What was sent, in the rider's words: 新增停車點, 回報這裡已經不能停車,
  /// or 建議修改 plus the field.
  String get action => switch (kind) {
    ContributionKind.newSpot => '新增停車點',
    ContributionKind.gone => '回報這裡已經不能停車',
    ContributionKind.suggestion => switch (fieldLabel) {
      final label? => '建議修改$label',
      null => '提出修改建議',
    },
  };

  String? get fieldLabel {
    final key = field ?? _prefix(summary);
    if (key == null) return null;
    return contributionFieldLabels[key] ??
        (contributionFieldLabels.containsValue(key) ? key : null);
  }

  /// The summary without the field label it starts with, since [action]
  /// already says which field it was.
  String? get detail {
    final text = summary?.trim();
    if (text == null || text.isEmpty) return null;
    final cut = text.indexOf('：');
    final rest = cut > 0 && cut <= 12 ? text.substring(cut + 1).trim() : text;
    return rest.isEmpty ? null : rest;
  }

  static String? _prefix(String? summary) {
    final cut = summary?.indexOf('：') ?? -1;
    return cut > 0 && cut <= 12 ? summary!.substring(0, cut) : null;
  }
}

/// One page of contributions; [hasMore] when the server filled the page.
class ContributionPage {
  const ContributionPage(this.items, {required this.hasMore});
  final List<MyContribution> items;
  final bool hasMore;
}

class ContributionsRepository {
  ContributionsRepository(this.client);
  final SupabaseClient? client;

  static const pageSize = 20;

  /// The signed-in rider's contributions, newest first; pass the last row
  /// of the previous page as [after] to continue.
  Future<ContributionPage> load({MyContribution? after}) async {
    final backend = client;
    if (backend == null) {
      return const ContributionPage([], hasMore: false);
    }
    final rows = await backend.rpc<List<dynamic>>(
      'my_contributions',
      params: {
        'p_before_at': ?after?.cursor,
        'p_before_id': ?after?.id,
        'p_limit': pageSize,
      },
    );
    final items = [
      for (final row in rows)
        MyContribution.fromJson((row as Map).cast<String, dynamic>()),
    ];
    return ContributionPage(items, hasMore: items.length == pageSize);
  }
}

/// Riders' on-site sightings (#154, REALTIME_AVAILABILITY_UI_PLAN §5.2):
/// what riders saw at a spot in the last 30 minutes, as the server judged
/// it (`spot_sightings`, decision 50). Kept apart from official counts: a
/// sighting is never a count and never replaces one.
library;

/// What a rider reports from the spot. [wire] is what the server stores.
enum SightingKind {
  available('available', '剛看到有空位'),
  full('full', '現場停滿'),
  closed('closed', '無法停車／施工中');

  const SightingKind(this.wire, this.label);
  final String wire;
  final String label;
}

/// What riders' recent sightings add up to at a spot.
enum SightingState {
  /// Credible riders agree (by weight, at least 70%) there were spaces.
  available,

  /// They agree it was full.
  full,

  /// They disagree: 近期回報不一致. Neither side is shown.
  conflict,
}

/// One spot's result from `spot_sightings`: no riders, no single sightings.
class RiderSighting {
  const RiderSighting({
    required this.spotId,
    required this.state,
    required this.latestAt,
    required this.since,
  });

  final String spotId;
  final SightingState state;

  /// The newest sighting behind [state] (any sighting for a conflict).
  final DateTime latestAt;

  /// The oldest sighting considered.
  final DateTime since;

  /// A `spot_sightings` row, or null when it does not parse.
  static RiderSighting? fromRow(Map<String, dynamic> row) {
    final spotId = row['spot_id'], state = row['state'];
    final latest = row['latest_at'], since = row['since'];
    final parsed = SightingState.values.asNameMap()[state];
    if (spotId is! String || parsed == null) return null;
    final latestAt = latest is String ? DateTime.tryParse(latest) : null;
    final sinceAt = since is String ? DateTime.tryParse(since) : null;
    if (latestAt == null) return null;
    return RiderSighting(
      spotId: spotId,
      state: parsed,
      latestAt: latestAt,
      since: sinceAt ?? latestAt,
    );
  }
}

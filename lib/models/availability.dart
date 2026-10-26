/// Live space counts, kept apart from [ParkingSpot] so a count that changes
/// every few minutes never rewrites the static spot or its favorites copy
/// (REALTIME_AVAILABILITY_UI_PLAN.md §7.1).
library;

/// Whose spaces a count describes. A scooter count never stands for heavy
/// bikes, and a car count is never a heavy-bike count, even where heavy
/// bikes may use car bays.
enum AvailabilityVehicle { scooter, heavy, car }

/// How far a count can be trusted right now (plan §5.1).
enum AvailabilityStatus {
  /// Within the source's update window: the number may be shown and used.
  fresh,

  /// Past the fresh window: the last number stays, marked as delayed, and
  /// never counts as a free space.
  delayed,

  /// Past the longest window: the space is unknown again.
  stale,

  /// No count for this vehicle: no field, `null`, `-1` (TDX), `-9`
  /// (Taipei, New Taipei) or no capacity. Never zero.
  unavailable,

  /// The source says the lot is closed; not the same as full.
  suspended,

  /// The count contradicts itself (more free than total, another negative
  /// code, a future time, zero for hours): shown as unknown.
  invalid,
}

/// A source's freshness windows (availability-coverage.md §2). Taipei's
/// parking office writes about every five minutes: fresh for two cycles,
/// delayed up to twenty minutes.
class AvailabilityWindow {
  const AvailabilityWindow({required this.fresh, required this.stale});
  final Duration fresh, stale;

  static const taipei = AvailabilityWindow(
    fresh: Duration(minutes: 10),
    stale: Duration(minutes: 20),
  );
}

/// Codes sources use for "no data", read as [AvailabilityStatus.unavailable]
/// rather than as a count. Any other negative number is invalid.
const availabilityNoDataCodes = {-1, -9};

/// A lot that reads zero for this long while it has capacity is suspect
/// (coverage §2 rule 4): shown as unknown, never as full.
const availabilityLongZero = Duration(hours: 2);

/// Clock skew allowed before a source time counts as in the future.
const _skew = Duration(minutes: 1);

/// One source's latest count for one vehicle at one spot.
class AvailabilitySnapshot {
  const AvailabilitySnapshot({
    required this.spotId,
    required this.vehicle,
    required this.provider,
    required this.window,
    this.total,
    this.available,
    this.sourceUpdatedAt,
    this.fetchedAt,
    this.suspended = false,
    this.zeroSince,
  });

  final String spotId;
  final AvailabilityVehicle vehicle;

  /// The publisher shown beside the time, e.g. 「臺北市停管處」.
  final String provider;
  final AvailabilityWindow window;

  /// Capacity and free spaces as the source sent them, special codes
  /// included; [status] decides what they mean.
  final int? total, available;

  /// When the source produced the count. Freshness reads only this, never
  /// [fetchedAt]: a count fetched a second ago may be an hour old.
  final DateTime? sourceUpdatedAt;
  final DateTime? fetchedAt;

  /// The source marks the lot closed.
  final bool suspended;

  /// Since when the count has read zero without a break, if it does.
  final DateTime? zeroSince;

  AvailabilityStatus status(DateTime now) {
    if (suspended) return AvailabilityStatus.suspended;
    final available = this.available, total = this.total;
    if (available == null || availabilityNoDataCodes.contains(available)) {
      return AvailabilityStatus.unavailable;
    }
    // No capacity for this vehicle means no such bays, not a full lot.
    if (total == null ||
        total == 0 ||
        availabilityNoDataCodes.contains(total)) {
      return AvailabilityStatus.unavailable;
    }
    if (available < 0 || total < 0 || available > total) {
      return AvailabilityStatus.invalid;
    }
    final at = sourceUpdatedAt;
    if (at == null) return AvailabilityStatus.unavailable;
    if (at.isAfter(now.add(_skew))) return AvailabilityStatus.invalid;
    if (available == 0 &&
        zeroSince != null &&
        now.difference(zeroSince!) >= availabilityLongZero) {
      return AvailabilityStatus.invalid;
    }
    final age = now.difference(at);
    if (age <= window.fresh) return AvailabilityStatus.fresh;
    if (age <= window.stale) return AvailabilityStatus.delayed;
    return AvailabilityStatus.stale;
  }

  /// Minutes since the source time, for 「更新延遲 N 分鐘」.
  int ageMinutes(DateTime now) =>
      sourceUpdatedAt == null ? 0 : now.difference(sourceUpdatedAt!).inMinutes;

  /// The capacity when it is a real one, for 「共 N 格」.
  int? get capacity => total != null && total! > 0 ? total : null;
}

/// Every count known for one spot, by vehicle.
class SpotAvailability {
  const SpotAvailability(this.snapshots);
  final List<AvailabilitySnapshot> snapshots;

  static const none = SpotAvailability([]);

  AvailabilitySnapshot? of(AvailabilityVehicle vehicle) =>
      snapshots.where((s) => s.vehicle == vehicle).firstOrNull;

  bool get isEmpty => snapshots.isEmpty;
}

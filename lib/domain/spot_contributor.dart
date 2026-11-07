import '../data/hidden_riders.dart';
import '../models/parking.dart';

/// Who added a spot, as #280's menus and filters read it. Only reads
/// [ParkingSpot]; the model belongs to the data layer.

/// The public contributor handle; null when the spot has none (never had a
/// public name, an admin or import, a deleted account, an official spot).
String? riderHandle(ParkingSpot spot) {
  final handle = spot.contributorHandle;
  return spot.isOfficial || handle == null || handle.isEmpty ? null : handle;
}

/// Whether the signed-in account added [spot] (`is_own`); false for
/// guests and whenever the backend does not say.
bool isOwnSpot(ParkingSpot spot) => spot.isOwn;

/// Whether a rider, not an admin or an import, added [spot].
bool addedByRider(ParkingSpot spot) =>
    !spot.isOfficial &&
    spot.contributorRole != 'admin' &&
    spot.contributorRole != 'import' &&
    spot.source != 'import';

/// The rider's public name as the details show it; empty when there is
/// none or it looks like an email (an account id, not a public name).
String publicRiderName(ParkingSpot spot) {
  if (!addedByRider(spot)) return '';
  final name = spot.contributorName.trim();
  return name.contains('@') ? '' : name;
}

/// The ⋯ menu beside 資料來源 (P17a ⑤, P17d ②); [show] false means no ⋯.
typedef SpotMenu = ({bool show, bool byRider, bool hide, bool unhide});

/// [handle] and [own] override the spot's own: [AppStore] knows better for
/// a snapshot that cannot keep them, or that an earlier session read.
SpotMenu spotMenu(
  ParkingSpot spot,
  HiddenRiders hidden, {
  String? handle,
  bool? own,
}) {
  if (spot.isOfficial || (own ?? isOwnSpot(spot))) {
    return (show: false, byRider: false, hide: false, unhide: false);
  }
  handle ??= riderHandle(spot);
  final isHidden = hidden.isHidden(handle);
  return (
    show: true,
    byRider: addedByRider(spot),
    hide: handle != null && handle.isNotEmpty && !isHidden,
    unhide: isHidden,
  );
}

/// The fields of [spot] held for review after a report (`content_held`:
/// `rider_name`, `spot_name`, `text`; #280 L3). Empty until the model
/// reads it: [ParkingSpot] has no such field yet (L3 left it out of the
/// model), so nothing shows.
Set<String> contentHeld(ParkingSpot spot) => const {};

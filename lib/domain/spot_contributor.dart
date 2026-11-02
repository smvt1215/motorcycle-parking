import '../data/hidden_riders.dart';
import '../models/parking.dart';

/// Who added a spot, as #280's menus and filters read it. Only reads
/// [ParkingSpot]; the model belongs to the data layer.

/// The public contributor handle; null when the spot has none (never had a
/// public name, an admin or import, a deleted account, an official spot).
String? riderHandle(ParkingSpot spot) => null;

/// Whether the signed-in account added [spot] (`is_own`); false for
/// guests and whenever the backend does not say.
bool isOwnSpot(ParkingSpot spot) => false;

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

/// Whether [spot] can be reported as inappropriate: community content
/// (rider-added, admin-added or imported), not official data and not the
/// rider's own spot (P17a ⑤, P17b).
bool canReportContent(ParkingSpot spot) => !spot.isOfficial && !isOwnSpot(spot);

/// The ⋯ menu beside 資料來源 (P17a ⑤, P17d ②); [show] false means no ⋯.
typedef SpotMenu = ({bool show, bool byRider, bool hide, bool unhide});

/// [handle] overrides the spot's own, for a favourite's snapshot whose
/// handle was looked up.
SpotMenu spotMenu(ParkingSpot spot, HiddenRiders hidden, {String? handle}) {
  if (!canReportContent(spot)) {
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

/// Whether the map, its clusters, search and nearby lists leave [spot] out.
bool hiddenFromLists(ParkingSpot spot, HiddenRiders hidden) =>
    !isOwnSpot(spot) && hidden.isHidden(riderHandle(spot));

/// The fields of [spot] held for review after a report (`content_held`:
/// `rider_name`, `spot_name`, `text`; #280 L3). Empty until the model
/// reads it.
Set<String> contentHeld(ParkingSpot spot) => const {};

/// Whether the contributor, looking at their own spot, should see that
/// [field] is under review (P17b ⑪); others see it already hidden.
bool heldForOwner(ParkingSpot spot, String field) =>
    isOwnSpot(spot) && contentHeld(spot).contains(field);

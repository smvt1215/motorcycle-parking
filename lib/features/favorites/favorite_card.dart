import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../domain/favorites_display.dart';
import '../../domain/four_sign.dart';
import '../../domain/four_sign_display.dart';
import '../../domain/hidden_riders_display.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/four_sign_plates.dart';
import '../hidden_riders/spot_more_menu.dart' show UnhideButton;
import '../map/spot_fees.dart' show MinuteTicker;
import '../map/spot_preview.dart' show previewDistance, previewSubtitle;
import '../map/spot_sheet.dart' show showSpot;

/// A favourite with how far it is from the device; null until located.
typedef FavoriteEntry = ({ParkingSpot spot, double? meters});

/// The favourites nearest first once the device is located (P6
/// 「依距離排序」); before that, in the order they were saved, with no
/// distance (a map centre is no measure of how far the rider is).
List<FavoriteEntry> favoritesByDistance(AppStore store) {
  final entries = [
    for (final s in store.favorites)
      (
        spot: s,
        meters: store.located
            ? distanceMeters(store.lat, store.lng, s.lat, s.lng)
            : null,
      ),
  ];
  if (store.located) {
    // List.sort is not stable; the saved order breaks ties.
    final order = {for (final (i, e) in entries.indexed) e.spot.id: i};
    entries.sort((a, b) {
      final by = a.meters!.compareTo(b.meters!);
      return by != 0 ? by : order[a.spot.id]!.compareTo(order[b.spot.id]!);
    });
  }
  return entries;
}

/// One favourite as a card (canvas v157 P4, P6): its name, distance and,
/// with [detailed], type and region, then the four signs as compact
/// plates. Tapping it opens the spot. [trailing] sits beside the name
/// (P6's bookmark).
class FavoriteCard extends StatelessWidget {
  const FavoriteCard({
    super.key,
    required this.store,
    required this.entry,
    this.detailed = false,
    this.trailing,
    this.padding = EdgeInsets.zero,
  });
  final AppStore store;
  final FavoriteEntry entry;
  final bool detailed;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final spot = entry.spot;
    final meters = entry.meters;
    final quiet = text.bodySmall?.copyWith(
      fontSize: 13,
      color: colors.onSurfaceVariant,
    );
    final name = Text(
      spot.name,
      style: text.titleMedium?.copyWith(fontWeight: FontWeight.w500),
    );
    final header = detailed
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              name,
              const SizedBox(height: 2),
              Text(previewSubtitle(spot, meters: meters), style: quiet),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: name),
              if (meters != null) ...[
                const SizedBox(width: 12),
                Text(previewDistance(meters), style: quiet),
              ],
            ],
          );
    // A hidden rider's favourite stays, faded and marked (P17d ①).
    final handle = store.riderHidden(spot) ? store.handleOf(spot) : null;
    return InkWell(
      onTap: () => showSpot(context, store, spot),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: handle == null ? 1 : .6,
              child: _body(context, header, spot),
            ),
            if (handle != null)
              _HiddenNote(
                store: store,
                handle: handle,
                name: store.hiddenRiders.byHandle(handle)?.name ?? '',
              ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, Widget header, ParkingSpot spot) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(top: trailing == null ? 0 : 6),
              child: header,
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 8),
      // Plates read the clock: a time slot opening or closing turns
      // them on the minute, as on the details sheet.
      MinuteTicker(
        clock: store.clock,
        builder: (context, now) => FourSignPlates(
          key: ValueKey('favorite-plates-${spot.id}'),
          compact: true,
          // Each plate opens the spot, as the card does: a plate is
          // a button, so it takes the tap itself.
          onTap: (_) => showSpot(context, store, spot),
          plates: fourSignPlates(
            fourSign(
              spot,
              store.vehicle,
              store.rules,
              now: now,
              availability: store.availabilityOf(spot),
              decision: store.decide(spot),
            ),
            now,
          ),
        ),
      ),
    ],
  );
}

/// P17d ①: 已隱藏這位車友（名稱）。地圖上不會顯示這個點。 with 解除隱藏.
class _HiddenNote extends StatelessWidget {
  const _HiddenNote({
    required this.store,
    required this.handle,
    required this.name,
  });
  final AppStore store;
  final String handle, name;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        key: ValueKey('favorite-hidden-$handle'),
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Row(
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  hiddenFavoriteNote(name),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 8),
              UnhideButton(store: store, handle: handle, name: name),
            ],
          ),
        ),
      ),
    );
  }
}

/// P6's bookmark: removes the favourite.
class UnfavoriteButton extends StatelessWidget {
  const UnfavoriteButton({super.key, required this.store, required this.spot});
  final AppStore store;
  final ParkingSpot spot;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: unfavoriteLabel(spot.name),
    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
    icon: const Icon(Icons.bookmark),
    color: Theme.of(context).colorScheme.primary,
    onPressed: () => runAction(context, () => store.toggleFavorite(spot)),
  );
}

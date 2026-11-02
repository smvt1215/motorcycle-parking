/// Where the contributor handles of saved favourites come from (#280,
/// P17d ①). Favourite snapshots never keep the handle, so marking a hidden
/// rider's favourite needs the backend's batch read (`spots_by_ids`, T280
/// L2). Replaceable so tests and that API can plug in.
abstract interface class FavoriteHandles {
  /// The handle of each spot in [ids] that has one, by spot id.
  Future<Map<String, String>> handlesFor(List<String> ids);
}

/// Until `spots_by_ids` ships: no handles, so no favourite is marked.
class PendingFavoriteHandles implements FavoriteHandles {
  const PendingFavoriteHandles();
  @override
  Future<Map<String, String>> handlesFor(List<String> ids) async => const {};
}

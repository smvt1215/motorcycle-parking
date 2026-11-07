import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show ApiV1Client;

/// What a saved favourite's snapshot cannot keep (#280): the contributor
/// handle and whether the signed-in account added it.
typedef FavoriteFacts = ({String? handle, bool isOwn});

/// Where [FavoriteFacts] come from (P17d ①). Favourite snapshots keep
/// neither, so the spots are read again (`api_v1.spots_by_ids`).
/// Replaceable so tests can plug in.
abstract interface class FavoriteHandles {
  /// The facts of each spot in [ids] still readable, by spot id.
  Future<Map<String, FavoriteFacts>> handlesFor(List<String> ids);
}

/// No handles, so no favourite is marked: the sample build, which has no
/// backend.
class NoFavoriteHandles implements FavoriteHandles {
  const NoFavoriteHandles();
  @override
  Future<Map<String, FavoriteFacts>> handlesFor(List<String> ids) async =>
      const {};
}

/// `api_v1.spots_by_ids(ids)`: at most [batch] ids a call (more is
/// `request.too_many_ids`), answering the rows a viewport returns.
/// Unknown or unreadable ids (e.g. `tdx:`) come back as nothing.
class RemoteFavoriteHandles implements FavoriteHandles {
  RemoteFavoriteHandles(SupabaseClient client) : api = ApiV1Client(client);
  final ApiV1Client api;
  static const batch = 200;

  @override
  Future<Map<String, FavoriteFacts>> handlesFor(List<String> ids) async {
    final facts = <String, FavoriteFacts>{};
    for (var i = 0; i < ids.length; i += batch) {
      final end = i + batch > ids.length ? ids.length : i + batch;
      final found = await api.spotsByIds(ids: ids.sublist(i, end));
      for (final spot in found.spots) {
        final handle = spot.contributorHandle;
        facts[spot.id] = (
          handle: handle == null || handle.isEmpty ? null : handle,
          isOwn: spot.isOwn ?? false,
        );
      }
    }
    return facts;
  }
}

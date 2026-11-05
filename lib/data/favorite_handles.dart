import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show ApiV1Client;

/// Where the contributor handles of saved favourites come from (#280,
/// P17d ①). Favourite snapshots never keep the handle, so marking a hidden
/// rider's favourite reads the spots again (`api_v1.spots_by_ids`).
/// Replaceable so tests can plug in.
abstract interface class FavoriteHandles {
  /// The handle of each spot in [ids] that has one, by spot id.
  Future<Map<String, String>> handlesFor(List<String> ids);
}

/// No handles, so no favourite is marked: the sample build, which has no
/// backend.
class NoFavoriteHandles implements FavoriteHandles {
  const NoFavoriteHandles();
  @override
  Future<Map<String, String>> handlesFor(List<String> ids) async => const {};
}

/// `api_v1.spots_by_ids(ids)`: at most [batch] ids a call (more is
/// `request.too_many_ids`), answering the rows a viewport returns.
/// Unknown or unreadable ids (e.g. `tdx:`) come back as nothing.
class RemoteFavoriteHandles implements FavoriteHandles {
  RemoteFavoriteHandles(SupabaseClient client) : api = ApiV1Client(client);
  final ApiV1Client api;
  static const batch = 200;

  @override
  Future<Map<String, String>> handlesFor(List<String> ids) async {
    final handles = <String, String>{};
    for (var i = 0; i < ids.length; i += batch) {
      final end = i + batch > ids.length ? ids.length : i + batch;
      final found = await api.spotsByIds(ids: ids.sublist(i, end));
      for (final spot in found.spots) {
        final handle = spot.contributorHandle;
        if (handle != null && handle.isNotEmpty) handles[spot.id] = handle;
      }
    }
    return handles;
  }
}

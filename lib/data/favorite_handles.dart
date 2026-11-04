import 'package:supabase_flutter/supabase_flutter.dart';

import '../api/v1/api_v1.g.dart' show ApiV1Exception;

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

/// Whether [RemoteFavoriteHandles] is used; off until `spots_by_ids` ships.
const spotsByIdsEnabled = bool.fromEnvironment('SPOTS_BY_IDS');

/// `api_v1.spots_by_ids(ids)`: at most [batch] ids a call (more is
/// `request.too_many_ids`), answering `{spots: [Spot]}` with the rows a
/// viewport returns. Unknown or unreadable ids (e.g. `tdx:`) come back
/// as nothing.
class RemoteFavoriteHandles implements FavoriteHandles {
  RemoteFavoriteHandles(this.client);
  final SupabaseClient client;
  static const batch = 200;

  // TODO(#280): use the generated ApiV1Client method once spots_by_ids is
  // in supabase/api/v1/api_v1.json (backend #315).
  Future<Object?> _call(List<String> ids) async {
    try {
      return await client
          .schema('api_v1')
          .rpc<Object?>('spots_by_ids', params: {'ids': ids});
    } on PostgrestException catch (e) {
      throw ApiV1Exception(
        code: e.code,
        message: e.message,
        details: e.details,
      );
    }
  }

  @override
  Future<Map<String, String>> handlesFor(List<String> ids) async {
    final handles = <String, String>{};
    for (var i = 0; i < ids.length; i += batch) {
      final body = await _call(
        ids.sublist(i, i + batch > ids.length ? ids.length : i + batch),
      );
      handles.addAll(spotHandles(body));
    }
    return handles;
  }
}

/// The `contributor_handle` of each row in a `{spots: [...]}` answer.
Map<String, String> spotHandles(Object? body) => {
  if (body case {'spots': final List<dynamic> rows})
    for (final row in rows)
      if (row
          case {
            'id': final String id,
            'contributor_handle': final String handle,
          }
          when handle.isNotEmpty)
        id: handle,
};

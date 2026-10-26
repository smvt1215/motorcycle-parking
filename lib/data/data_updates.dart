import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A dataset the app caches; the backend keeps a `data_versions` row for
/// each (migration 202610260040).
enum DataSet { spots, rules }

/// One `data_versions` row: the dataset and how many times it changed.
typedef DataVersion = ({DataSet set, int version});

/// Parses a `data_versions` row; null for a key this build does not know.
/// The bigint arrives as a JSON number, or as a string from a client that
/// keeps 64-bit values exact.
DataVersion? dataVersionFromRow(Map<String, dynamic> row) {
  final set = DataSet.values.asNameMap()[row['key']];
  final raw = row['version'];
  final version = switch (raw) {
    num _ => raw.toInt(),
    String _ => int.tryParse(raw),
    _ => null,
  };
  if (set == null || version == null) return null;
  return (set: set, version: version);
}

/// Tells the app that spots or rules changed on the backend, so an open app
/// reloads instead of showing what it loaded until the next camera move.
///
/// Triggers bump the dataset's `data_versions` row on every write and
/// Realtime streams the bumped row to [watch]. A backgrounded app can miss
/// the stream, so [current] reads the rows directly when the app resumes.
/// Both are quiet in demo mode (no backend).
class DataUpdates {
  DataUpdates(this.client);
  final SupabaseClient? client;

  /// Versions as the backend bumps them, for as long as someone listens.
  /// [onSubscribed] runs each time the channel joins, including a rejoin
  /// after a dropped connection, when changes may have been missed.
  Stream<DataVersion> watch({void Function()? onSubscribed}) {
    final backend = client;
    if (backend == null) return const Stream.empty();
    RealtimeChannel? channel;
    late final StreamController<DataVersion> controller;
    controller = StreamController<DataVersion>(
      onListen: () {
        channel = backend.channel('data_versions')
          ..onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'data_versions',
            callback: (payload) {
              final version = dataVersionFromRow(payload.newRecord);
              if (version != null && !controller.isClosed) {
                controller.add(version);
              }
            },
          )
          ..subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              onSubscribed?.call();
            } else if (status != RealtimeSubscribeStatus.closed) {
              // No retry here: the resume and rejoin checks still compare
              // versions. Logged so a silent staging stays explainable.
              debugPrint('data_versions 訂閱未成功（$status）：$error');
            }
          });
      },
      onCancel: () async {
        final open = channel;
        channel = null;
        if (open != null) await backend.removeChannel(open);
      },
    );
    return controller.stream;
  }

  /// Every dataset's version right now.
  Future<List<DataVersion>> current() async {
    final backend = client;
    if (backend == null) return const [];
    final rows = await backend.from('data_versions').select('key,version');
    return [for (final row in rows) ?dataVersionFromRow(row)];
  }
}

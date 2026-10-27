/// How riders' sightings read in the app (#154; realtime availability
/// canvas, boards 路邊靜態與騎士回報 and 狀態總表). A sighting is never a
/// count: nothing here produces 「剩 N」, and it never replaces an official
/// count.
library;

import '../models/rider_sighting.dart';

/// Sightings older than this are not shown at all.
const sightingShownFor = Duration(minutes: 30);

/// Within this the map marks the spot with the small rider badge.
const sightingBadgeFor = Duration(minutes: 15);

/// Clock skew allowed before a time counts as in the future.
const _skew = Duration(minutes: 1);

const sightingCaption = '車友目擊，不是官方即時資料；抵達時可能已變。';

/// The detail sheet's row: a headline and the line under it.
typedef SightingLine = ({String title, String caption});

/// 「8 分鐘前有騎士回報『有空位』」 within 30 minutes, 「近期回報不一致」
/// when riders disagree, or null.
SightingLine? sightingLine(RiderSighting? sighting, DateTime now) {
  if (sighting == null || !_recent(sighting.latestAt, now, sightingShownFor)) {
    return null;
  }
  if (sighting.state == SightingState.conflict) {
    final minutes = now.difference(sighting.since).inSeconds / 60;
    return (
      title: '近期回報不一致',
      caption: '${minutes.ceil().clamp(1, 30)} 分鐘內有人說有空位、有人說停滿',
    );
  }
  final age = now.difference(sighting.latestAt);
  final when = age.inMinutes < 1 ? '剛剛' : '${age.inMinutes} 分鐘前';
  final what = sighting.state == SightingState.available ? '有空位' : '停滿';
  return (title: '$when有騎士回報「$what」', caption: sightingCaption);
}

/// Whether the map shows the 16 px rider badge: an agreed sighting within
/// 15 minutes. A conflict has none.
bool sightingBadge(RiderSighting? sighting, DateTime now) =>
    sighting != null &&
    sighting.state != SightingState.conflict &&
    _recent(sighting.latestAt, now, sightingBadgeFor);

bool _recent(DateTime at, DateTime now, Duration within) {
  final age = now.difference(at);
  return age <= within && age >= -_skew;
}

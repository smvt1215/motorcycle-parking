import 'dart:ui';

/// Which of a marker's availability pills to draw.
enum CapsuleShow {
  /// Every pill: the rider's own count and any car-bay count.
  full,

  /// Only the rider's own count: the marker is crowded.
  primary,

  /// No pill: it would cover the selected marker's pills.
  none,
}

/// A marker and its pills, in screen pixels.
class CapsuleItem {
  const CapsuleItem({
    required this.id,
    required this.center,
    required this.fullWidth,
    this.primaryWidth = 0,
    this.markerSize = 38,
    this.height = 24,
  });
  final String id;

  /// The marker's centre on screen.
  final Offset center;

  /// Width of the whole row of pills, and of the rider's own pill alone;
  /// zero when there is none.
  final double fullWidth, primaryWidth;
  final double markerSize, height;
}

/// Gap between the pills' lower edge and the marker's top edge.
const capsuleGap = 10.0;

Rect _marker(CapsuleItem item) => Rect.fromCenter(
  center: item.center,
  width: item.markerSize,
  height: item.markerSize,
);

/// The pills' box above the marker, centred on it; null without pills.
Rect? capsuleRect(CapsuleItem item, double width) => width <= 0
    ? null
    : Rect.fromLTWH(
        item.center.dx - width / 2,
        item.center.dy - item.markerSize / 2 - capsuleGap - item.height,
        width,
        item.height,
      );

Rect _bounds(CapsuleItem item, double width) {
  final pills = capsuleRect(item, width);
  return pills == null ? _marker(item) : _marker(item).expandToInclude(pills);
}

bool _overlaps(Rect a, Rect b) => a.overlaps(b);

/// Which pills each marker shows (MapDensity board). A marker whose full
/// set would touch a neighbour keeps only the rider's own count. The
/// [selected] marker always shows its full set, and every other marker's
/// pills that would touch it (its pills and marker) are hidden; farther
/// ones stay. Pure: screen positions in, decisions out.
Map<String, CapsuleShow> layoutCapsules(
  List<CapsuleItem> items, {
  String? selected,
}) {
  final full = {
    for (final item in items) item.id: _bounds(item, item.fullWidth),
  };
  final result = <String, CapsuleShow>{};
  for (final item in items) {
    if (item.id == selected) {
      result[item.id] = CapsuleShow.full;
      continue;
    }
    final crowded = items.any(
      (other) =>
          other.id != item.id && _overlaps(full[item.id]!, full[other.id]!),
    );
    result[item.id] = crowded ? CapsuleShow.primary : CapsuleShow.full;
  }
  final chosen = items.where((item) => item.id == selected).firstOrNull;
  if (chosen != null) {
    final area = full[chosen.id]!;
    for (final item in items) {
      if (item.id == chosen.id) continue;
      final width = result[item.id] == CapsuleShow.full
          ? item.fullWidth
          : item.primaryWidth;
      final pills = capsuleRect(item, width);
      if (pills != null && _overlaps(pills, area)) {
        result[item.id] = CapsuleShow.none;
      }
    }
  }
  return result;
}

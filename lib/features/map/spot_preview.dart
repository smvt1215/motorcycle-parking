import 'dart:math' as math;

import '../../domain/four_sign.dart';
import '../../domain/four_sign_display.dart';
import '../../domain/sighting_display.dart' show ClosureLine, ClosureLineTone;
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/detail_tokens.dart';
import '../../ui/four_sign_plates.dart';
import '../../ui/text_wrap.dart';
import 'spot_details.dart';

/// 「650 m」, 「1.1 km」 (Main, A3).
String previewDistance(double meters) => meters < 1000
    ? '${(meters / 10).round() * 10} m'
    : '${(meters / 1000).toStringAsFixed(1)} km';

/// The subtitle under a spot's name: type, region, distance (Main).
String previewSubtitle(ParkingSpot spot, {double? meters}) => [
  facilitySummary(spot),
  regionSummary(spot),
  if (meters != null) previewDistance(meters),
].where((s) => s.isNotEmpty).join('　');

/// A spot's preview on the map (canvas Ver.143 Main, A1, A3, A5, A6): its
/// name, type and distance with 收藏, 分享 and 關閉 beside it (user
/// decision 2026-10-31), then the four signs. The action bar is
/// [SpotPreviewActions], pinned by the sheet. Tapping a plate calls
/// [onPlate], which opens the details at that section.
class SpotPreview extends StatelessWidget {
  const SpotPreview({
    super.key,
    required this.spot,
    required this.plates,
    required this.subtitle,
    required this.favorite,
    required this.onFavorite,
    required this.onShare,
    required this.onClose,
    this.onPlate,
    this.titleNote,
    this.besideRow,
    this.disagrees = false,
    this.closureLines = const [],
  });
  final ParkingSpot spot;

  /// Riders' reports that nobody can park (A7d ①②), under the plates.
  final List<ClosureLine> closureLines;

  /// The report beside an official count, or the lapsed count beside a
  /// report (A11).
  final SeatBesideRow? besideRow;

  /// Show [riderDisagreesNote] under it (A11 card 4).
  final bool disagrees;

  /// A line under the name (P17b ⑪: the contributor's own name held for
  /// review).
  final Widget? titleNote;
  final List<SignPlate> plates;
  final String subtitle;
  final bool favorite;
  final VoidCallback onFavorite, onClose;
  final Future<void> Function(BuildContext) onShare;
  final ValueChanged<FourSignFace>? onPlate;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The name never truncates (A5).
                    Text(
                      spot.name,
                      style: text.titleLarge?.copyWith(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    ?titleNote,
                    const SizedBox(height: 2),
                    // 臺北市中山區 stays on one line (#467).
                    KeepGroupsText(
                      subtitle,
                      key: const ValueKey('spot-subtitle'),
                      style: text.bodySmall?.copyWith(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: favorite ? '取消收藏' : '收藏停車點',
              onPressed: onFavorite,
              icon: Icon(favorite ? Icons.bookmark : Icons.bookmark_outline),
              color: colors.primary,
            ),
            Builder(
              builder: (buttonContext) => IconButton(
                tooltip: '分享停車點',
                onPressed: () =>
                    runAction(buttonContext, () => onShare(buttonContext)),
                icon: Icon(isCupertino ? Icons.ios_share : Icons.share),
                color: colors.onSurfaceVariant,
              ),
            ),
            IconButton(
              tooltip: '關閉詳情',
              onPressed: onClose,
              style: IconButton.styleFrom(
                backgroundColor: colors.surfaceContainerHighest,
              ),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 12),
        FourSignPlates(
          key: const ValueKey('spot-four-sign'),
          plates: plates,
          onTap: onPlate,
        ),
        for (final (i, line) in closureLines.indexed) ...[
          const SizedBox(height: 8),
          ClosureLineView(key: ValueKey('closure-line-$i'), line: line),
        ],
        if (besideRow case final row?) ...[
          const SizedBox(height: 8),
          SeatBesideLine(row: row),
        ],
        if (disagrees) ...[const SizedBox(height: 8), const _DisagreesNote()],
      ],
    );
  }
}

/// What stands beside the 有沒有位 answer (A11): the riders' report with its
/// meter, or the official count past its window, tagged with whose it is.
class SeatBesideLine extends StatelessWidget {
  const SeatBesideLine({super.key, required this.row});
  final SeatBesideRow row;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Semantics(
      container: true,
      label: row.semantics,
      excludeSemantics: true,
      child: Container(
        key: const ValueKey('seat-beside-row'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.chip,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            if (row.official)
              Icon(Icons.history, size: 18, color: c.muted)
            else
              RiderMeters(levels: row.meters, ink: c.ink, paper: c.chip),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                row.text,
                style: TextStyle(fontSize: 13, color: c.ink, height: 1.4),
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: row.official ? c.ink : c.border),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                row.tag,
                style: TextStyle(fontSize: 11, color: c.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A line about riders' reports that nobody can park (A7d): the works
/// sign amber while 能不能停 still stands, red once riders closed the
/// spot; an info sign for how it ends.
class ClosureLineView extends StatelessWidget {
  const ClosureLineView({super.key, required this.line});
  final ClosureLine line;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final (icon, color) = switch (line.tone) {
      ClosureLineTone.report => (Icons.construction, c.conditional),
      ClosureLineTone.closed => (Icons.construction, c.denied),
      ClosureLineTone.info => (Icons.info_outline, c.muted),
    };
    return Semantics(
      container: true,
      label: line.semantics,
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                line.text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: line.tone == ClosureLineTone.info ? c.muted : c.ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DisagreesNote extends StatelessWidget {
  const _DisagreesNote();

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Container(
      key: const ValueKey('seat-disagrees'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.conditionalTint,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: c.conditional),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              riderDisagreesNote,
              style: TextStyle(fontSize: 13, color: c.conditional, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// The action bar of the preview and the full page (A15a–d): 導航到入口 (a
/// street spot: 導航), then 回報現場狀況 and 修改建議, always one row. It
/// stands still when it fits, 導航 taking the width left over; a row a
/// little too wide tightens its buttons' sides rather than scroll a few
/// points. Wider than that the three slide together, 導航 first and not
/// held in place, the cut button at the right edge fading out as the hint.
/// A null [onReport] leaves 回報現場狀況 out, where the rider has nothing
/// to report on (see `sightingPlaces`).
class SpotPreviewActions extends StatefulWidget {
  const SpotPreviewActions({
    super.key,
    required this.street,
    required this.onNavigate,
    this.onReport,
    this.onSuggest,
    this.navigateSecondary = false,
    this.edge = 0,
  });
  final bool street;

  /// 導航 in the secondary style, where no motorcycle may park (A2b): the
  /// bar does not urge the rider toward a place they cannot park.
  final bool navigateSecondary;
  final VoidCallback onNavigate;
  final VoidCallback? onReport, onSuggest;

  /// The page margin the row keeps; it slides out to the screen's edge
  /// through this margin.
  final double edge;

  static const _gap = 8.0, _side = 24.0, _tightSide = 16.0, _labelSize = 16.0;

  static String navigateLabel({required bool street}) =>
      street ? '導航' : '導航到入口';

  /// The bar's height at the current text size.
  static double heightFor(BuildContext context) =>
      math.max(48.0, MediaQuery.textScalerOf(context).scale(20) + 28);

  /// The labels' width together at the current text size, in the style
  /// the buttons set them in: its letter spacing alone adds a few points
  /// to each label, enough to cut 導航到入口 at 411 points (#466).
  static double _labelsWidth(BuildContext context, List<String> labels) {
    final style = AdaptiveButton.measureStyle(context, labelSize: _labelSize);
    var total = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      total += painter.width.ceilToDouble();
      painter.dispose();
    }
    return total;
  }

  /// The buttons' side padding for a row that fits [room], or null when it
  /// has to slide.
  static double? fittedSide(
    BuildContext context,
    double room,
    List<String> labels,
  ) {
    final free =
        room - _labelsWidth(context, labels) - _gap * (labels.length - 1);
    final each = free / (labels.length * 2);
    if (each >= _side) return _side;
    return each >= _tightSide ? each.floorToDouble() : null;
  }

  @override
  State<SpotPreviewActions> createState() => _SpotPreviewActionsState();
}

class _SpotPreviewActionsState extends State<SpotPreviewActions> {
  final rail = ScrollController();

  @override
  void dispose() {
    rail.dispose();
    super.dispose();
  }

  AdaptiveButton _button(
    String key,
    String label,
    VoidCallback? onPressed,
    double side, {
    required bool secondary,
  }) => AdaptiveButton(
    key: ValueKey(key),
    label: label,
    secondary: secondary,
    sidePadding: side,
    labelSize: SpotPreviewActions._labelSize,
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final edge = widget.edge;
      final navigateLabel = SpotPreviewActions.navigateLabel(
        street: widget.street,
      );
      final report = widget.onReport != null;
      final fitted = SpotPreviewActions.fittedSide(
        context,
        constraints.maxWidth - edge * 2,
        [navigateLabel, if (report) '回報現場狀況', '修改建議'],
      );
      final side = fitted ?? SpotPreviewActions._side;
      final navigate = _button(
        'spot-navigate',
        navigateLabel,
        widget.onNavigate,
        side,
        secondary: widget.navigateSecondary,
      );
      final others = [
        if (report)
          _button(
            'spot-report',
            '回報現場狀況',
            widget.onReport,
            side,
            secondary: true,
          ),
        _button(
          'spot-suggest',
          '修改建議',
          widget.onSuggest,
          side,
          secondary: true,
        ),
      ];
      List<Widget> row(Widget first) => [
        first,
        for (final button in others) ...[
          const SizedBox(width: SpotPreviewActions._gap),
          button,
        ],
      ];
      if (fitted != null) {
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: edge),
          child: Row(children: row(Expanded(child: navigate))),
        );
      }
      return Stack(
        children: [
          Semantics(
            container: true,
            explicitChildNodes: true,
            label: '更多動作，可左右滑動',
            child: SingleChildScrollView(
              key: const ValueKey('spot-actions-rail'),
              controller: rail,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: edge),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: row(navigate),
              ),
            ),
          ),
          Positioned.fill(child: _RailFades(rail: rail)),
        ],
      );
    },
  );
}

/// The fades at the ends of the sliding bar, in the sheet's own colour: a
/// side fades only while there is more to reveal on it.
class _RailFades extends StatelessWidget {
  const _RailFades({required this.rail});
  final ScrollController rail;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    Widget fade(String key, double width, Alignment from) => Container(
      key: ValueKey(key),
      width: width,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: from,
          end: Alignment(-from.x, 0),
          colors: [surface, surface.withValues(alpha: 0)],
        ),
      ),
    );
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: rail,
        builder: (context, _) {
          final ready = rail.hasClients && rail.position.hasContentDimensions;
          final more = ready ? rail.position.maxScrollExtent : 1.0;
          final at = ready ? rail.position.pixels : 0.0;
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (at > .5)
                fade('spot-actions-fade-start', 24, Alignment.centerLeft),
              const Spacer(),
              if (at < more - .5)
                fade('spot-actions-fade-end', 36, Alignment.centerRight),
            ],
          );
        },
      ),
    );
  }
}

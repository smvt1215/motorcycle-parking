import 'dart:math' as math;

import '../../domain/four_sign.dart';
import '../../domain/four_sign_display.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/four_sign_plates.dart';
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
  });
  final ParkingSpot spot;
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
                    const SizedBox(height: 2),
                    Text(
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
      ],
    );
  }
}

/// The preview's action bar (Main, A5, A6): 導航到入口 (a street spot:
/// 導航) first, then 回報現場狀況 and 修改建議. One row when it fits,
/// else the first on its own row and the others side by side (A5), else
/// one per row. A null [onReport] leaves 回報現場狀況 out: until the rider
/// sighting sheet (A7, A7b; PR-E) lands, the bar has two buttons.
class SpotPreviewActions extends StatelessWidget {
  const SpotPreviewActions({
    super.key,
    required this.street,
    required this.onNavigate,
    this.onReport,
    this.onSuggest,
  });
  final bool street;
  final VoidCallback onNavigate;
  final VoidCallback? onReport, onSuggest;

  static String navigateLabel({required bool street}) =>
      street ? '導航' : '導航到入口';

  /// The secondary labels shown: 回報現場狀況 only with [report].
  static List<String> _secondary({required bool report}) => [
    if (report) '回報現場狀況',
    '修改建議',
  ];

  /// The room a button needs at the current text size: its label and 24
  /// on either side.
  static double _need(BuildContext context, String label) {
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(fontSize: MediaQuery.textScalerOf(context).scale(16)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + 48;
  }

  /// Whether every button fits one row of [width].
  static bool fitsRow(
    BuildContext context,
    double width, {
    required bool street,
    required bool report,
  }) {
    final labels = [
      navigateLabel(street: street),
      ..._secondary(report: report),
    ];
    final need = labels.fold<double>(0, (a, l) => a + _need(context, l));
    return need + 8 * (labels.length - 1) <= width;
  }

  /// Whether the secondary buttons fit side by side under the first.
  static bool fitsPair(
    BuildContext context,
    double width, {
    required bool report,
  }) {
    final labels = _secondary(report: report);
    final each = (width - 8 * (labels.length - 1)) / labels.length;
    return labels.every((l) => _need(context, l) <= each);
  }

  /// Upper estimate of the bar's height at [width].
  static double heightFor(
    BuildContext context,
    double width, {
    required bool street,
    required bool report,
  }) {
    final button = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(20) + 28,
    );
    if (fitsRow(context, width, street: street, report: report)) return button;
    if (fitsPair(context, width, report: report)) return button * 2 + 8;
    final rows = 1 + _secondary(report: report).length;
    return button * rows + 8 * (rows - 1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final report = onReport != null;
      final navigate = AdaptiveButton(
        key: const ValueKey('spot-navigate'),
        label: navigateLabel(street: street),
        onPressed: onNavigate,
      );
      final secondary = [
        if (report)
          AdaptiveButton(
            key: const ValueKey('spot-report'),
            label: '回報現場狀況',
            secondary: true,
            onPressed: onReport,
          ),
        AdaptiveButton(
          key: const ValueKey('spot-suggest'),
          label: '修改建議',
          secondary: true,
          onPressed: onSuggest,
        ),
      ];
      List<Widget> spaced(List<Widget> items, Widget gap) => [
        for (final (i, w) in items.indexed) ...[if (i > 0) gap, w],
      ];
      if (fitsRow(context, width, street: street, report: report)) {
        return Row(
          children: spaced([
            Expanded(child: navigate),
            ...secondary,
          ], const SizedBox(width: 8)),
        );
      }
      if (fitsPair(context, width, report: report)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            navigate,
            const SizedBox(height: 8),
            Row(
              children: spaced([
                for (final b in secondary) Expanded(child: b),
              ], const SizedBox(width: 8)),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: spaced([navigate, ...secondary], const SizedBox(height: 8)),
      );
    },
  );
}

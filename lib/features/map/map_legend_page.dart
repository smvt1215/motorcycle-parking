import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../data/app_store.dart';
import '../../domain/availability_beta_display.dart';
import '../../domain/availability_display.dart';
import '../../domain/eligibility.dart';
import '../../domain/map_legend_display.dart';
import '../../domain/rider_meter_display.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'availability_capsule.dart';
import 'beta_tag.dart';
import 'cluster_badge.dart';
import 'map_legend.dart';

/// 地圖怎麼看 (design canvas Ver.154 P3): a page pushed inside the current
/// tab, so the tab bar stays below it. iOS has a navigation bar whose back
/// button names where the rider came from; Android an app bar with
/// arrow_back.
class MapLegendPage extends ConsumerWidget {
  const MapLegendPage({super.key, required this.fromMap});

  /// Opened from the map's button rather than from 個人中心.
  final bool fromMap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    void back() => Navigator.maybePop(context);
    return Scaffold(
      key: const ValueKey('map-legend-page'),
      backgroundColor: isCupertino
          ? cu.CupertinoColors.systemGroupedBackground.resolveFrom(context)
          : colors.surface,
      appBar: isCupertino
          ? cu.CupertinoNavigationBar(
              leading: cu.CupertinoNavigationBarBackButton(
                previousPageTitle: legendBackTitle(fromMap: fromMap),
                onPressed: back,
              ),
              middle: const Text(legendTitle),
              backgroundColor: cu.CupertinoColors.systemGroupedBackground
                  .resolveFrom(context)
                  .withValues(alpha: .9),
            )
          : M3EAppBar.top(
              titleText: legendTitle,
              leading: IconButton(
                tooltip: '返回',
                onPressed: back,
                icon: const Icon(Icons.arrow_back),
              ),
            ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          8,
          16,
          // Clear of the floating tab bar on iOS.
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          MapLegendContent(
            vehicle: store.vehicle,
            availability: store.availabilitySource.enabled,
            betaCities: store.availabilityBetaCities,
          ),
        ],
      ),
    );
  }
}

/// The legend itself, shared by the page and the first-launch sheet:
/// markers and pills as lists, the icon families as 3-column grids.
class MapLegendContent extends StatelessWidget {
  const MapLegendContent({
    super.key,
    required this.vehicle,
    this.availability = false,
    this.betaCities = const [],
  });
  final VehicleType vehicle;

  /// Whether this build has live counts, so the pills can appear at all.
  final bool availability;

  /// The cities whose counts are in Beta: the 即時車位 Beta section
  /// explains them again (A13: 之後可從「地圖怎麼看」重看); none without.
  final List<String> betaCities;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    const allowed = (EligibilityStatus.allowed, null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          legendIntro(vehicle),
          style: text.bodyMedium?.copyWith(height: 1.5),
        ),
        const SizedBox(height: 22),
        _Section(
          heading: legendMarkersHeading,
          child: _ListRows(
            rows: [
              for (final (status, restriction) in const [
                (EligibilityStatus.allowed, null),
                (EligibilityStatus.conditional, RuleRestriction.timeLimited),
                (EligibilityStatus.unverified, null),
                (EligibilityStatus.notAllowed, null),
              ])
                (
                  SpotMarker(look: (status, restriction)),
                  markerTitle(status),
                  markerDetail(status, vehicle),
                ),
            ],
          ),
        ),
        _Section(
          heading: legendConditionsHeading,
          child: _Grid(
            iconHeight: 44,
            items: [
              for (final restriction in legendConditionOrder)
                (
                  SpotMarker(
                    look: (EligibilityStatus.conditional, restriction),
                  ),
                  conditionLabel(restriction),
                  '',
                ),
            ],
          ),
        ),
        _Section(
          heading: legendBadgesHeading,
          note: legendBadgesNote,
          child: _Grid(
            key: const ValueKey('legend-badges'),
            iconHeight: 48,
            items: [
              for (final badge in SpaceBadge.values)
                (
                  SpotMarker(look: allowed, badge: badge),
                  badge.label,
                  badge.look,
                ),
            ],
          ),
        ),
        if (availability)
          _Section(
            key: const ValueKey('availability-legend'),
            heading: legendCapsulesHeading,
            note: legendCapsulesNote,
            child: _ListRows(
              rows: [
                for (final (capsule, (title, detail)) in [
                  (
                    const AvailabilityCapsule(
                      text: '剩 12',
                      style: CapsuleStyle.live,
                      semantics: '',
                    ),
                    capsuleLegendLive,
                  ),
                  (
                    const AvailabilityCapsule(
                      text: '已滿',
                      style: CapsuleStyle.full,
                      semantics: '',
                    ),
                    capsuleLegendFull,
                  ),
                  (
                    const AvailabilityCapsule(
                      text: '剩 12',
                      style: CapsuleStyle.delayed,
                      semantics: '',
                    ),
                    capsuleLegendDelayed,
                  ),
                  (
                    const AvailabilityCapsule(
                      text: '暫停',
                      style: CapsuleStyle.suspended,
                      semantics: '',
                    ),
                    capsuleLegendSuspended,
                  ),
                  // Car bays carry a count only for heavy bikes.
                  if (vehicle == VehicleType.heavy)
                    (
                      const AvailabilityCapsule(
                        text: '剩 3',
                        style: CapsuleStyle.car,
                        semantics: '',
                      ),
                      capsuleLegendCar,
                    ),
                ])
                  (AvailabilityCapsuleView(capsule: capsule), title, detail),
              ],
            ),
          ),
        if (availability && betaCities.isNotEmpty)
          _Section(
            key: const ValueKey('availability-beta-legend'),
            heading: legendBetaHeading,
            headingTag: const BetaTag(),
            child: _ListRows(
              rows: [
                (
                  const AvailabilityCapsuleView(
                    capsule: AvailabilityCapsule(
                      text: '剩 4',
                      style: CapsuleStyle.live,
                      semantics: '',
                    ),
                  ),
                  legendBetaSource(betaCities),
                  '',
                ),
                (
                  Icon(Icons.schedule, size: 24, color: muted),
                  betaIntroCaution,
                  '',
                ),
                (
                  const SpotMarker(look: allowed, size: 24),
                  betaIntroEligibility,
                  '',
                ),
              ],
            ),
          ),
        _Section(
          key: const ValueKey('rider-legend'),
          heading: legendRiderHeading,
          note: legendRiderNote,
          child: _Grid(
            iconHeight: 28,
            items: [
              for (final level in RiderLevel.values.reversed)
                (RiderMeterBadge(meter: RiderMeter(level)), level.label, ''),
              (
                const RiderMeterBadge(
                  meter: RiderMeter.conflict(
                    RiderLevel.plenty,
                    RiderLevel.full,
                  ),
                ),
                riderConflictLabel,
                riderConflictDetail,
              ),
            ],
          ),
        ),
        _Section(
          heading: legendOthersHeading,
          child: _Grid(
            iconHeight: 56,
            items: [
              (
                const SpotMarker(look: allowed, selected: true),
                otherSelected.$1,
                otherSelected.$2,
              ),
              (const ClusterBadge(count: 12), otherCluster.$1, otherCluster.$2),
              (const ExcludedSpotDot(), otherExcluded.$1, otherExcluded.$2),
              (
                const SpotMarker(look: allowed, faded: true),
                otherGone.$1,
                otherGone.$2,
              ),
              (
                Icon(
                  Icons.touch_app_outlined,
                  size: 28,
                  color: Theme.of(context).colorScheme.primary,
                ),
                otherLongPress.$1,
                otherLongPress.$2,
              ),
            ],
          ),
        ),
        Text(
          legendFootnote,
          style: text.bodySmall?.copyWith(color: muted, height: 1.5),
        ),
      ],
    );
  }
}

/// A heading over a group: the iOS inset grouped list (grey caption,
/// white rounded card) or the Android flat section (primary title).
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.heading,
    required this.child,
    this.note,
    this.headingTag,
  });
  final String heading;
  final String? note;
  final Widget child;

  /// A tag after the heading, such as Beta.
  final Widget? headingTag;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final note = this.note;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: isCupertino
                ? const EdgeInsets.fromLTRB(16, 0, 16, 6)
                : const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              header: true,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      heading,
                      style: isCupertino
                          ? TextStyle(
                              fontSize: 13,
                              color: cu.CupertinoColors.secondaryLabel
                                  .resolveFrom(context),
                            )
                          : TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.primary,
                            ),
                    ),
                  ),
                  if (headingTag case final tag?) ...[
                    const SizedBox(width: 6),
                    tag,
                  ],
                ],
              ),
            ),
          ),
          if (isCupertino)
            DecoratedBox(
              decoration: BoxDecoration(
                color: cu.CupertinoColors.secondarySystemGroupedBackground
                    .resolveFrom(context),
                borderRadius: BorderRadius.circular(12),
              ),
              child: child,
            )
          else
            child,
          if (note != null)
            Padding(
              padding: EdgeInsets.fromLTRB(
                isCupertino ? 16 : 0,
                6,
                isCupertino ? 16 : 0,
                0,
              ),
              child: Text(
                note,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One row per item: the visual in an 84-wide column, then name and
/// meaning. A screen reader reads the words; the visual is decoration.
class _ListRows extends StatelessWidget {
  const _ListRows({required this.rows});
  final List<(Widget, String, String)> rows;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final divider = isCupertino
        ? cu.CupertinoColors.separator.resolveFrom(context)
        : null;
    return Column(
      children: [
        for (final (i, (visual, title, detail)) in rows.indexed)
          Container(
            decoration: divider != null && i > 0
                ? BoxDecoration(
                    border: Border(top: BorderSide(color: divider, width: .5)),
                  )
                : null,
            padding: EdgeInsets.symmetric(
              horizontal: isCupertino ? 16 : 0,
              vertical: 10,
            ),
            child: MergeSemantics(
              child: Row(
                children: [
                  SizedBox(
                    width: 84,
                    child: Center(
                      // A wide pill (large text, long count) shrinks rather
                      // than overflow the column.
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: ExcludeSemantics(child: visual),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(fontSize: isCupertino ? 17 : 16),
                        ),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.45,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Three columns of a visual over its name and, where given, a line of
/// explanation.
class _Grid extends StatelessWidget {
  const _Grid({super.key, required this.items, required this.iconHeight});
  final List<(Widget, String, String)> items;
  final double iconHeight;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final outer = isCupertino
        ? const EdgeInsets.symmetric(horizontal: 8, vertical: 14)
        : const EdgeInsets.only(top: 8, bottom: 10);
    final gap = isCupertino ? 6.0 : 8.0;
    return Padding(
      padding: outer,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = (constraints.maxWidth - gap * 2) / 3;
          return Wrap(
            spacing: gap,
            runSpacing: isCupertino ? 16 : 18,
            children: [
              for (final (visual, title, detail) in items)
                SizedBox(
                  width: width,
                  child: MergeSemantics(
                    child: Column(
                      children: [
                        SizedBox(
                          height: iconHeight,
                          child: Center(child: ExcludeSemantics(child: visual)),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 14,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (detail.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            detail,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

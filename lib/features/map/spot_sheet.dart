import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../models/availability.dart';
import '../../models/parking.dart';
import '../../models/spot_history.dart';
import '../../domain/availability_display.dart';
import '../../domain/sighting_display.dart';
import '../../data/sighting_repository.dart' show canSight;
import '../report/sighting_sheet.dart';
import '../../domain/eligibility.dart';
import '../../domain/eligibility_display.dart';
import '../../domain/parking_decision.dart';
import '../../ui/adaptive/adaptive.dart';
import '../auth/sign_in.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:share_plus/share_plus.dart';

import '../report/spot_suggestions.dart';
import 'map_legend.dart';
import 'closure_card.dart';
import 'spot_details.dart';
import 'spot_fees.dart';
import 'spot_photos.dart';
import 'parking_access_view.dart';
import 'vehicle_sheet.dart' show SmallPlateStack, platesOf;

/// Peek height: header, eligibility and actions, with the map left visible
/// above, the way map apps open a place.
/// The sheet's resting height, as a fraction of the space it opens in.
const spotSheetPeek = .42;

String _distanceLabel(double meters) => meters < 1000
    ? '${(meters / 10).round() * 10} 公尺'
    : '${(meters / 1000).toStringAsFixed(1)} 公里';

/// Opens a spot's details over another page. The map embeds [SpotSheet]
/// instead, so it stays movable and other spots stay tappable.
Future<void> showSpot(BuildContext context, AppStore store, ParkingSpot spot) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => SpotSheet(store: store, spot: spot),
      detail: true,
    );

class SpotSheet extends StatefulWidget {
  const SpotSheet({
    super.key,
    required this.store,
    required this.spot,
    this.onClose,
  });
  final AppStore store;
  final ParkingSpot spot;

  /// Closes an embedded sheet; a modal sheet pops its route by default.
  final VoidCallback? onClose;
  @override
  State<SpotSheet> createState() => _SpotSheetState();
}

class _SpotSheetState extends State<SpotSheet> {
  void close(BuildContext context) =>
      (widget.onClose ?? () => Navigator.pop(context))();

  final extent = DraggableScrollableController();

  /// The spot's latest public changes (#141), read once per spot.
  late Future<List<HistoryEntry>> history = _history();

  Future<List<HistoryEntry>> _history() => widget.store.parking
      .history(widget.spot.id)
      .catchError((Object _) => const <HistoryEntry>[]);

  @override
  void didUpdateWidget(SpotSheet old) {
    super.didUpdateWidget(old);
    if (old.spot.id != widget.spot.id) history = _history();
  }

  Offset? start;
  bool dismissGesture = false;
  bool closing = false;
  String? feedback;
  Future<void> share(BuildContext buttonContext) async {
    final spot = widget.spot;
    final text =
        '${spot.name}\nhttps://www.google.com/maps/search/?api=1&query=${spot.lat},${spot.lng}';
    final box = buttonContext.findRenderObject() as RenderBox;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: spot.name,
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          downloadFallbackEnabled: false,
        ),
      );
      if (!kIsWeb || result.status != ShareResultStatus.unavailable) return;
    } catch (_) {
      if (!kIsWeb) rethrow;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => feedback = '位置連結已複製，可貼上分享。');
  }

  @override
  void dispose() {
    extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildDetails(context),
  );

  Widget _buildDetails(BuildContext context) {
    final store = widget.store, spot = widget.spot;
    final sourceUri = licenseLinkUri(spot);
    final colors = Theme.of(context).colorScheme;
    final photos = SpotPhotos.usable(spot.photoUrls);
    // Tablets keep a phone-width sheet instead of spanning the screen.
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        // Over a Google map on the web, the sheet must take its own clicks.
        child: PointerInterceptor(
          intercepting: kIsWeb,
          child: _sheet(context, store, spot, sourceUri, colors, photos),
        ),
      ),
    );
  }

  Widget _sheet(
    BuildContext context,
    AppStore store,
    ParkingSpot spot,
    Uri? sourceUri,
    ColorScheme colors,
    List<String> photos,
  ) {
    return DraggableScrollableSheet(
      key: const ValueKey('parking-spot-sheet'),
      controller: extent,
      initialChildSize: spotSheetPeek,
      minChildSize: spotSheetPeek,
      maxChildSize: 1,
      snap: true,
      shouldCloseOnMinExtent: false,
      expand: false,
      builder: (ctx, scroll) => Listener(
        onPointerDown: (event) {
          start = event.position;
          dismissGesture =
              extent.isAttached &&
              extent.size <= spotSheetPeek + .001 &&
              scroll.hasClients &&
              scroll.offset <= 0;
        },
        onPointerMove: (event) {
          if (start == null || !dismissGesture || closing) return;
          final delta = event.position - start!;
          if (delta.dy > 80 && delta.dy > delta.dx.abs() * 1.2) {
            closing = true;
            close(ctx);
          }
        },
        onPointerUp: (_) {
          start = null;
          dismissGesture = false;
        },
        onPointerCancel: (_) {
          start = null;
          dismissGesture = false;
        },
        child: Material(
          color: Theme.of(ctx).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: AnimatedBuilder(
            animation: store,
            builder: (ctx, _) {
              final decision = store.decide(spot);
              final eligibility = decision.eligibility;
              final extraFee = _additionalFeeNote(spot);
              final actions = _DetailActions(
                onNavigate: () =>
                    runAction(ctx, () => navigateTo(spot.lat, spot.lng)),
                onSuggest: () =>
                    runAction(ctx, () => showSpotSuggestions(ctx, store, spot)),
                // Riders' on-site sightings (#154), for spots stored in
                // the backend.
                onSighting: store.demo || canSight(spot)
                    ? () => runAction(
                        ctx,
                        () => showSightingSheet(ctx, store, spot),
                      )
                    : null,
              );
              return LayoutBuilder(
                builder: (ctx, constraints) {
                  // A short sheet (landscape, large text) keeps the actions
                  // in the scrolling list so the header is never squeezed out.
                  // Three actions one per row would fill a narrow sheet:
                  // 導航到這裡 and 修改建議 stay pinned as before, and
                  // 回報現場狀況 follows the summary.
                  final split =
                      actions.onSighting != null &&
                      _stackedActions(
                        ctx,
                        constraints.maxWidth - 40,
                        three: true,
                      );
                  final pinned =
                      constraints.maxHeight -
                          _footerHeight(
                            ctx,
                            constraints.maxWidth - 40,
                            three: actions.onSighting != null,
                            split: split,
                          ) >=
                      _minDetailHeight;
                  return Column(
                    children: [
                      Expanded(
                        child: ListView(
                          controller: scroll,
                          padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                          children: [
                            Center(
                              child: Container(
                                width: 40,
                                height: 4,
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: Theme.of(ctx).colorScheme.outline,
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                            _SpotHeading(
                              name: spot.name,
                              subtitle: [
                                facilitySummary(spot),
                                regionSummary(spot),
                                if (store.located)
                                  _distanceLabel(
                                    distanceMeters(
                                      store.lat,
                                      store.lng,
                                      spot.lat,
                                      spot.lng,
                                    ),
                                  ),
                              ].where((value) => value.isNotEmpty).join(' · '),
                              favorite: store.favorites.any(
                                (s) => s.id == spot.id,
                              ),
                              onFavorite: () => runAction(
                                ctx,
                                () => store.toggleFavorite(spot),
                              ),
                              onShare: share,
                              onClose: () => close(ctx),
                            ),
                            const SizedBox(height: 14),
                            // Works or a closure (#116), above the verdict:
                            // it overrides it while it holds.
                            if (spot.closure case final closure?) ...[
                              ClosureCard(
                                closure: closure,
                                now: store.clock(),
                                onReopened: () => runAction(ctx, () async {
                                  final message = await reportReopened(
                                    store,
                                    spot,
                                  );
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                      SnackBar(content: Text(message)),
                                    );
                                  }
                                }),
                                onStillClosed: () => runAction(
                                  ctx,
                                  () => showGoneReport(ctx, store, spot),
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            _SpotDecision(
                              vehicle: store.vehicle,
                              eligibility: eligibility,
                              display: eligibilityDisplay(
                                spot,
                                store.vehicle,
                                eligibility,
                                decision: decision,
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Ticks each minute: the rate follows the
                            // period the rider is in (decision 26).
                            MinuteTicker(
                              clock: store.clock,
                              builder: (_, now) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _SpotSummary(
                                    spot: spot,
                                    vehicle: store.vehicle,
                                    availability: store.availabilityOf(spot),
                                    decision: decision,
                                    now: now,
                                  ),
                                  // Its own row, never in the count above:
                                  // a sighting is not official (#154).
                                  if (sightingLine(store.sightingOf(spot), now)
                                      case final line?) ...[
                                    const SizedBox(height: 14),
                                    _SightingRow(line: line),
                                  ],
                                ],
                              ),
                            ),
                            if (feedback != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(feedback!),
                              ),
                            if (pinned && split) ...[
                              const SizedBox(height: 16),
                              actions.sightingOnly,
                            ],
                            _DetailSection(
                              title: '收費',
                              icon: Icons.payments_outlined,
                              children: [
                                SpotFees(
                                  spot: spot,
                                  vehicle: store.vehicle,
                                  decision: decideParking(spot, store.vehicle, [
                                    ?store.ruleFor(spot),
                                  ], now: store.clock()),
                                  extraNote: extraFee,
                                ),
                              ],
                            ),
                            _DetailSection(
                              title: '停車資訊',
                              icon: Icons.local_parking_outlined,
                              children: [
                                _DetailField(
                                  label: '類型',
                                  value: facilitySummary(spot),
                                ),
                                Text(
                                  spot.zones.isEmpty ? '停放車種' : '分區',
                                  style: Theme.of(ctx).textTheme.bodySmall
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                                const SizedBox(height: 10),
                                ParkingAccessView(spot: spot),
                              ],
                            ),
                            _DetailSection(
                              title: '位置與指引',
                              icon: Icons.near_me_outlined,
                              children: [
                                if (spot.isFacility &&
                                    spot.entranceNote.trim().isNotEmpty)
                                  _DetailField(
                                    label: '入口',
                                    value: spot.entranceNote,
                                  ),
                                if (spot.parkingGuide.trim().isNotEmpty)
                                  _DetailField(
                                    label: '停車指引',
                                    value: spot.parkingGuide,
                                  ),
                                _DetailField(
                                  label: '位置',
                                  value: [
                                    if (spot.address.trim().isNotEmpty)
                                      spot.address,
                                    if (spot.roadSegment.trim().isNotEmpty)
                                      spot.roadSegment,
                                  ].join('\n'),
                                  secondary:
                                      'GPS ${spot.lat.toStringAsFixed(6)}, ${spot.lng.toStringAsFixed(6)}',
                                ),
                                if (spot.specialRules.trim().isNotEmpty)
                                  _DetailField(
                                    label: '特殊規則',
                                    value: spot.specialRules,
                                  ),
                              ],
                            ),
                            _DetailSection(
                              title: '現場補充',
                              icon: Icons.photo_camera_outlined,
                              children: [
                                Text(
                                  '照片',
                                  style: Theme.of(ctx).textTheme.labelLarge,
                                ),
                                const SizedBox(height: 8),
                                SpotPhotos(
                                  urls: spot.photoUrls,
                                  strip: photos.isNotEmpty,
                                ),
                                const SizedBox(height: 14),
                                if (spot.note.trim().isNotEmpty)
                                  _DetailField(label: '備註', value: spot.note),
                              ],
                            ),
                            _DetailSection(
                              title: '資料與查核',
                              icon: Icons.verified_outlined,
                              children: [
                                _DetailField(
                                  label: '資料來源',
                                  value: sourceSummary(spot, demo: store.demo),
                                ),
                                if (!spot.isOfficial)
                                  _ConfirmationField(
                                    lines: confirmationLines(spot),
                                  ),
                                _LatestUpdateField(
                                  spot: spot,
                                  history: history,
                                ),
                                if (sourceUri != null)
                                  TextButton(
                                    onPressed: () => runAction(ctx, () async {
                                      if (!await launchUrl(sourceUri)) {
                                        throw StateError('無法開啟資料授權');
                                      }
                                    }),
                                    child: const Text('查看政府資料授權'),
                                  ),
                                if (spot.stale) ...[
                                  const SizedBox(height: 8),
                                  const _DetailRow(
                                    icon: Icons.info_outline,
                                    text: '停放資訊可能過時，請確認現場公告。',
                                  ),
                                ],
                              ],
                            ),
                            if (!store.canReport)
                              TextButton(
                                onPressed: () => showSignIn(ctx, store),
                                child: const Text('登入後提出修改建議'),
                              ),
                            if (!pinned) ...[
                              const SizedBox(height: 16),
                              actions,
                            ],
                          ],
                        ),
                      ),
                      if (pinned)
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.surface,
                            border: Border(
                              top: BorderSide(color: colors.outlineVariant),
                            ),
                          ),
                          child: SafeArea(
                            top: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                20,
                                12,
                                20,
                                12,
                              ),
                              child: split ? actions.withoutSighting : actions,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

String _additionalFeeNote(ParkingSpot spot) {
  if (spot.fee != null) return '';
  final rates = [
    for (final zone in spot.zones) ...[
      zone.feeNote,
      zone.scooterFeeText,
      zone.heavyFeeText,
      // A car's old text is not shown (decision 45).
    ],
  ];
  if (!rates.any((rate) => rate.trim().isNotEmpty)) return '';
  final note = spot.feeNote.trim();
  if (note == '0' && rates.any((rate) => rate.trim() == '免費')) return '';
  if ([
        '',
        '請依現場公告',
        '依現場公告',
        '依車種計費',
        '依車種與分區計費',
        '依車種與停放區計費',
        '依分區計費',
      ].contains(note) ||
      rates.any((rate) => rate.trim() == note)) {
    return '';
  }
  return note;
}

class _SpotHeading extends StatelessWidget {
  const _SpotHeading({
    required this.name,
    required this.subtitle,
    required this.favorite,
    required this.onFavorite,
    required this.onShare,
    required this.onClose,
  });
  final String name, subtitle;
  final bool favorite;
  final VoidCallback onFavorite, onClose;
  final Future<void> Function(BuildContext) onShare;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  name,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '關閉詳情',
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(
                subtitle,
                key: const ValueKey('spot-subtitle'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
              ),
            ),
            IconButton(
              tooltip: favorite ? '取消收藏' : '收藏停車點',
              onPressed: onFavorite,
              icon: Icon(
                favorite ? Icons.bookmark : Icons.bookmark_outline,
                size: 21,
              ),
              color: colors.primary,
            ),
            Builder(
              builder: (buttonContext) => IconButton(
                tooltip: '分享停車點',
                onPressed: () =>
                    runAction(buttonContext, () => onShare(buttonContext)),
                icon: const Icon(Icons.ios_share, size: 21),
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SpotDecision extends StatelessWidget {
  const _SpotDecision({
    required this.vehicle,
    required this.eligibility,
    required this.display,
  });
  final VehicleType vehicle;
  final Eligibility eligibility;
  final EligibilityDisplay display;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = spotMarkerColor(eligibility.status);
    // The marker's colour and shape, so the banner reads like the map; a
    // rider's claim swaps the question mark for people, never for a tick.
    final icon = display.reported && !display.lapsed
        ? Icons.groups_outlined
        : spotMarkerIcon(markerLook(eligibility));
    return MergeSemantics(
      child: Container(
        key: const ValueKey('spot-decision'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .08),
          border: Border(left: BorderSide(color: color, width: 3)),
          borderRadius: const BorderRadius.only(
            topRight: Radius.circular(12),
            bottomRight: Radius.circular(12),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(
                  spotMarkerRadius(eligibility.status) * .8,
                ),
              ),
              child: Icon(icon, size: 20, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Riders know their class by plate colour.
                  Row(
                    children: [
                      ExcludeSemantics(
                        // Both plates of the class, as in the vehicle
                        // picker: one colour alone names only half of it.
                        child: SmallPlateStack(
                          key: const ValueKey('spot-decision-plate'),
                          plates: platesOf(vehicle),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          vehicle.label,
                          style: text.labelMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    display.label,
                    key: const ValueKey('spot-decision-label'),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  if (display.explanation.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      display.explanation,
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (display.basis case final basis?) ...[
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Icon(
                            display.reported
                                ? Icons.schedule
                                : Icons.verified_user_outlined,
                            size: 16,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            basis,
                            key: const ValueKey('spot-decision-basis'),
                            style: text.bodySmall?.copyWith(
                              color: colors.onSurface,
                              height: 1.45,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  for (final (i, notice) in display.notices.indexed) ...[
                    const SizedBox(height: 4),
                    _BannerLine(
                      key: ValueKey('spot-decision-notice-$i'),
                      // An ended notice changes the icon and says so in
                      // words; amber only adds to that (§8.7 C4).
                      icon: notice.expired
                          ? Icons.event_busy_outlined
                          : Icons.calendar_today_outlined,
                      iconColor: notice.expired
                          ? conditionalColor
                          : colors.onSurfaceVariant,
                      text: notice.text,
                    ),
                  ],
                  if (display.zones.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final (i, zone) in display.zones.indexed)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _ZoneRow(
                          key: ValueKey('spot-zone-$i'),
                          zone: zone,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One line under the banner's headline: an icon and wrapping text.
class _BannerLine extends StatelessWidget {
  const _BannerLine({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.text,
  });
  final IconData icon;
  final Color iconColor;
  final String text;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(icon, size: 16, color: iconColor),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurface, height: 1.45),
          ),
        ),
      ],
    );
  }
}

/// A zone's eligibility under the banner (逐區資格): the map marker's small
/// shape and colour, the zone's name and its status in words. Regular
/// weight, so the banner's conclusion stays the only bold line.
class _ZoneRow extends StatelessWidget {
  const _ZoneRow({super.key, required this.zone});
  final ZoneLine zone;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final color = spotMarkerColor(zone.status);
    // Why it is conditional or unknown, less what the notice lines say.
    final detail =
        zone.reason.isNotEmpty &&
            (zone.status == EligibilityStatus.conditional ||
                zone.status == EligibilityStatus.unverified)
        ? '：${zone.reason}'
        : '';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(
                spotMarkerRadius(zone.status) * .4,
              ),
            ),
            child: Icon(
              spotMarkerIcon((zone.status, zone.restriction)),
              size: 11,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${zone.name}・${zone.label}$detail',
            style: text.bodySmall?.copyWith(
              color: colors.onSurface,
              height: 1.45,
            ),
          ),
        ),
      ],
    );
  }
}

class _SpotSummary extends StatelessWidget {
  const _SpotSummary({
    required this.spot,
    required this.vehicle,
    required this.availability,
    required this.decision,
    required this.now,
  });
  final ParkingSpot spot;
  final VehicleType vehicle;
  final SpotAvailability availability;
  final ParkingDecision decision;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final legacy = spot.available;
    // Live counts come from snapshots; a spot's own legacy count is shown
    // the old way only when no snapshot exists for it.
    final live =
        spot.isFacility &&
        (!availability.isEmpty || legacy == null || legacy < 0);
    // The rate at this moment (decision 26); the full board is below.
    final fee = spotFeeNow(spot, vehicle, now);
    final available = spot.available;
    final availabilityTime =
        spot.availabilityUpdatedAt ??
        (spot.source == 'tdx' && spot.spaceType == SpaceType.offStreet
            ? spot.updatedAt
            : null);
    final availabilityCaption =
        spot.isFacility && available != null && available >= 0
        ? availabilityTime == null
              ? '車位時間未提供'
              : formatSpotTime(availabilityTime)
        : null;
    final total = spot.scooterTotal;
    final capacity = total != null && available != null && total >= available
        ? ' / $total 格'
        : '';
    final second = spot.isFacility
        ? (available == null || available < 0
              ? '尚無即時資料'
              : '$available 格$capacity')
        : spot.spaceType.label;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 18 ||
            fee.main.text.length + (fee.caption?.length ?? 0) > 48;
        final facts = [
          FeeNowSummary(now: fee),
          if (live)
            _AvailabilitySummary(
              fact: availabilityFact(
                spot,
                availability,
                vehicle,
                decision,
                now,
              ),
            )
          else
            _SummaryFact(
              label: spot.isFacility ? '機車剩餘' : '地面格位',
              value: second,
              caption: availabilityCaption,
            ),
        ];
        return stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [facts[0], const SizedBox(height: 12), facts[1]],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: facts[0]),
                  const SizedBox(width: 20),
                  Expanded(child: facts[1]),
                ],
              );
      },
    );
  }
}

/// The availability half of the summary: a large count beside 「剩餘」 and
/// the capacity, or the reason there is none. Ink only, never a status
/// colour, so it never competes with the eligibility banner.
class _AvailabilitySummary extends StatelessWidget {
  const _AvailabilitySummary({required this.fact});
  final AvailabilityFact fact;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    const figures = [FontFeature.tabularFigures()];
    return Semantics(
      key: const ValueKey('availability-summary'),
      label: fact.semantics,
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fact.title, style: muted),
          const SizedBox(height: 4),
          if (fact.count case final count?)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$count',
                    style: text.headlineMedium?.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      fontFeatures: figures,
                    ),
                  ),
                  TextSpan(
                    text: ' ${fact.headline}',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (fact.capacity case final capacity?)
                    TextSpan(
                      text: ' $capacity',
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: figures,
                      ),
                    ),
                ],
              ),
              key: const ValueKey('availability-count'),
            )
          else
            Text(
              fact.headline,
              key: const ValueKey('availability-headline'),
              style: text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          if (fact.caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(fact.caption, style: muted),
          ],
          for (final note in fact.notes) ...[
            const SizedBox(height: 10),
            Text(
              note.text,
              style: text.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: figures,
              ),
            ),
            const SizedBox(height: 2),
            Text(note.caption, style: muted),
          ],
        ],
      ),
    );
  }
}

class _SummaryFact extends StatelessWidget {
  const _SummaryFact({required this.label, required this.value, this.caption});
  final String label, value;
  final String? caption;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 4),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600, height: 1.4),
      ),
      if (caption != null) ...[
        const SizedBox(height: 4),
        Text(
          caption!,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ],
  );
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  bool _missing(Widget child) =>
      child is _DetailField &&
      (child.value.trim().isEmpty || child.value.trim() == '未提供') &&
      child.secondary.isEmpty;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final missing = children
        .where(_missing)
        .cast<_DetailField>()
        .map((field) => field.label)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Icon(icon, size: 19, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: colors.outlineVariant),
          const SizedBox(height: 16),
          ...children.where((child) => !_missing(child)),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '尚未提供：${missing.join('、')}',
                key: ValueKey('missing-$title'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    required this.value,
    this.secondary = '',
    this.action,
  });

  final String label, value, secondary;

  /// A link or toggle under the value (看更新紀錄, 還有 N 項).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelWidget = Text(
      label,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: colors.onSurfaceVariant),
    );
    final valueWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (value.trim().isNotEmpty)
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(height: 1.5),
          ),
        if (secondary.isNotEmpty) ...[
          if (value.trim().isNotEmpty) const SizedBox(height: 5),
          Text(
            secondary,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
          ),
        ],
        ?action,
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 18) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, const SizedBox(height: 6), valueWidget],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 76, child: labelWidget),
              const SizedBox(width: 12),
              Expanded(child: valueWidget),
            ],
          );
        },
      ),
    );
  }
}

/// 確認狀態 (decision 52): the newest confirmation, the rest folded under
/// 「還有 N 項」; 尚未確認 when there is none.
class _ConfirmationField extends StatefulWidget {
  const _ConfirmationField({required this.lines});
  final List<String> lines;

  @override
  State<_ConfirmationField> createState() => _ConfirmationFieldState();
}

class _ConfirmationFieldState extends State<_ConfirmationField> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    if (lines.length < 2) {
      return _DetailField(label: '確認狀態', value: lines.firstOrNull ?? '尚未確認');
    }
    final colors = Theme.of(context).colorScheme;
    return _DetailField(
      label: '確認狀態',
      value: (expanded ? lines : lines.take(1)).join('\n'),
      action: Semantics(
        expanded: expanded,
        child: TextButton.icon(
          key: const ValueKey('spot-confirmations-more'),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 40),
            alignment: AlignmentDirectional.centerStart,
            foregroundColor: colors.primary,
          ),
          onPressed: () => setState(() => expanded = !expanded),
          iconAlignment: IconAlignment.end,
          icon: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text(expanded ? '收起' : '還有 ${lines.length - 1} 項'),
        ),
      ),
    );
  }
}

/// 最近更新 (#141, AppHistory): the latest change's kinds and date, and
/// 「看更新紀錄」 for the last 10. Until the history answers, or where there
/// is none, the spot's own update time stands in.
class _LatestUpdateField extends StatelessWidget {
  const _LatestUpdateField({required this.spot, required this.history});
  final ParkingSpot spot;
  final Future<List<HistoryEntry>> history;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HistoryEntry>>(
    future: history,
    builder: (context, snapshot) {
      final entries = snapshot.data ?? const <HistoryEntry>[];
      final latest = entries.firstOrNull;
      final updated = spot.updatedAt;
      // History covers administrators' writes, decided reports, owners'
      // edits and votes (decision 56); an update it does not cover (an older
      // server) keeps its later time.
      final covered =
          latest != null &&
          (updated == null ||
              !updated.isAfter(latest.at.add(const Duration(minutes: 1))));
      return _DetailField(
        label: '最近更新',
        value: covered
            ? '${latest.title(app: true)}，${formatSpotDate(latest.at)}'
            : updated == null
            ? '未提供'
            : formatSpotTime(updated),
        action: latest == null
            ? null
            : TextButton(
                key: const ValueKey('spot-history-open'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 40),
                  alignment: AlignmentDirectional.centerStart,
                ),
                onPressed: () => showSpotHistory(context, spot, entries),
                child: const Text('看更新紀錄'),
              ),
      );
    },
  );
}

/// The app's 更新紀錄 sheet (AppHistory): the latest 10 changes, each its
/// kinds, what it changed to where the spot still holds it, and the date
/// with where it came from. No reporter or administrator is named, and no
/// before value is shown.
Future<void> showSpotHistory(
  BuildContext context,
  ParkingSpot spot,
  List<HistoryEntry> entries,
) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle('更新紀錄'),
      const SizedBox(height: 8),
      for (final (i, entry) in entries.take(10).indexed)
        _HistoryItem(
          key: ValueKey('spot-history-$i'),
          entry: entry,
          official: spot.isOfficial,
          last: i == math.min(entries.length, 10) - 1,
        ),
      const SizedBox(height: 12),
      Text(
        '只列最近 10 筆，不顯示回報者名稱。',
        style: Theme.of(ctx).textTheme.bodySmall
            ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
      ),
    ],
  ),
);

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    super.key,
    required this.entry,
    required this.official,
    required this.last,
  });
  final HistoryEntry entry;
  final bool official, last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summary = historySummary(entry);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.title(app: true),
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(summary, style: text.bodyMedium),
          ],
          const SizedBox(height: 2),
          Text(
            '${formatSpotDate(entry.at)}・${historySourceText(entry, official: official)}',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 10),
      Expanded(child: Text(text)),
    ],
  );
}

/// Room the scrolling details keep above a pinned action footer: the drag
/// handle, the name and the start of the eligibility summary.
const _minDetailHeight = 160.0;

/// Content width from which three actions fit side by side (tablets).
const _oneRowThree = 528.0;

/// Whether the actions stack one per row. With 回報現場狀況 the two
/// secondary actions share a row under 導航到這裡 (canvas), which needs
/// more width for its six characters.
bool _stackedActions(
  BuildContext context,
  double width, {
  bool three = false,
}) =>
    width < (three ? 340 : 320) ||
    MediaQuery.textScalerOf(context).scale(14) > 18;

/// Upper estimate of the pinned footer: border, 24 padding, the safe area and
/// one or two rows of buttons at the current text size; [split] leaves
/// 回報現場狀況 out of it.
double _footerHeight(
  BuildContext context,
  double width, {
  bool three = false,
  bool split = false,
}) {
  final button = math.max(
    48.0,
    MediaQuery.textScalerOf(context).scale(20) + 28,
  );
  final rows = split
      ? 2
      : _stackedActions(context, width)
      ? 2
      : (three && width < _oneRowThree ? 2 : 1);
  return 25 +
      MediaQuery.paddingOf(context).bottom +
      button * rows +
      12 * (rows - 1);
}

class _DetailActions extends StatelessWidget {
  const _DetailActions({
    required this.onNavigate,
    this.onSuggest,
    this.onSighting,
    this.navigate = true,
  });
  final VoidCallback onNavigate;
  final VoidCallback? onSuggest;

  /// 回報現場狀況 (#154); null where a spot cannot be sighted.
  final VoidCallback? onSighting;

  /// Whether 導航到這裡 is among them (a split footer leaves 回報現場狀況
  /// to the details).
  final bool navigate;

  _DetailActions get withoutSighting =>
      _DetailActions(onNavigate: onNavigate, onSuggest: onSuggest);
  _DetailActions get sightingOnly => _DetailActions(
    onNavigate: onNavigate,
    onSighting: onSighting,
    navigate: false,
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final three = onSighting != null;
      final stacked = _stackedActions(
        context,
        constraints.maxWidth,
        three: three,
      );
      final half = (constraints.maxWidth - 12) / 2;
      // A tablet's sheet fits all three in a row; on a phone 導航到這裡
      // keeps the whole first row (canvas).
      final oneRow = three && !stacked && constraints.maxWidth >= _oneRowThree;
      final third = (constraints.maxWidth - 24) / 3;
      final width = oneRow
          ? third
          : stacked || onSuggest == null || three
          ? constraints.maxWidth
          : half;
      final secondary = oneRow
          ? third
          : (stacked ? constraints.maxWidth : half);
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          if (navigate)
            SizedBox(
              width: width,
              child: AdaptiveButton(
                label: '導航到這裡',
                icon: Icons.navigation_outlined,
                onPressed: onNavigate,
              ),
            ),
          if (onSighting != null)
            SizedBox(
              width: secondary,
              child: AdaptiveButton(
                key: const ValueKey('sighting-action'),
                label: '回報現場狀況',
                secondary: true,
                icon: Icons.location_searching,
                onPressed: onSighting,
              ),
            ),
          if (onSuggest != null && three)
            SizedBox(
              width: secondary,
              child: AdaptiveButton(
                label: '修改建議',
                secondary: true,
                icon: Icons.edit_outlined,
                onPressed: onSuggest,
              ),
            )
          else if (onSuggest != null)
            SizedBox(
              width: width,
              child: AdaptiveButton(
                label: '修改建議',
                secondary: true,
                icon: Icons.edit_outlined,
                onPressed: onSuggest,
              ),
            ),
        ],
      );
    },
  );
}

/// 「8 分鐘前有騎士回報『有空位』」 and the line under it, in its own bordered
/// row (canvas 路邊靜態與騎士回報).
class _SightingRow extends StatelessWidget {
  const _SightingRow({required this.line});
  final SightingLine line;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        key: const ValueKey('rider-sighting'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.person_outline,
                size: 22,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line.caption,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

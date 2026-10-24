import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../domain/eligibility.dart';
import '../../ui/adaptive/adaptive.dart';
import '../report/report_sheet.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:share_plus/share_plus.dart';

import '../report/spot_suggestions.dart';
import 'map_legend.dart';
import 'spot_details.dart';
import 'spot_photos.dart';
import 'parking_access_view.dart';

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
  Widget build(BuildContext context) {
    final store = widget.store, spot = widget.spot;
    final sourceUri = sourceLinkUri(spot.sourceUrl);
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
              final eligibility = store.eligible(spot);
              final extraFee = _additionalFeeNote(spot);
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
                            spot.city,
                            spot.district,
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
                          favorite: store.favorites.any((s) => s.id == spot.id),
                          onFavorite: () =>
                              runAction(ctx, () => store.toggleFavorite(spot)),
                          onShare: share,
                          onClose: () => close(ctx),
                        ),
                        const SizedBox(height: 14),
                        _SpotDecision(
                          vehicle: store.vehicle.label,
                          eligibility: eligibility,
                        ),
                        const SizedBox(height: 16),
                        _SpotSummary(spot: spot, vehicle: store.vehicle),
                        if (feedback != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(feedback!),
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
                                  ?.copyWith(color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 10),
                            ParkingAccessView(spot: spot),
                            if (extraFee.isNotEmpty) ...[
                              const SizedBox(height: 14),
                              _DetailField(label: '收費說明', value: extraFee),
                            ],
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
                            _DetailField(
                              label: '查核狀態',
                              value: trustSummary(spot, demo: store.demo),
                            ),
                            _DetailField(
                              label: '更新時間',
                              value: spot.updatedAt == null
                                  ? '未提供'
                                  : formatSpotTime(spot.updatedAt!),
                            ),
                            if (spot.isFacility)
                              _DetailField(
                                label: '即時車位狀態',
                                value: availabilitySummary(spot),
                              ),
                            if (spot.licenseNote.trim().isNotEmpty)
                              _DetailField(
                                label: '授權說明',
                                value: spot.licenseNote,
                              ),
                            if (sourceUri != null)
                              TextButton(
                                onPressed: () => runAction(ctx, () async {
                                  if (!await launchUrl(sourceUri)) {
                                    throw StateError('無法開啟資料來源');
                                  }
                                }),
                                child: const Text('查看停車點資料來源'),
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
                            onPressed: () => showSettings(ctx, store),
                            child: const Text('登入後提出修改建議'),
                          ),
                      ],
                    ),
                  ),
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
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                        child: _DetailActions(
                          onNavigate: () => runAction(
                            ctx,
                            () => navigateTo(spot.lat, spot.lng),
                          ),
                          onSuggest: () => runAction(
                            ctx,
                            () => showSpotSuggestions(ctx, store, spot),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

String _additionalFeeNote(ParkingSpot spot) {
  final rates = [
    for (final zone in spot.zones) ...[
      zone.feeNote,
      zone.scooterFeeNote,
      zone.heavyFeeNote,
      zone.carFeeNote,
    ],
  ];
  if (!rates.any((rate) => rate.trim().isNotEmpty)) return '';
  final note = spot.feeNote.trim();
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
  const _SpotDecision({required this.vehicle, required this.eligibility});
  final String vehicle;
  final Eligibility eligibility;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final color = spotMarkerColor(eligibility.status);
    return Container(
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
            child: Icon(
              spotMarkerIcon(markerLook(eligibility)),
              size: 20,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$vehicle · ${eligibility.label}',
                  style: Theme.of(context).textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  eligibility.reason,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant, height: 1.45),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotSummary extends StatelessWidget {
  const _SpotSummary({required this.spot, required this.vehicle});
  final ParkingSpot spot;
  final VehicleType vehicle;
  @override
  Widget build(BuildContext context) {
    final perVehicle = spot.zones.any(
      (zone) => [
        zone.scooterFeeNote,
        zone.heavyFeeNote,
        zone.carFeeNote,
      ].any((note) => note.trim().isNotEmpty),
    );
    final perZone = spot.zones.any((zone) => zone.feeNote.trim().isNotEmpty);
    final singleZone = perVehicle && spot.zones.length == 1
        ? spot.zones.single
        : null;
    final selectedFee = singleZone == null
        ? ''
        : vehicle == VehicleType.scooter
        ? singleZone.scooterFeeNote
        : singleZone.heavyFeeNote;
    final feeLabel = singleZone == null ? '收費資訊' : '${vehicle.label}費率';
    final feeValue = singleZone != null
        ? (selectedFee.trim().isEmpty ? '尚未提供' : selectedFee)
        : perVehicle
        ? '依車種與分區計費'
        : perZone
        ? '依分區計費'
        : spot.feeNote.trim().isEmpty
        ? '依現場公告'
        : spot.feeNote;
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
    final second = spot.isFacility
        ? (available == null || available < 0 ? '尚無即時資料' : '$available 格')
        : spot.spaceType.label;
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked =
            constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 18 ||
            (!perVehicle && !perZone && feeValue.length > 48);
        final facts = [
          _SummaryFact(
            label: feeLabel,
            value: feeValue,
            maxLines: perVehicle || perZone ? 2 : null,
          ),
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

class _SummaryFact extends StatelessWidget {
  const _SummaryFact({
    required this.label,
    required this.value,
    this.caption,
    this.maxLines = 2,
  });
  final String label, value;
  final String? caption;
  final int? maxLines;
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
        maxLines: maxLines,
        overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
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
  });

  final String label, value, secondary;

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

class _DetailActions extends StatelessWidget {
  const _DetailActions({required this.onNavigate, this.onSuggest});
  final VoidCallback onNavigate;
  final VoidCallback? onSuggest;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < 320 ||
          MediaQuery.textScalerOf(context).scale(14) > 18;
      final width = stacked || onSuggest == null
          ? constraints.maxWidth
          : (constraints.maxWidth - 12) / 2;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          SizedBox(
            width: width,
            child: AdaptiveButton(
              label: '導航到這裡',
              icon: Icons.navigation_outlined,
              onPressed: onNavigate,
            ),
          ),
          if (onSuggest != null)
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

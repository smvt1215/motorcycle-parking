import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../domain/eligibility.dart';
import '../../ui/adaptive/adaptive.dart';
import '../report/report_sheet.dart';

import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:share_plus/share_plus.dart';

import '../report/spot_suggestions.dart';
import 'spot_details.dart';
import 'spot_photos.dart';

/// Peek height: header, eligibility and actions, with the map left visible
/// above, the way map apps open a place.
const _peek = .42;

String _distanceLabel(double meters) => meters < 1000
    ? '${(meters / 10).round() * 10} 公尺'
    : '${(meters / 1000).toStringAsFixed(1)} 公里';

Future<void> showSpot(BuildContext context, AppStore store, ParkingSpot spot) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => _SpotSheet(store: store, spot: spot),
      detail: true,
    );

class _SpotSheet extends StatefulWidget {
  const _SpotSheet({required this.store, required this.spot});
  final AppStore store;
  final ParkingSpot spot;
  @override
  State<_SpotSheet> createState() => _SpotSheetState();
}

class _SpotSheetState extends State<_SpotSheet> {
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
        child: _sheet(context, store, spot, sourceUri, colors, photos),
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
      initialChildSize: _peek,
      minChildSize: _peek,
      maxChildSize: 1,
      snap: true,
      shouldCloseOnMinExtent: false,
      expand: false,
      builder: (ctx, scroll) => Listener(
        onPointerDown: (event) {
          start = event.position;
          dismissGesture =
              extent.isAttached &&
              extent.size <= _peek + .001 &&
              scroll.hasClients &&
              scroll.offset <= 0;
        },
        onPointerMove: (event) {
          if (start == null || !dismissGesture || closing) return;
          final delta = event.position - start!;
          if (delta.dy > 80 && delta.dy > delta.dx.abs() * 1.2) {
            closing = true;
            Navigator.pop(ctx);
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
              final (
                statusIcon,
                statusBackground,
                statusForeground,
              ) = switch (eligibility.status) {
                EligibilityStatus.allowed => (
                  Icons.check_circle_outline,
                  colors.primaryContainer,
                  colors.onPrimaryContainer,
                ),
                EligibilityStatus.conditional => (
                  Icons.info_outline,
                  colors.secondaryContainer,
                  colors.onSecondaryContainer,
                ),
                EligibilityStatus.notAllowed => (
                  Icons.block,
                  colors.errorContainer,
                  colors.onErrorContainer,
                ),
              };
              return ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
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
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          spot.name,
                          style: Theme.of(ctx).textTheme.headlineSmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: store.favorites.any((s) => s.id == spot.id)
                            ? '取消收藏'
                            : '收藏停車點',
                        onPressed: () =>
                            runAction(ctx, () => store.toggleFavorite(spot)),
                        icon: Icon(
                          store.favorites.any((s) => s.id == spot.id)
                              ? Icons.bookmark
                              : Icons.bookmark_outline,
                        ),
                      ),
                      Builder(
                        builder: (buttonContext) => IconButton.filledTonal(
                          tooltip: '分享停車點',
                          onPressed: () =>
                              runAction(ctx, () => share(buttonContext)),
                          icon: const Icon(Icons.ios_share),
                        ),
                      ),
                      IconButton.filledTonal(
                        tooltip: '關閉詳情',
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
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
                    key: const ValueKey('spot-subtitle'),
                    style: Theme.of(ctx).textTheme.bodyMedium
                        ?.copyWith(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: statusBackground,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(statusIcon, size: 22, color: statusForeground),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${store.vehicle.label} · ${eligibility.label}',
                                style: Theme.of(ctx).textTheme.titleSmall
                                    ?.copyWith(color: statusForeground),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                eligibility.reason,
                                style: Theme.of(ctx).textTheme.bodySmall
                                    ?.copyWith(color: statusForeground),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _DetailActions(
                    onNavigate: () =>
                        runAction(ctx, () => navigateTo(spot.lat, spot.lng)),
                    onSuggest: () => runAction(ctx, () async {
                      await extent.animateTo(
                        1,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                      );
                      if (ctx.mounted) {
                        await showSpotSuggestions(ctx, store, spot);
                      }
                    }),
                  ),
                  if (feedback != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(feedback!),
                    ),
                  if (photos.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    SpotPhotos(urls: spot.photoUrls, strip: true),
                  ],
                  _DetailSection(
                    title: '基本資訊',
                    children: [
                      _DetailField(label: '類型', value: facilitySummary(spot)),
                      _DetailField(
                        label: '費率',
                        value: [
                          spot.feeNote,
                          for (final zone in spot.zones)
                            if (zone.feeNote.trim().isNotEmpty)
                              '${zone.name}：${zone.feeNote}',
                        ].join('\n'),
                      ),
                      _DetailField(
                        label: '停放車種',
                        value: spot.zones.isEmpty
                            ? accessSummary(spot)
                            : [
                                for (final zone in spot.zones)
                                  '${zone.name.isEmpty ? '停放區域' : zone.name}：'
                                      '${zone.access == null ? '未確認' : '${zone.access!.label} · ${zone.access!.description}'}',
                              ].join('\n\n'),
                      ),
                    ],
                  ),
                  _DetailSection(
                    title: '位置與停放',
                    children: [
                      if (spot.isFacility)
                        _DetailField(label: '入口', value: spot.entranceNote),
                      _DetailField(
                        label: '停車指引',
                        value: [
                          if (spot.parkingGuide.trim().isNotEmpty)
                            spot.parkingGuide,
                          for (final zone in spot.zones)
                            if (zone.guide.trim().isNotEmpty)
                              '${zone.name}：${zone.guide}',
                        ].join('\n'),
                      ),
                      _DetailField(
                        label: '位置',
                        value: [
                          if (spot.address.trim().isNotEmpty) spot.address,
                          if (spot.roadSegment.trim().isNotEmpty)
                            spot.roadSegment,
                          'GPS ${spot.lat.toStringAsFixed(6)}, ${spot.lng.toStringAsFixed(6)}',
                        ].join('\n'),
                      ),
                      _DetailField(label: '特殊規則', value: spot.specialRules),
                    ],
                  ),
                  _DetailSection(
                    title: '現場補充',
                    children: [
                      // Usable photos already lead the sheet; here only
                      // the reason there are none.
                      if (photos.isEmpty) ...[
                        Text('照片', style: Theme.of(ctx).textTheme.labelLarge),
                        const SizedBox(height: 10),
                        SpotPhotos(urls: spot.photoUrls),
                        const SizedBox(height: 16),
                      ],
                      _DetailField(label: '備註', value: spot.note),
                    ],
                  ),
                  _DetailSection(
                    title: '資料資訊',
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
                        _DetailField(label: '授權說明', value: spot.licenseNote),
                      if (sourceUri != null)
                        TextButton(
                          onPressed: () => runAction(ctx, () async {
                            if (!await launchUrl(sourceUri)) {
                              throw StateError('無法開啟資料來源');
                            }
                          }),
                          child: const Text('查看點位資料來源'),
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
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: colors.outlineVariant),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}

class _DetailField extends StatelessWidget {
  const _DetailField({required this.label, required this.value});

  final String label, value;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelWidget = Text(
      label,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: colors.onSurfaceVariant),
    );
    final valueWidget = Text(
      value.trim().isEmpty ? '未提供' : value,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 18) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, const SizedBox(height: 6), valueWidget],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 88, child: labelWidget),
              const SizedBox(width: 16),
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

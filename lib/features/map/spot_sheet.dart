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
    final eligibility = store.eligible(spot);
    final colors = Theme.of(context).colorScheme;
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
    return DraggableScrollableSheet(
      key: const ValueKey('parking-spot-sheet'),
      controller: extent,
      initialChildSize: .5,
      minChildSize: .5,
      maxChildSize: 1,
      snap: true,
      shouldCloseOnMinExtent: false,
      expand: false,
      builder: (ctx, scroll) => Listener(
        onPointerDown: (event) {
          start = event.position;
          dismissGesture =
              extent.isAttached &&
              extent.size <= .501 &&
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
            builder: (ctx, _) => ListView(
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
                  children: [
                    Expanded(
                      child: Text(
                        spot.name,
                        style: Theme.of(ctx).textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '關閉詳情',
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          spot.spaceType.label,
                          spot.city,
                          spot.district,
                        ].where((value) => value.isNotEmpty).join(' · '),
                        style: Theme.of(ctx).textTheme.bodyMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
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
                      builder: (buttonContext) => IconButton(
                        tooltip: '分享停車點',
                        onPressed: () =>
                            runAction(ctx, () => share(buttonContext)),
                        icon: const Icon(Icons.ios_share),
                      ),
                    ),
                  ],
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
                const SizedBox(height: 12),
                _DetailRow(icon: Icons.payments_outlined, text: spot.feeNote),
                if (spot.available != null) ...[
                  const SizedBox(height: 8),
                  _DetailRow(
                    icon: Icons.local_parking,
                    text:
                        '機車剩餘 ${spot.available} 格${spot.scooterTotal == null ? '' : ' / ${spot.scooterTotal} 格'}',
                  ),
                ],
                const SizedBox(height: 16),
                _DetailActions(
                  onNavigate: () =>
                      runAction(ctx, () => navigateTo(spot.lat, spot.lng)),
                  onSuggest: spot.source == 'fixture'
                      ? null
                      : () => runAction(ctx, () async {
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
                const Divider(height: 32),
                if (spot.note.isNotEmpty) ...[
                  _DetailRow(icon: Icons.notes_outlined, text: spot.note),
                  const SizedBox(height: 20),
                ],
                Text('資料資訊', style: Theme.of(ctx).textTheme.titleSmall),
                const SizedBox(height: 12),
                _DetailRow(
                  icon: Icons.source_outlined,
                  text:
                      '來源：${store.demo || spot.source == 'fixture'
                          ? '範例資料'
                          : spot.source == 'tdx'
                          ? 'TDX 官方資料'
                          : spot.source == 'import'
                          ? '授權匯入：${spot.sourceName}'
                          : '社群回報'}',
                ),
                if (spot.licenseNote.isNotEmpty) Text('授權：${spot.licenseNote}'),
                if (spot.sourceUrl.isNotEmpty)
                  TextButton(
                    onPressed: () => runAction(ctx, () async {
                      if (!await launchUrl(Uri.parse(spot.sourceUrl))) {
                        throw StateError('無法開啟資料來源');
                      }
                    }),
                    child: const Text('查看點位資料來源'),
                  ),
                if (spot.updatedAt != null) ...[
                  const SizedBox(height: 8),
                  _DetailRow(
                    icon: Icons.update,
                    text:
                        '資料更新：${spot.updatedAt!.toLocal().toString().substring(0, 16)}',
                  ),
                ],
                if (spot.stale) ...[
                  const SizedBox(height: 8),
                  const _DetailRow(
                    icon: Icons.info_outline,
                    text: '停放資訊可能過時，請確認現場公告。',
                  ),
                ],
                if (spot.source == 'fixture')
                  const Padding(
                    padding: EdgeInsets.only(top: 16),
                    child: Text('此點為 TDX 範例，僅供預覽。'),
                  ),
                if (spot.source == 'tdx') ...[
                  const Divider(height: 32),
                  Text('補充重機停放資訊', style: Theme.of(ctx).textTheme.titleSmall),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final choice in ['allowed', 'denied', 'car_space'])
                        TextButton(
                          onPressed: () => runAction(ctx, () async {
                            final result = await store.submit({
                              'action': 'annotation',
                              'source_id': spot.id,
                              'heavy_access': choice,
                            });
                            if (ctx.mounted) showMessage(ctx, result);
                          }),
                          child: Text(
                            choice == 'allowed'
                                ? '重機可停'
                                : choice == 'denied'
                                ? '重機不可停'
                                : '須停汽車格',
                          ),
                        ),
                    ],
                  ),
                ],
                if (!store.canReport && spot.source != 'fixture')
                  TextButton(
                    onPressed: () => showSettings(ctx, store),
                    child: const Text('登入後提出修改建議'),
                  ),
              ],
            ),
          ),
        ),
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
                icon: Icons.edit_outlined,
                onPressed: onSuggest,
              ),
            ),
        ],
      );
    },
  );
}

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin_theme.dart';
import 'review_controller.dart';
import 'review_models.dart';
import 'review_page.dart';

/// Deleted spots (#200): off the map at once, restorable for 14 days, then
/// purged. Purged official spots are listed too: imports skip them until
/// an admin releases one.
class HiddenSpotsPage extends StatefulWidget {
  const HiddenSpotsPage({super.key, required this.review});
  final ReviewController review;

  @override
  State<HiddenSpotsPage> createState() => _HiddenSpotsPageState();
}

class _HiddenSpotsPageState extends State<HiddenSpotsPage> {
  ReviewController get review => widget.review;

  @override
  void initState() {
    super.initState();
    // Loading notifies listeners; never during this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) => review.loadHidden());
  }

  Future<void> _restore(ReviewSpot spot) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await review.setHidden(spot, false) || !mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        undoSnackBar(
          context,
          '已復原：${spot.name}',
          review.undoWindow,
          () => review.setHidden(spot, true),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    return ListenableBuilder(
      listenable: review,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 680;
          return ListView(
            padding: EdgeInsets.fromLTRB(
              compact ? 12 : 20,
              compact ? 12 : 20,
              compact ? 12 : 20,
              48,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surface,
                      border: Border.all(color: colors.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            compact ? 8 : 16,
                            8,
                            8,
                            0,
                          ),
                          child: Row(
                            children: [
                              TextButton.icon(
                                onPressed: () => context.go('/review'),
                                icon: const Icon(Icons.arrow_back),
                                label: const Text('返回待審回報'),
                              ),
                              const Spacer(),
                              IconButton(
                                tooltip: '重新載入',
                                onPressed: review.hiddenLoading
                                    ? null
                                    : review.loadHidden,
                                icon: const Icon(Icons.refresh),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            compact ? 16 : 24,
                            4,
                            compact ? 16 : 24,
                            16,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  '已刪除的點位',
                                  style: text.headlineMedium?.copyWith(
                                    fontSize: compact ? 22 : 26,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 640,
                                ),
                                child: Text(
                                  '騎士已看不到這些點位。刪除後 14 天內可以復原，之後永久刪除，無法復原。'
                                  '復原後，官方點直接重新顯示；社群點回到「待確認」，並清除先前的「已不存在」回報；刪除時一起結案的回報不會重開。',
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              if (review.hiddenError != null) ...[
                                const SizedBox(height: 12),
                                AdminNotice(review.hiddenError!, error: true),
                              ],
                            ],
                          ),
                        ),
                        Divider(height: 1, color: colors.outlineVariant),
                        if (!review.hiddenLoaded)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: review.hiddenLoading
                                  ? const CircularProgressIndicator()
                                  : FilledButton(
                                      onPressed: review.loadHidden,
                                      child: const Text('重新載入'),
                                    ),
                            ),
                          )
                        else if (review.hidden.isEmpty)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 16 : 24,
                              28,
                              compact ? 16 : 24,
                              32,
                            ),
                            child: Text('目前沒有已刪除的點位。', style: text.titleMedium),
                          )
                        else
                          for (final (i, spot) in review.hidden.indexed) ...[
                            if (i > 0)
                              Divider(height: 1, color: colors.outlineVariant),
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 16 : 24,
                                vertical: 12,
                              ),
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: compact
                                          ? constraints.maxWidth
                                          : 600,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          spot.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          '${spot.city}${spot.district}，${spot.sourceLabel}',
                                          style: muted,
                                        ),
                                        if (spot.deletedAt case final at?)
                                          Text(
                                            '已刪除，${purgeDaysLeft(at, review.now())} 天後永久刪除',
                                            key: ValueKey(
                                              'purge-days-${spot.sourceId}',
                                            ),
                                            style: muted,
                                          ),
                                      ],
                                    ),
                                  ),
                                  OutlinedButton(
                                    key: ValueKey('restore-${spot.sourceId}'),
                                    onPressed:
                                        review.changing.contains(spot.sourceId)
                                        ? null
                                        : () => _restore(spot),
                                    child: const Text('復原'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        if (review.hiddenLoaded &&
                            review.purged.isNotEmpty) ...[
                          Divider(height: 1, color: colors.outlineVariant),
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              compact ? 16 : 24,
                              16,
                              compact ? 16 : 24,
                              4,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  child: Text(
                                    '已永久刪除的官方點',
                                    style: text.titleMedium,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '匯入時會跳過這些官方資料編號。要讓下次匯入帶回來，按「解除」。',
                                  style: muted,
                                ),
                              ],
                            ),
                          ),
                          for (final p in review.purged)
                            Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: compact ? 16 : 24,
                                vertical: 8,
                              ),
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 16,
                                runSpacing: 8,
                                children: [
                                  ConstrainedBox(
                                    constraints: BoxConstraints(
                                      maxWidth: compact
                                          ? constraints.maxWidth
                                          : 600,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          p.name.isEmpty ? '（未命名）' : p.name,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        Text(
                                          p.sourceId.isEmpty
                                              ? '官方點'
                                              : '官方資料編號 ${p.sourceId}',
                                          style: muted,
                                        ),
                                      ],
                                    ),
                                  ),
                                  OutlinedButton(
                                    key: ValueKey('release-${p.officialId}'),
                                    onPressed:
                                        review.changing.contains(p.officialId)
                                        ? null
                                        : () => review.releasePurged(p),
                                    child: const Text('解除'),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    ),
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

import 'package:material_ui/material_ui.dart';

import '../../models/spot_history.dart';
import '../admin_gateway.dart';
import '../admin_theme.dart';
import '../review/review_models.dart' show ResolutionKind;

/// Which entries the timeline lists (C6 canvas EditHistory).
enum HistoryFilter {
  all('全部'),
  admin('管理員'),
  report('車友回報'),
  import('匯入');

  const HistoryFilter(this.label);
  final String label;

  bool shows(HistoryEntry e) => switch (this) {
    all => true,
    admin => e.kind == HistoryKind.admin,
    report => e.kind == HistoryKind.report,
    import => e.kind == HistoryKind.import,
  };
}

/// Opens a spot's edit history over the spots page.
Future<void> showSpotHistoryPage(
  BuildContext context,
  AdminGateway gateway, {
  required String sourceId,
  required String name,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) =>
        SpotHistoryPage(gateway: gateway, sourceId: sourceId, name: name),
  ),
);

/// 編輯紀錄 (#141): one timeline of administrators' writes, decided rider
/// reports and imports, newest first, each with its time, who, the kinds of
/// data and what they were and became; a decided report links to what the
/// rider sent.
class SpotHistoryPage extends StatefulWidget {
  const SpotHistoryPage({
    super.key,
    required this.gateway,
    required this.sourceId,
    required this.name,
  });
  final AdminGateway gateway;
  final String sourceId, name;

  @override
  State<SpotHistoryPage> createState() => _SpotHistoryPageState();
}

class _SpotHistoryPageState extends State<SpotHistoryPage> {
  late Future<List<HistoryEntry>> entries = _load();
  HistoryFilter filter = HistoryFilter.all;

  Future<List<HistoryEntry>> _load() =>
      widget.gateway.spotHistory(widget.sourceId);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: AdminColors.asphalt,
        foregroundColor: AdminColors.white,
        leading: IconButton(
          tooltip: '返回點位',
          icon: const Icon(Icons.chevron_left, size: 28),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('編輯紀錄'),
      ),
      body: FutureBuilder<List<HistoryEntry>>(
        future: entries,
        builder: (context, snapshot) {
          final all = snapshot.data;
          final shown = all?.where(filter.shows).toList();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                key: const ValueKey('spot-history'),
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 32),
                children: [
                  Text(
                    widget.name,
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (all != null)
                    Text(
                      '共 ${all.length} 筆，最新在上',
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Semantics(
                    container: true,
                    label: '篩選紀錄',
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in HistoryFilter.values)
                          FilterChip(
                            key: ValueKey('history-filter-${f.name}'),
                            label: Text(f.label),
                            selected: filter == f,
                            showCheckmark: false,
                            materialTapTargetSize: MaterialTapTargetSize.padded,
                            onSelected: (_) => setState(() => filter = f),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (snapshot.hasError) ...[
                    const AdminNotice('編輯紀錄讀取失敗，請稍後再試。', error: true),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton(
                        onPressed: () => setState(() {
                          entries = _load();
                        }),
                        child: const Text('重新載入'),
                      ),
                    ),
                  ] else if (shown == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (shown.isEmpty)
                    Text(
                      all!.isEmpty ? '這個點位還沒有編輯紀錄。' : '沒有符合篩選的紀錄。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    )
                  else
                    for (final (i, e) in shown.indexed)
                      _TimelineItem(
                        key: ValueKey('history-entry-$i'),
                        entry: e,
                        last: i == shown.length - 1,
                      ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

String _time(DateTime at) => at.toLocal().toString().substring(0, 16);

/// Who made [e] and how, after its time (「管理員 小哲・採納車友建議」).
String historyMeta(HistoryEntry e) {
  final admin = switch (e.actorName) {
    null => null,
    final n when n.trim().isEmpty => '管理員',
    final n => '管理員 $n',
  };
  final parts = switch (e.kind) {
    HistoryKind.report when e.report == null => ['車友新增'],
    HistoryKind.report => [
      e.report!.accepted ? '車友回報（已採納）' : '車友回報（已駁回）',
      ?admin,
    ],
    HistoryKind.import => [
      e.action == 'convert_fee'
          ? '費率轉換'
          : e.sourceName == null
          ? '匯入'
          : '匯入（${e.sourceName}）',
    ],
    HistoryKind.admin => [
      admin ?? '管理員',
      ?switch (e.action) {
        'create_spot' => '新增點位',
        'hide_spot' => '隱藏點位',
        'restore_spot' => '恢復顯示',
        'promote_spot' => '改為官方點',
        'promoted_from' => '由社群點改為官方點',
        'clear_contributor_name' => '清除回報者名稱',
        _ => null,
      },
    ],
  };
  return [_time(e.at), ...parts].join('・');
}

/// The changes worth a row: the fee speaks through its sentence when both
/// changed.
List<HistoryChange> shownChanges(HistoryEntry e) {
  final fields = {for (final c in e.changes) c.field};
  return [
    for (final c in e.changes)
      if (!(c.field == 'fee' && fields.contains('fee_note'))) c,
  ];
}

class _TimelineItem extends StatelessWidget {
  const _TimelineItem({super.key, required this.entry, required this.last});
  final HistoryEntry entry;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final changes = shownChanges(entry);
    final ink = colors.onSurface;
    final dot = switch (entry.kind) {
      HistoryKind.admin => BoxDecoration(
        color: colors.primary,
        shape: BoxShape.circle,
      ),
      HistoryKind.import => BoxDecoration(color: ink, shape: BoxShape.circle),
      HistoryKind.report => BoxDecoration(
        color: colors.surface,
        shape: BoxShape.circle,
        border: Border.all(color: ink, width: 2),
      ),
    };
    final report = entry.report;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 20,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(width: 12, height: 12, decoration: dot),
                if (!last)
                  Expanded(
                    child: Container(width: 2, color: colors.outlineVariant),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    historyMeta(entry),
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.title(),
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (changes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    _Diff(changes: changes),
                  ],
                  if (entry.note.trim().isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('處理說明：${entry.note.trim()}', style: text.bodyMedium),
                  ],
                  if (report != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => showReportDialog(context, report),
                        child: const Text('看原始回報'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 原本 → 改成 per field, on white like the canvas.
class _Diff extends StatelessWidget {
  const _Diff({required this.changes});
  final List<HistoryChange> changes;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.bodyMedium;
    final muted = text?.copyWith(color: colors.onSurfaceVariant);
    final many = changes.length > 1;
    Widget row(String label, String value, {bool before = false}) => Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 40, child: Text(label, style: muted)),
          Expanded(
            child: Text(
              value,
              style: before
                  ? muted?.copyWith(decoration: TextDecoration.lineThrough)
                  : text,
            ),
          ),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, c) in changes.indexed) ...[
            if (i > 0) const SizedBox(height: 6),
            if (many)
              Text(
                historyFieldLabel(c.field),
                style: muted?.copyWith(fontWeight: FontWeight.w700),
              ),
            if (c.hasBefore)
              row('原本', historyValueText(c.field, c.before), before: true),
            row('改成', historyValueText(c.field, c.after)),
          ],
        ],
      ),
    );
  }
}

/// What the rider sent, and how it was decided.
Future<void> showReportDialog(BuildContext context, HistoryReport r) {
  final kind = ResolutionKind.values
      .where((k) => k.name == r.resolutionKind)
      .firstOrNull;
  final proposed = r.proposed ?? const <String, dynamic>{};
  final rows = <(String, String)>[
    if (r.createdAt case final at?) ('送出時間', _time(at)),
    ('回報內容', r.reason.trim().isEmpty ? '（沒有摘要）' : r.reason.trim()),
    for (final MapEntry(:key, :value) in proposed.entries)
      ('建議${historyFieldLabel(key)}', historyValueText(key, value)),
    if (r.note.trim().isNotEmpty) ('車友說明', r.note.trim()),
    if (r.evidenceUrl case final url?) ('公告連結', url),
    (
      '處理結果',
      [
        r.accepted ? '已採納' : '已駁回',
        ?kind?.label,
        if (r.resolutionNote.trim().isNotEmpty) r.resolutionNote.trim(),
      ].join('・'),
    ),
  ];
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('原始回報'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows) ...[
              Text(
                label,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              SelectableText(value),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('關閉'),
        ),
      ],
    ),
  );
}

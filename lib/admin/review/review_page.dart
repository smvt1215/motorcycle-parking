import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/parking.dart';
import '../admin_controller.dart';
import '../admin_theme.dart';
import 'review_controller.dart';
import 'review_map.dart';
import 'review_models.dart';

/// Below this width the queue and the report are separate screens.
const reviewCompactWidth = 680.0;
const _wideWidth = 1040.0;

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.admin,
    required this.review,
    required this.selectedId,
    required this.mapBuilder,
  });
  final AdminController admin;
  final ReviewController review;

  /// From `/review/:id`; null on `/review`.
  final String? selectedId;
  final ReviewMapBuilder mapBuilder;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  /// One resolution note per report, so switching never clears text mid-build.
  final _notes = <String, TextEditingController>{};

  ReviewController get review => widget.review;

  String? _shownError;
  int _shownConflicts = 0;

  /// A refused write invalidates its "undo" toast; take it down at once.
  void _reviewChanged() {
    final error = review.error;
    final conflicts = review.conflicts.length;
    if (mounted &&
        ((error != null && error != _shownError) ||
            conflicts > _shownConflicts)) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
    _shownError = error;
    _shownConflicts = conflicts;
  }

  @override
  void initState() {
    super.initState();
    review.addListener(_reviewChanged);
    // Loading notifies listeners; never during this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!review.loaded && !review.loading) review.load();
    });
  }

  @override
  void dispose() {
    review.removeListener(_reviewChanged);
    for (final c in _notes.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _open(String? id) => context.go(id == null ? '/review' : '/review/$id');

  Future<void> _reload() async {
    await review.flush();
    await Future.wait([review.load(), widget.admin.refreshCount()]);
  }

  Future<void> _decide(ReviewReport report, ReviewDecision decision) async {
    final messenger = ScaffoldMessenger.of(context);
    // The page is rebuilt for the next report's route; keep the router.
    final router = GoRouter.of(context);
    final name = review.spots[report.sourceId]?.name ?? report.title;
    final before = review.pending;
    final note = _notes[report.id]?.text.trim() ?? '';
    // Shown the newer values, the admin's second accept overrides the conflict.
    final next = await review.decide(
      report,
      decision,
      note,
      force: review.conflicts.contains(report.id),
    );
    if (!mounted || identical(review.pending, before)) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        undoSnackBar(context, '${decision.done}：$name', review.undoWindow, () {
          final id = review.undo();
          if (id != null) router.go('/review/$id');
        }),
      );
    _open(next);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: review,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < reviewCompactWidth;
        final visible = review.visible;
        var selected = review.byId(widget.selectedId);
        if (selected == null && widget.selectedId == null && !compact) {
          selected = visible.firstOrNull;
        }
        final queue = _QueuePane(
          admin: widget.admin,
          review: review,
          selectedId: selected?.id,
          compact: compact,
          onPick: _open,
          onReload: _reload,
        );
        final Widget detail;
        if (!review.loaded) {
          detail = _Status(
            loading: review.loading,
            error: review.loadError,
            onRetry: _reload,
          );
        } else if (selected != null) {
          detail = _ReviewDetail(
            key: ValueKey(selected.id),
            report: selected,
            review: review,
            compact: compact,
            note: _notes.putIfAbsent(selected.id, TextEditingController.new),
            mapBuilder: widget.mapBuilder,
            onDecide: (d) => _decide(selected!, d),
            onBack: () => _open(null),
          );
        } else {
          detail = _Done(
            missing: widget.selectedId != null,
            compact: compact,
            onBack: () => _open(null),
          );
        }
        if (compact) {
          return widget.selectedId == null ? queue : detail;
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth >= _wideWidth ? 360 : 300,
                child: _Pane(child: queue),
              ),
              const SizedBox(width: 20),
              Expanded(child: _Pane(child: detail)),
            ],
          ),
        );
      },
    ),
  );
}

/// Floats above the review action bar so the next decision stays reachable.
SnackBar undoSnackBar(
  BuildContext context,
  String message,
  Duration duration,
  VoidCallback onUndo,
) {
  final width = MediaQuery.sizeOf(context).width;
  final side = width > 552 ? (width - 520) / 2 : 16.0;
  return SnackBar(
    content: Text(message),
    duration: duration,
    behavior: SnackBarBehavior.floating,
    margin: EdgeInsets.fromLTRB(
      side,
      0,
      side,
      width < reviewCompactWidth ? 150 : 96,
    ),
    action: SnackBarAction(label: '復原', onPressed: onUndo),
  );
}

class _Pane extends StatelessWidget {
  const _Pane({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(11), child: child),
    );
  }
}

class _QueuePane extends StatelessWidget {
  const _QueuePane({
    required this.admin,
    required this.review,
    required this.selectedId,
    required this.compact,
    required this.onPick,
    required this.onReload,
  });
  final AdminController admin;
  final ReviewController review;
  final String? selectedId;
  final bool compact;
  final ValueChanged<String> onPick;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final visible = review.visible;
    final filters = [
      for (final kind in [null, ...ReviewKind.values])
        _FilterButton(
          label: kind?.label ?? '全部',
          count: review.countOf(kind),
          selected: review.filter == kind,
          onPressed: () => review.setFilter(kind),
        ),
    ];
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('待審回報', style: text.titleLarge),
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/review/hidden'),
                  child: const Text('已隱藏的點位'),
                ),
                IconButton(
                  tooltip: '重新載入佇列',
                  onPressed: review.loading ? null : onReload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          if (admin.countError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: AdminNotice(admin.countError!, error: true),
            ),
          Semantics(
            label: '依回報類型篩選',
            container: true,
            // One row at every width: a wrapped row reads as two groups.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  for (final f in filters) ...[f, const SizedBox(width: 6)],
                ],
              ),
            ),
          ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: !review.loaded
                ? const SizedBox()
                : visible.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(18, 28, 18, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          review.filter == null ? '目前沒有待審回報' : '這個分類沒有待審回報',
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          review.filter == null
                              ? '騎士送出修改建議或不存在回報後，會出現在這裡。'
                              : '切換到「全部」可以查看其他類型。',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.outlineVariant),
                    itemBuilder: (context, i) => _QueueItem(
                      report: visible[i],
                      spot: review.spots[visible[i].sourceId],
                      conflict: review.conflicts.contains(visible[i].id),
                      age: relativeAge(visible[i].createdAt, review.now()),
                      selected: visible[i].id == selectedId && !compact,
                      onPressed: () => onPick(visible[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const StadiumBorder(),
          foregroundColor: selected ? colors.surface : colors.onSurface,
          backgroundColor: selected ? colors.onSurface : null,
        ),
        child: Text('$label $count'),
      ),
    );
  }
}

class _QueueItem extends StatelessWidget {
  const _QueueItem({
    required this.report,
    required this.spot,
    required this.conflict,
    required this.age,
    required this.selected,
    required this.onPressed,
  });
  final ReviewReport report;
  final ReviewSpot? spot;
  final bool conflict;
  final String age;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey('report-${report.id}'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(),
          foregroundColor: colors.onSurface,
          backgroundColor: selected
              ? colors.primary.withValues(alpha: .1)
              : null,
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      report.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      spot?.name ?? '找不到點位',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      spot == null
                          ? report.sourceId
                          : '${spot!.city}${spot!.district}，${spot!.official ? '官方點' : '社群點'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                    if (conflict)
                      Text(
                        '資料已更新，需重新檢視',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: colors.error,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(age, style: muted),
            ],
          ),
        ),
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({
    required this.loading,
    required this.error,
    required this.onRetry,
  });
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: loading
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AdminNotice(error ?? '尚未載入待審回報。', error: error != null),
                const SizedBox(height: 16),
                FilledButton(onPressed: onRetry, child: const Text('重新載入')),
              ],
            ),
    ),
  );
}

class _Done extends StatelessWidget {
  const _Done({
    required this.missing,
    required this.compact,
    required this.onBack,
  });
  final bool missing;
  final bool compact;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
        children: [
          Semantics(
            header: true,
            child: Text(
              missing ? '這筆回報已處理或不存在' : '待審回報都處理完了',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            missing
                ? '可能已由其他人處理，或網址有誤。回到佇列查看其他回報。'
                : '騎士送出新的修改建議或不存在回報後，會出現在佇列。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (missing || compact) ...[
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back),
                label: const Text('返回佇列'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReviewDetail extends StatelessWidget {
  const _ReviewDetail({
    super.key,
    required this.report,
    required this.review,
    required this.compact,
    required this.note,
    required this.mapBuilder,
    required this.onDecide,
    required this.onBack,
  });
  final ReviewReport report;
  final ReviewController review;
  final bool compact;
  final TextEditingController note;
  final ReviewMapBuilder mapBuilder;
  final ValueChanged<ReviewDecision> onDecide;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final spot = review.spots[report.sourceId];
    final editing = review.editing(report.id);
    final conflict = review.conflicts.contains(report.id);
    final proposal = spot == null
        ? <String, dynamic>{}
        : initialProposal(report, spot);
    final patch = spot == null
        ? <String, dynamic>{}
        : applicablePatch(proposal, spot);
    final ignored = spot == null ? <String>[] : ignoredKeys(proposal, spot);
    final rows = editing ? review.draft : patch;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 14);
    final pad = compact ? 16.0 : 24.0;
    final proposedLat = (rows['lat'] as num?)?.toDouble();
    final proposedLng = (rows['lng'] as num?)?.toDouble();

    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 22, pad, 24),
              children: [
                if (compact)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: onBack,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                      icon: const Icon(Icons.arrow_back),
                      label: Text('返回佇列（${review.countOf(review.filter)}）'),
                    ),
                  ),
                Text(
                  report.kind == ReviewKind.gone
                      ? report.title
                      : '${report.title}的修改建議',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(
                  header: true,
                  child: Text(
                    spot?.name ?? '找不到這個點位',
                    style: text.headlineMedium?.copyWith(
                      fontSize: compact ? 22 : 26,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    if (spot != null) ...[
                      Text('${spot.city}${spot.district}', style: muted),
                      Text(spot.sourceLabel, style: muted),
                    ] else
                      Text(report.sourceId, style: muted),
                    Text(
                      '${relativeAge(report.createdAt, review.now())}回報',
                      style: muted,
                    ),
                  ],
                ),
                if (spot != null) ...[
                  const SizedBox(height: 16),
                  _MapFrame(
                    height: compact ? 160 : 200,
                    spot: spot,
                    child: mapBuilder(
                      context,
                      ReviewMapData(
                        lat: spot.lat,
                        lng: spot.lng,
                        proposedLat: proposedLat,
                        proposedLng: proposedLng,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  child: Text(
                    '建議變更',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (spot == null)
                  const AdminNotice('找不到這個點位，可能已刪除或不是官方／社群點，只能駁回。')
                else if (rows.isEmpty && !editing)
                  const AdminNotice('這筆回報沒有可直接套用的建議。請依騎士的說明「修改後套用」，或結案、駁回。')
                else ...[
                  if (conflict) ...[
                    const AdminNotice(
                      '騎士送出後，這個點位已被修改。比對「送出時」與「目前」後再決定；仍要套用會記錄在稽核紀錄。',
                      error: true,
                    ),
                    const SizedBox(height: 10),
                  ],
                  LayoutBuilder(
                    builder: (context, c) => _DiffTable(
                      report: report,
                      spot: spot,
                      rows: rows,
                      editing: editing,
                      stacked: c.maxWidth < 520,
                      base: conflict ? report.baseSpot : null,
                      review: review,
                    ),
                  ),
                ],
                if (ignored.isNotEmpty && !editing) ...[
                  const SizedBox(height: 10),
                  AdminNotice(
                    '另有無法在這裡修改的建議：${ignored.map((k) => '$k＝${proposal[k]}').join('、')}',
                  ),
                ],
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  child: Text(
                    '騎士的說明',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Text(
                    report.riderText ?? '騎士沒有補充說明。',
                    style: report.riderText == null ? muted : null,
                  ),
                ),
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: TextField(
                    key: const ValueKey('resolution-note'),
                    controller: note,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '處理說明（選填）',
                      helperText: '會和處理人、時間一起記錄在稽核紀錄。',
                      hintText: '例如：已比對街景與停管處公告',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text('套用後地圖上的點位會立即更新；駁回不會改動點位。', style: muted),
              ],
            ),
          ),
          _ActionBar(
            compact: compact,
            editing: editing,
            hasSpot: spot != null,
            hasPatch: patch.isNotEmpty,
            busy: review.writing,
            conflict: conflict,
            error: review.error,
            onDecide: onDecide,
            onEdit: () => review.startEdit(report),
            onCancelEdit: review.cancelEdit,
          ),
        ],
      ),
    );
  }
}

class _MapFrame extends StatelessWidget {
  const _MapFrame({
    required this.height,
    required this.spot,
    required this.child,
  });
  final double height;
  final ReviewSpot spot;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '小地圖：${spot.name}，周圍 15 公尺為重複判斷範圍',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Color(0xff3b4046))),
            Positioned.fill(child: child),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  color: AdminColors.asphalt.withValues(alpha: .82),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    children: [
                      const Text(
                        '圈內 15 m 的同類型點會被當成重複',
                        style: TextStyle(
                          color: Color(0xfff2f2f0),
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        '${spot.lat.toStringAsFixed(6)}, ${spot.lng.toStringAsFixed(6)}',
                        style: const TextStyle(
                          color: Color(0xfff2f2f0),
                          fontSize: 13,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DiffTable extends StatelessWidget {
  const _DiffTable({
    required this.report,
    required this.spot,
    required this.rows,
    required this.editing,
    required this.stacked,
    required this.review,
    this.base,
  });
  final ReviewReport report;
  final ReviewSpot spot;
  final Map<String, dynamic> rows;
  final bool editing;
  final bool stacked;
  final ReviewController review;

  /// The spot when the report was sent; shown only for a version conflict.
  final Map<String, dynamic>? base;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant);
    final keys = [
      for (final f in reviewFields)
        if (rows.containsKey(f.key)) f.key,
    ];
    final addable = [
      for (final f in reviewFields)
        if (spot.allows(f.key) && !rows.containsKey(f.key)) f,
    ];
    Widget cell(String key) {
      final current = spot.values[key];
      final value = rows[key];
      if (editing) {
        return Row(
          children: [
            Expanded(
              child: _FieldEditor(
                key: ValueKey('edit-${report.id}-$key'),
                field: reviewField(key)!,
                value: value,
                official: spot.official,
                onChanged: (v) => review.setDraft(key, v),
              ),
            ),
            IconButton(
              tooltip: '不修改${reviewField(key)!.label}',
              onPressed: () => review.removeDraft(key),
              icon: const Icon(Icons.close),
            ),
          ],
        );
      }
      if (value == current) return Text('不變', style: muted);
      return Align(
        alignment: Alignment.centerLeft,
        child: ChangeBand(formatValue(key, value)),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!stacked)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: DefaultTextStyle.merge(
                style: muted.copyWith(fontSize: 13),
                child: Row(
                  children: [
                    const Expanded(flex: 8, child: Text('欄位')),
                    if (base != null) ...[
                      const SizedBox(width: 12),
                      const Expanded(flex: 10, child: Text('送出時')),
                    ],
                    const SizedBox(width: 12),
                    const Expanded(flex: 10, child: Text('目前')),
                    const SizedBox(width: 12),
                    const Expanded(flex: 13, child: Text('建議')),
                  ],
                ),
              ),
            ),
          for (final (i, key) in keys.indexed)
            Container(
              decoration: BoxDecoration(
                border: i == 0 && stacked
                    ? null
                    : Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          reviewField(key)!.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        if (base != null) ...[
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 56,
                                child: Text('送出時', style: muted),
                              ),
                              Expanded(
                                child: Text(formatValue(key, base![key])),
                              ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: base == null ? 44 : 56,
                              child: Text('目前', style: muted),
                            ),
                            Expanded(
                              child: Text(formatValue(key, spot.values[key])),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            SizedBox(
                              width: base == null ? 44 : 56,
                              child: Text('建議', style: muted),
                            ),
                            Expanded(child: cell(key)),
                          ],
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          flex: 8,
                          child: Text(reviewField(key)!.label, style: muted),
                        ),
                        if (base != null) ...[
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 10,
                            child: Text(formatValue(key, base![key])),
                          ),
                        ],
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 10,
                          child: Text(formatValue(key, spot.values[key])),
                        ),
                        const SizedBox(width: 12),
                        Expanded(flex: 13, child: cell(key)),
                      ],
                    ),
            ),
          if (editing && addable.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                border: keys.isEmpty
                    ? null
                    : Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('add-field-${keys.length}'),
                    decoration: const InputDecoration(labelText: '加入要修改的欄位'),
                    items: [
                      for (final f in addable)
                        DropdownMenuItem(value: f.key, child: Text(f.label)),
                    ],
                    onChanged: (k) {
                      if (k != null) review.setDraft(k, spot.values[k]);
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The "changed" mark of the admin UI: a yellow band with slanted ends.
class ChangeBand extends StatelessWidget {
  const ChangeBand(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: const _SlantClipper(),
    child: Container(
      color: AdminColors.yellow,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Text(
        text,
        style: const TextStyle(
          color: AdminColors.asphalt,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _SlantClipper extends CustomClipper<Path> {
  const _SlantClipper();
  @override
  Path getClip(Size size) => Path()
    ..moveTo(7, 0)
    ..lineTo(size.width, 0)
    ..lineTo(size.width - 7, size.height)
    ..lineTo(0, size.height)
    ..close();
  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _FieldEditor extends StatelessWidget {
  const _FieldEditor({
    super.key,
    required this.field,
    required this.value,
    required this.official,
    required this.onChanged,
  });
  final ReviewField field;
  final Object? value;
  final bool official;
  final ValueChanged<Object?> onChanged;

  InputDecoration _decoration(BuildContext context) => InputDecoration(
    labelText: '修改為',
    isDense: true,
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AdminColors.yellow, width: 2),
    ),
  );

  @override
  Widget build(BuildContext context) => switch (field.input) {
    FieldInput.text => TextFormField(
      initialValue: value as String? ?? '',
      maxLength: field.maxLength,
      maxLines: field.key == 'name' ? 1 : null,
      decoration: _decoration(context),
      onChanged: onChanged,
    ),
    FieldInput.coordinate => TextFormField(
      initialValue: (value as num?)?.toString() ?? '',
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: _decoration(context),
      onChanged: (v) => onChanged(double.tryParse(v.trim()) ?? v),
    ),
    FieldInput.spaceType => DropdownButtonFormField<String>(
      initialValue: value as String?,
      isExpanded: true,
      decoration: _decoration(context),
      items: [
        for (final t in SpaceType.values)
          DropdownMenuItem(value: t.name, child: Text(t.label)),
      ],
      onChanged: onChanged,
    ),
    FieldInput.triState => DropdownButtonFormField<int>(
      initialValue: switch (value) {
        true => 1,
        false => 0,
        _ => -1,
      },
      isExpanded: true,
      decoration: _decoration(context),
      items: [
        const DropdownMenuItem(value: 1, child: Text('可停')),
        const DropdownMenuItem(value: 0, child: Text('不可停')),
        if (!(official && field.key == 'heavy_allowed'))
          const DropdownMenuItem(value: -1, child: Text('未確認')),
      ],
      onChanged: (v) => onChanged(switch (v) {
        1 => true,
        0 => false,
        _ => null,
      }),
    ),
    FieldInput.hiddenFlag => DropdownButtonFormField<bool>(
      initialValue: value == true,
      isExpanded: true,
      decoration: _decoration(context),
      items: const [
        DropdownMenuItem(value: false, child: Text('顯示')),
        DropdownMenuItem(value: true, child: Text('隱藏')),
      ],
      onChanged: onChanged,
    ),
    FieldInput.visibility => DropdownButtonFormField<String>(
      initialValue: value as String?,
      isExpanded: true,
      decoration: _decoration(context),
      items: const [
        DropdownMenuItem(value: 'pending', child: Text('顯示（待確認）')),
        DropdownMenuItem(value: 'confirmed', child: Text('顯示（已確認）')),
        DropdownMenuItem(value: 'hidden', child: Text('隱藏')),
      ],
      onChanged: onChanged,
    ),
  };
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.compact,
    required this.editing,
    required this.hasSpot,
    required this.hasPatch,
    required this.busy,
    required this.conflict,
    required this.error,
    required this.onDecide,
    required this.onEdit,
    required this.onCancelEdit,
  });
  final bool compact, editing, hasSpot, hasPatch, busy, conflict;
  final String? error;
  final ValueChanged<ReviewDecision> onDecide;
  final VoidCallback onEdit, onCancelEdit;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final primary = !hasSpot
        ? null
        : editing
        ? FilledButton(
            onPressed: busy
                ? null
                : () => onDecide(ReviewDecision.acceptEdited),
            child: Text(conflict ? '仍要套用修改' : '套用修改'),
          )
        : hasPatch
        ? FilledButton(
            onPressed: busy ? null : () => onDecide(ReviewDecision.accept),
            child: Text(conflict ? '仍要套用建議' : '套用建議'),
          )
        : FilledButton(
            onPressed: busy ? null : onEdit,
            child: const Text('修改後套用'),
          );
    final secondary = [
      if (hasSpot && editing)
        OutlinedButton(onPressed: onCancelEdit, child: const Text('取消修改'))
      else if (hasSpot && hasPatch)
        OutlinedButton(
          onPressed: busy ? null : onEdit,
          child: const Text('修改後套用'),
        )
      else if (hasSpot)
        OutlinedButton(
          onPressed: busy ? null : () => onDecide(ReviewDecision.close),
          child: const Text('結案不修改'),
        ),
    ];
    final reject = OutlinedButton(
      onPressed: busy ? null : () => onDecide(ReviewDecision.reject),
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.error,
        side: BorderSide(color: colors.error),
      ),
      child: const Text('駁回'),
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(
        compact ? 16 : 24,
        12,
        compact ? 16 : 24,
        12,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (error != null) ...[
            AdminNotice(error!, error: true),
            const SizedBox(height: 10),
          ],
          if (compact) ...[
            ?primary,
            if (primary != null) const SizedBox(height: 8),
            Row(
              children: [
                for (final b in secondary) ...[
                  Expanded(child: b),
                  const SizedBox(width: 8),
                ],
                Expanded(child: reject),
              ],
            ),
          ] else
            Row(
              children: [
                ?primary,
                for (final b in secondary) ...[const SizedBox(width: 10), b],
                const Spacer(),
                reject,
              ],
            ),
        ],
      ),
    );
  }
}

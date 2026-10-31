import 'dart:async';

import '../../data/app_store.dart';
import '../../data/contributions_repository.dart';
import '../../domain/contribution_display.dart';
import '../../domain/map_viewport.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/spot_sheet.dart';
import '../report/report_sheet.dart';

/// How a status reads: a small tinted plate with its words (P9). The
/// tints are fixed, as on road signs, so they read the same in dark mode.
typedef StatusLook = ({String label, Color background, Color foreground});

const _reviewing = (Color(0xffe3f0f2), Color(0xff0f4e5c));
const _waiting = (Color(0xfffdf4e3), Color(0xff5c4310));
const _accepted = (Color(0xffddf0e5), Color(0xff145238));
const _rejected = (Color(0xfffbecee), Color(0xff7a1f2e));
const _removed = (Color(0xffeceff1), Color(0xff3e4a50));

StatusLook _look(String label, (Color, Color) tint) =>
    (label: label, background: tint.$1, foreground: tint.$2);

StatusLook statusLook(MyContribution item) =>
    switch ((item.kind, item.status)) {
      (ContributionKind.newSpot, ContributionStatus.pending) => _look(
        '待車友確認',
        _waiting,
      ),
      (ContributionKind.newSpot, ContributionStatus.confirmed) => _look(
        '車友已確認',
        _accepted,
      ),
      (ContributionKind.newSpot, ContributionStatus.hidden) => _look(
        '已從地圖移除',
        _removed,
      ),
      (_, ContributionStatus.pending) => _look('審核中', _reviewing),
      (_, ContributionStatus.accepted) => _look('已採納', _accepted),
      (_, ContributionStatus.rejected) => _look('未採納', _rejected),
      (_, ContributionStatus.closed) => _look('已結案', _removed),
      _ => _look('處理中', _reviewing),
    };

/// Why a report was not used, one fixed sentence per kind an admin picks
/// (moderation_queue.resolution_kind); the admin's own note stays internal.
const rejectionReasons = {
  'wrong': '核對後與現場資訊不符。',
  'duplicate': '已有相同的建議，併入先前的處理。',
  'insufficient': '資訊不足，無法查證。',
  'outdated': '點位已變更，建議不再適用。',
  'abuse': '內容不符合回報規範。',
  'other': '管理員核對後沒有採用。',
};

/// What happened after a result, for riders who wonder whether the map
/// changed. Waiting needs no extra words beside its plate.
String? statusNote(MyContribution item) => switch ((item.kind, item.status)) {
  (ContributionKind.newSpot, ContributionStatus.pending) => '在地圖上，等其他車友確認',
  (ContributionKind.newSpot, ContributionStatus.hidden) => '管理員已將這個停車點從地圖移除。',
  (ContributionKind.suggestion, ContributionStatus.accepted) => '地圖已依你的建議更新。',
  (ContributionKind.gone, ContributionStatus.accepted) => '已依你的回報處理這個停車點。',
  (_, ContributionStatus.rejected) =>
    rejectionReasons[item.resolutionKind] ?? '管理員核對後沒有採用。',
  (_, ContributionStatus.closed) =>
    '${rejectionReasons[item.resolutionKind] ?? '這筆回報已處理完畢。'}地圖沒有變更。',
  _ => null,
};

/// 10月22日, with the year when it is not this year.
String sentDate(DateTime time, DateTime now) => time.year == now.year
    ? '${time.month}月${time.day}日送出'
    : '${time.year}年${time.month}月${time.day}日送出';

/// "我送出的建議": what the rider sent and how it was handled
/// (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §7, stage 0). In the contribute
/// tab it previews the latest [preview] rows with 「查看全部紀錄」 (P8); the
/// pushed page lists them all with older pages on demand (P9).
class MyContributionsSection extends StatefulWidget {
  const MyContributionsSection({
    super.key,
    required this.store,
    this.now,
    this.preview,
    this.onShowAll,
  });
  final AppStore store;

  /// Rows shown in the tab; null lists them all.
  final int? preview;

  /// Opens the full list, from the preview.
  final VoidCallback? onShowAll;

  /// Fixed in tests so dates read the same every run.
  final DateTime? now;

  @override
  State<MyContributionsSection> createState() => _MyContributionsSectionState();
}

class _MyContributionsSectionState extends State<MyContributionsSection> {
  final items = <MyContribution>[];
  bool loading = false, failed = false, hasMore = false, loadingMore = false;
  bool moreFailed = false;

  /// A quiet refresh is replacing the first page; older pages wait for it,
  /// or they would continue from a list about to be replaced.
  bool refreshing = false;

  /// The account and report count [items] were loaded for.
  (String?, int)? loadedFor;
  int _request = 0;

  /// Whether the tab was showing at the last dependency change; the shell
  /// keeps hidden tabs mounted with tickers off.
  bool? _active;
  late final AppLifecycleListener _lifecycle;

  AppStore get store => widget.store;
  String? get userId => store.riderId;

  @override
  void initState() {
    super.initState();
    store.addListener(_storeChanged);
    // Reviews finish while the app is away: check again on return.
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    _storeChanged();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (active && _active == false) _refresh();
    _active = active;
  }

  /// Fetches the first page again when coming back to the tab or the app,
  /// keeping the current list on screen until the new one arrives.
  void _refresh() {
    if (userId == null || loading) return;
    unawaited(reload(quiet: items.isNotEmpty));
  }

  @override
  void didUpdateWidget(MyContributionsSection old) {
    super.didUpdateWidget(old);
    if (old.store != store) {
      old.store.removeListener(_storeChanged);
      store.addListener(_storeChanged);
      _storeChanged();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    store.removeListener(_storeChanged);
    _request++;
    super.dispose();
  }

  /// Reloads after signing in or out and after each report sent.
  void _storeChanged() {
    final key = (userId, store.reportsSent);
    if (key == loadedFor) return;
    loadedFor = key;
    unawaited(reload());
  }

  /// Loads the first page. [quiet] keeps the list shown meanwhile and keeps
  /// it if the refresh fails; otherwise the list gives way to a spinner.
  Future<void> reload({bool quiet = false}) async {
    final request = ++_request;
    // Supersedes any older-page request, which can no longer clear these.
    loadingMore = false;
    moreFailed = false;
    if (!quiet) {
      items.clear();
      hasMore = false;
    }
    if (userId == null) {
      items.clear();
      hasMore = false;
      if (mounted) setState(() => loading = failed = refreshing = false);
      return;
    }
    if (mounted) {
      setState(() {
        loading = !quiet;
        refreshing = quiet;
        failed = false;
      });
    }
    try {
      final page = await store.contributions.load();
      if (!mounted || request != _request) return;
      setState(() {
        items
          ..clear()
          ..addAll(page.items);
        hasMore = page.hasMore;
        loading = refreshing = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        loading = refreshing = false;
        failed = !quiet;
      });
    }
  }

  Future<void> more() async {
    if (refreshing || loadingMore || items.isEmpty) return;
    final request = _request;
    setState(() {
      loadingMore = true;
      moreFailed = false;
    });
    try {
      final page = await store.contributions.load(after: items.last);
      if (!mounted || request != _request) return;
      setState(() {
        items.addAll(page.items);
        hasMore = page.hasMore;
      });
    } catch (_) {
      if (mounted && request == _request) setState(() => moreFailed = true);
    } finally {
      if (mounted && request == _request) setState(() => loadingMore = false);
    }
  }

  Future<void> open(MyContribution item) async {
    if (!item.canOpen) {
      showMessage(context, unavailableMessage(item));
      return;
    }
    final id = item.spotId!;
    var spot = store.spots.where((s) => s.id == id).firstOrNull;
    if (spot == null) {
      try {
        // The viewport functions return the spot exactly as the map shows
        // it; a box a few metres wide around it finds just that one.
        const pad = .0005;
        final found = await store.parking.inViewport(
          MapViewport(
            south: item.lat! - pad,
            west: item.lng! - pad,
            north: item.lat! + pad,
            east: item.lng! + pad,
          ),
        );
        spot = found.spots.where((s) => s.id == id).firstOrNull;
      } catch (_) {
        if (mounted) showMessage(context, '無法開啟停車點，請確認網路後再點一次。');
        return;
      }
    }
    if (!mounted) return;
    if (spot == null) {
      showMessage(context, '這個停車點目前不在地圖上。');
      return;
    }
    await showSpot(context, store, spot);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.preview != null)
          Padding(
            padding: EdgeInsets.fromLTRB(isCupertino ? 16 : 0, 0, 16, 6),
            child: Semantics(
              header: true,
              child: Text(
                myContributionsTitle,
                style: text.bodySmall?.copyWith(
                  color: isCupertino ? colors.onSurfaceVariant : colors.primary,
                  fontSize: 13,
                ),
              ),
            ),
          )
        else ...[
          Text(
            myContributionsIntro,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
        ],
        ..._body(context),
      ],
    );
  }

  List<Widget> _body(BuildContext context) {
    if (store.demo) {
      return [const _Notice('範例模式不會保存送出的內容，這裡不會有紀錄。')];
    }
    if (userId == null) {
      // The tab's sign-in banner above already has the button; one way in
      // per page, so this only says what signing in adds here.
      return [const _Notice('登入後，你送出的建議與審核結果會列在這裡。', icon: Icons.lock_outline)];
    }
    if (loading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: CircularProgressIndicator.adaptive(
              semanticsLabel: '正在讀取你送出的建議',
            ),
          ),
        ),
      ];
    }
    if (failed) {
      return [
        _Notice(
          '讀不到你送出的建議。請確認網路連線後重試。',
          icon: Icons.cloud_off_outlined,
          action: TextButton(onPressed: reload, child: const Text('重試')),
        ),
      ];
    }
    if (items.isEmpty) {
      return [
        _Notice(
          '還沒有送出建議。在上方選一個停車點提出修改，或新增你找到的停車點，審核結果會出現在這裡。',
          icon: Icons.inbox_outlined,
          action: TextButton.icon(
            onPressed: () => showReport(
              context,
              store,
              store.mapLat,
              store.mapLng,
              mapCenter: true,
            ),
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('新增停車點'),
          ),
        ),
      ];
    }
    final now = widget.now ?? DateTime.now();
    final preview = widget.preview;
    final shown = preview == null ? items : items.take(preview).toList();
    return [
      ContributionGroup(
        children: [
          for (final item in shown)
            ContributionRow(item: item, now: now, onTap: () => open(item)),
        ],
      ),
      if (preview != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('contributions-all'),
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: EdgeInsets.symmetric(horizontal: isCupertino ? 16 : 0),
            ),
            onPressed: widget.onShowAll,
            child: const Text(myContributionsAll),
          ),
        )
      else if (moreFailed)
        _Notice(
          '沒有載入更多紀錄。請確認網路連線後重試。',
          icon: Icons.cloud_off_outlined,
          action: TextButton(
            onPressed: refreshing ? null : more,
            child: const Text('重試'),
          ),
        )
      else if (hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: loadingMore
              ? const Center(child: CircularProgressIndicator.adaptive())
              : TextButton(
                  onPressed: refreshing ? null : more,
                  child: const Text('載入更早的紀錄'),
                ),
        ),
    ];
  }
}

/// iOS inset grouped rows; a plain divided list on Android.
class ContributionGroup extends StatelessWidget {
  const ContributionGroup({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rows = [
      for (final (i, child) in children.indexed) ...[
        if (i > 0)
          Divider(
            height: 1,
            indent: isCupertino ? 16 : 0,
            color: colors.outlineVariant,
          ),
        child,
      ],
    ];
    if (!isCupertino) return Column(children: rows);
    return Material(
      color: colors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Column(children: rows),
    );
  }
}

/// Why a contribution's spot cannot open.
String unavailableMessage(MyContribution item) => item.spotName == null
    ? '這個停車點已不在地圖資料中，無法開啟。'
    : '「${item.spotName}」已不在地圖上，無法開啟詳情。';

/// One contribution (P9): its kind and date with the status plate, the
/// spot, then what was sent or what happened.
class ContributionRow extends StatelessWidget {
  const ContributionRow({
    super.key,
    required this.item,
    required this.now,
    required this.onTap,
  });
  final MyContribution item;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final look = statusLook(item);
    final note = statusNote(item);
    final summary = contributionSummary(item);
    final name = item.spotName ?? '已不在地圖資料中的停車點';
    final meta = [
      contributionKindLabel(item.kind),
      [
        contributionDate(item.createdAt, now),
        if (!item.canOpen) '已不在地圖上',
      ].join('，'),
    ].join('　');
    final quiet = TextStyle(color: colors.onSurfaceVariant);
    return Semantics(
      button: true,
      // Everything the row shows, since the visible text is merged away.
      // The row's own tap, since excludeSemantics drops the InkWell's.
      onTap: onTap,
      label: [
        name,
        item.action,
        ?summary,
        look.label,
        ?note,
        sentDate(item.createdAt, now),
        if (!item.canOpen) '已不在地圖上',
      ].join('，'),
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isCupertino ? 16 : 0,
              vertical: 12,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        meta,
                        style: text.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusPlate(look: look),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  name,
                  style: text.titleMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (summary != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: quiet,
                  ),
                ],
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(note, style: quiet),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A status as a small tinted plate.
class StatusPlate extends StatelessWidget {
  const StatusPlate({super.key, required this.look});
  final StatusLook look;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: look.background,
      borderRadius: BorderRadius.circular(isCupertino ? 6 : 8),
    ),
    child: Text(
      look.label,
      style: TextStyle(
        color: look.foreground,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// A short message in place of the list, with what to do next.
class _Notice extends StatelessWidget {
  const _Notice(this.message, {this.icon, this.action});
  final String message;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, color: colors.onSurfaceVariant),
                const SizedBox(width: 12),
              ],
              Expanded(child: Text(message)),
            ],
          ),
          if (action != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: action),
        ],
      ),
    );
  }
}

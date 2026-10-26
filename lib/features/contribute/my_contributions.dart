import 'dart:async';

import '../../data/app_store.dart';
import '../../data/contributions_repository.dart';
import '../../domain/map_viewport.dart';
import '../../ui/adaptive/adaptive.dart';
import '../map/map_legend.dart';
import '../map/spot_sheet.dart';
import '../report/report_sheet.dart';

/// How a status reads: a plate in the colour riders know from the map's
/// legend, always with its own icon and words. Results are filled plates;
/// waiting is an outline, so a finished review stands out in the list.
typedef StatusLook = ({String label, IconData icon, Color color, bool done});

StatusLook statusLook(MyContribution item) =>
    switch ((item.kind, item.status)) {
      (ContributionKind.newSpot, ContributionStatus.pending) => (
        label: '在地圖上，待車友確認',
        icon: Icons.schedule,
        color: unverifiedColor,
        done: false,
      ),
      (ContributionKind.newSpot, ContributionStatus.confirmed) => (
        label: '車友已確認',
        icon: Icons.check_circle,
        color: allowedColor,
        done: true,
      ),
      (ContributionKind.newSpot, ContributionStatus.hidden) => (
        label: '已從地圖移除',
        icon: Icons.visibility_off,
        color: deniedColor,
        done: true,
      ),
      (_, ContributionStatus.pending) => (
        label: '審核中',
        icon: Icons.schedule,
        color: unverifiedColor,
        done: false,
      ),
      (_, ContributionStatus.accepted) => (
        label: '已採納',
        icon: Icons.check_circle,
        color: allowedColor,
        done: true,
      ),
      (_, ContributionStatus.rejected) => (
        label: '未採納',
        icon: Icons.cancel,
        color: deniedColor,
        done: true,
      ),
      (_, ContributionStatus.closed) => (
        label: '已結案',
        icon: Icons.task_alt,
        color: unverifiedColor,
        done: true,
      ),
      _ => (
        label: '處理中',
        icon: Icons.schedule,
        color: unverifiedColor,
        done: false,
      ),
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
  (ContributionKind.newSpot, ContributionStatus.hidden) => '管理員已將這個停車點從地圖移除。',
  (ContributionKind.suggestion, ContributionStatus.accepted) => '地圖已依你的建議更新。',
  (ContributionKind.gone, ContributionStatus.accepted) => '已依你的回報處理這個停車點。',
  (_, ContributionStatus.rejected) =>
    '${rejectionReasons[item.resolutionKind] ?? '管理員核對後沒有採用。'}地圖維持原樣。',
  (_, ContributionStatus.closed) =>
    '${rejectionReasons[item.resolutionKind] ?? '這筆回報已處理完畢。'}地圖沒有變更。',
  _ => null,
};

/// 10月22日, with the year when it is not this year.
String sentDate(DateTime time, DateTime now) => time.year == now.year
    ? '${time.month}月${time.day}日送出'
    : '${time.year}年${time.month}月${time.day}日送出';

/// "我送出的建議" in the contribute tab: what the rider sent and how it
/// was handled (docs/CONTRIBUTION_TIERS_FEASIBILITY.md §7, stage 0).
class MyContributionsSection extends StatefulWidget {
  const MyContributionsSection({super.key, required this.store, this.now});
  final AppStore store;

  /// Fixed in tests so dates read the same every run.
  final DateTime? now;

  @override
  State<MyContributionsSection> createState() => _MyContributionsSectionState();
}

class _MyContributionsSectionState extends State<MyContributionsSection> {
  final items = <MyContribution>[];
  bool loading = false, failed = false, hasMore = false, loadingMore = false;
  bool moreFailed = false;

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
      if (mounted) setState(() => loading = failed = false);
      return;
    }
    if (mounted) {
      setState(() {
        loading = !quiet;
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
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        loading = false;
        failed = !quiet;
      });
    }
  }

  Future<void> more() async {
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
        Semantics(
          header: true,
          child: Text(
            '我送出的建議',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '新增的停車點、修改建議與不能停車的回報，以及審核結果。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
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
    return [
      for (final (i, item) in items.indexed) ...[
        if (i > 0) const Divider(height: 1),
        ContributionRow(item: item, now: now, onTap: () => open(item)),
      ],
      if (moreFailed)
        _Notice(
          '沒有載入更多紀錄。請確認網路連線後重試。',
          icon: Icons.cloud_off_outlined,
          action: TextButton(onPressed: more, child: const Text('重試')),
        )
      else if (hasMore)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: loadingMore
              ? const Center(child: CircularProgressIndicator.adaptive())
              : TextButton(onPressed: more, child: const Text('載入更早的紀錄')),
        ),
    ];
  }
}

/// Why a contribution's spot cannot open.
String unavailableMessage(MyContribution item) => item.spotName == null
    ? '這個停車點已不在地圖資料中，無法開啟。'
    : '「${item.spotName}」已不在地圖上，無法開啟詳情。';

/// One contribution: what it was about, then its status plate, which is
/// the one strong element of the row. Beside the text when the pane is
/// wide enough, under it on phones and at large text sizes.
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
    final detail = item.detail;
    final name = item.spotName ?? '已不在地圖資料中的停車點';
    final plate = StatusPlate(look: look);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: text.titleMedium,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(item.action, style: TextStyle(color: colors.onSurfaceVariant)),
        if (detail != null) ...[
          const SizedBox(height: 2),
          Text(
            detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ],
    );
    final meta = Text(
      [sentDate(item.createdAt, now), if (!item.canOpen) '已不在地圖上'].join('，'),
      style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
    );
    return Semantics(
      button: true,
      // Everything the row shows, since the visible text is merged away.
      label: [
        name,
        item.action,
        ?detail,
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
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: LayoutBuilder(
              builder: (context, box) {
                // Side by side only when the text keeps a readable width.
                final wide =
                    box.maxWidth >= 520 &&
                    MediaQuery.textScalerOf(context).scale(1) <= 1.3;
                final trailing = Icon(
                  item.canOpen ? Icons.chevron_right : Icons.info_outline,
                  color: colors.onSurfaceVariant,
                );
                if (wide) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [body, const SizedBox(height: 4), meta],
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 200,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            plate,
                            if (note != null) ...[
                              const SizedBox(height: 4),
                              Text(note, style: text.bodySmall),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      trailing,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          plate,
                          const SizedBox(height: 8),
                          body,
                          if (note != null) ...[
                            const SizedBox(height: 4),
                            Text(note, style: text.bodySmall),
                          ],
                          const SizedBox(height: 4),
                          meta,
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    trailing,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A status as a small road-sign plate: filled with white words for a
/// result, outlined while it waits.
class StatusPlate extends StatelessWidget {
  const StatusPlate({super.key, required this.look});
  final StatusLook look;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // An outline on a dark surface needs a lighter stroke and text to stay
    // readable; filled plates keep white text on the legend colour.
    final waiting = dark ? const Color(0xffb7c0c6) : look.color;
    final fg = look.done ? Colors.white : waiting;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: look.done ? look.color : null,
        border: look.done ? null : Border.all(color: waiting, width: 1.5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(look.icon, size: 18, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              look.label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
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

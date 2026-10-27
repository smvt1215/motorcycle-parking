import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../admin_theme.dart';
import '../review/review_page.dart' show reviewCompactWidth;
import 'user_models.dart';
import 'users_controller.dart';

const _wideWidth = 1040.0;

/// `/users` and `/users/<user id>`: find an account, see how it reports,
/// ban or lift a ban, and clear its public name on a point.
class UsersPage extends StatefulWidget {
  const UsersPage({super.key, required this.users, required this.selectedId});
  final UsersController users;
  final String? selectedId;

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage> {
  final query = TextEditingController();
  Timer? _debounce;

  UsersController get users => widget.users;

  @override
  void initState() {
    super.initState();
    query.text = users.query;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!users.searched && !users.searching) users.search();
      _follow();
    });
  }

  @override
  void didUpdateWidget(covariant UsersPage old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  void _follow() {
    if (!mounted) return;
    final id = widget.selectedId;
    if (id == null) {
      if (users.openId != null) users.close();
    } else if (users.openId != id) {
      users.open(id);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    super.dispose();
  }

  void _search(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      users.query = value;
      users.search();
    });
  }

  Future<void> _ban(bool lift) async {
    final user = users.detail?.user;
    if (user == null) return;
    final result = await showDialog<(BanLength?, String)>(
      context: context,
      builder: (context) => _BanDialog(user: user, lift: lift),
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (await users.setBan(result.$1, result.$2)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(lift ? '已解除停權：${user.label}' : '已停權：${user.label}'),
          ),
        );
    }
  }

  Future<void> _clearName(UserSpot spot) async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => _ClearNameDialog(spot: spot),
    );
    if (note == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (await users.clearName(spot.id, note)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已清除公開名稱：${spot.name}')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: users,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < reviewCompactWidth;
        final list = _ListPane(
          users: users,
          query: query,
          selectedId: compact ? null : widget.selectedId,
          onQuery: _search,
          onPick: (id) => context.go('/users/$id'),
        );
        final detail = _DetailPane(
          users: users,
          compact: compact,
          selectedId: widget.selectedId,
          onBack: () => context.go('/users'),
          onBan: _ban,
          onClearName: _clearName,
          onReload: () {
            final id = widget.selectedId;
            if (id != null) users.open(id);
          },
        );
        if (compact) return widget.selectedId == null ? list : detail;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth >= _wideWidth ? 380 : 300,
                child: _Pane(child: list),
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

class _ListPane extends StatelessWidget {
  const _ListPane({
    required this.users,
    required this.query,
    required this.selectedId,
    required this.onQuery,
    required this.onPick,
  });
  final UsersController users;
  final TextEditingController query;
  final String? selectedId;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final recent = users.query.trim().isEmpty;
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
                  // A phone names the page in the top bar.
                  child: MediaQuery.sizeOf(context).width < reviewCompactWidth
                      ? const SizedBox()
                      : Semantics(
                          header: true,
                          child: Text('使用者管理', style: text.titleLarge),
                        ),
                ),
                IconButton(
                  tooltip: '重新搜尋',
                  onPressed: users.searching ? null : users.search,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: TextField(
              key: const ValueKey('user-search'),
              controller: query,
              onChanged: onQuery,
              decoration: const InputDecoration(
                labelText: '顯示名稱、使用者 id 或完整 email',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Text(
              recent
                  ? '目前列出最近 30 天有回報的帳號，最近回報的在前。'
                  : 'email 需輸入完整地址；結果只顯示部分字元。',
              style: muted,
            ),
          ),
          if (users.searchError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: AdminNotice(users.searchError!, error: true),
            ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: !users.searched
                ? Center(
                    child: users.searching
                        ? const CircularProgressIndicator()
                        : const SizedBox(),
                  )
                : users.results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      recent
                          ? '最近 30 天沒有人回報。要找特定帳號，請輸入顯示名稱、使用者 id 或完整 email。'
                          : '沒有符合的帳號。名稱可只打一部分；email 要完整，使用者 id 要完整 36 碼。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    itemCount: users.results.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.outlineVariant),
                    itemBuilder: (context, i) => _UserItem(
                      user: users.results[i],
                      selected: users.results[i].id == selectedId,
                      onPressed: () => onPick(users.results[i].id),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _UserItem extends StatelessWidget {
  const _UserItem({
    required this.user,
    required this.selected,
    required this.onPressed,
  });
  final AdminUser user;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey('user-${user.id}'),
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
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    user.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: user.displayName.isEmpty
                          ? colors.onSurfaceVariant
                          : null,
                    ),
                  ),
                  if (user.banned) const _BannedTag(),
                  if (user.isAdmin) Text('管理者', style: muted),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  if (user.email.isNotEmpty) user.email,
                  '30 天回報 ${user.reports30d} 次',
                ].join('，'),
                style: muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A banned account reads like a red curb: no stopping here.
class _BannedTag extends StatelessWidget {
  const _BannedTag();

  @override
  Widget build(BuildContext context) {
    final red = Theme.of(context).colorScheme.error;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.block, size: 16, color: red),
        const SizedBox(width: 4),
        Text(
          '停權中',
          style: TextStyle(
            color: red,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _DetailPane extends StatelessWidget {
  const _DetailPane({
    required this.users,
    required this.compact,
    required this.selectedId,
    required this.onBack,
    required this.onBan,
    required this.onClearName,
    required this.onReload,
  });
  final UsersController users;
  final bool compact;
  final String? selectedId;
  final VoidCallback onBack, onReload;
  final ValueChanged<bool> onBan;
  final ValueChanged<UserSpot> onClearName;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pad = compact ? 16.0 : 24.0;
    final back = compact
        ? Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回使用者清單'),
            ),
          )
        : null;
    if (selectedId == null) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
          children: [
            Text('選擇一個帳號', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              '從左側清單選擇帳號，即可查看今天的回報額度、回報紀錄，並停權或清除它在停車點上的公開名稱。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    final detail = users.detail;
    if (detail == null || detail.user.id != selectedId) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: EdgeInsets.all(pad),
          children: [
            ?back,
            const SizedBox(height: 24),
            if (users.openError != null) ...[
              AdminNotice(users.openError!, error: true),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: onReload,
                  child: const Text('重新載入'),
                ),
              ),
            ] else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }
    final user = detail.user;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    Widget section(String title) => Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
    );
    return Material(
      color: colors.surface,
      child: SelectionArea(
        child: ListView(
          key: ValueKey('user-detail-${user.id}'),
          padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 22, pad, 32),
          children: [
            ?back,
            Semantics(
              header: true,
              child: Text(
                user.label,
                style: text.headlineMedium?.copyWith(
                  fontSize: compact ? 22 : 26,
                  height: 1.3,
                  color: user.displayName.isEmpty
                      ? colors.onSurfaceVariant
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 6),
            _Facts([
              if (user.email.isNotEmpty) ('email', user.email),
              ('使用者 id', user.id),
              (
                '登入方式',
                user.providers.isEmpty
                    ? '無'
                    : user.providers.map(_provider).join('、'),
              ),
              if (user.createdAt != null) ('建立', _when(user.createdAt!)),
              if (user.lastSignInAt != null)
                ('最後登入', _when(user.lastSignInAt!)),
              if (user.deleted) ('狀態', '帳號已刪除'),
            ]),
            const SizedBox(height: 20),
            _StatusBlock(
              user: user,
              busy: users.writing,
              onBan: () => onBan(false),
              onLift: () => onBan(true),
            ),
            if (users.writeError != null) ...[
              const SizedBox(height: 12),
              AdminNotice(users.writeError!, error: true),
            ],
            section('今天的回報額度'),
            _Quota(limits: detail.limits),
            const SizedBox(height: 10),
            Text(
              '近 7 天 ${detail.limits.last7d} 次，近 30 天 ${detail.limits.last30d} 次，'
              '來自 ${detail.limits.networks30d} 個網路位置。',
            ),
            if (detail.limits.sharedAccounts30d > 0) ...[
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 3),
                    child: Icon(
                      Icons.group_outlined,
                      size: 18,
                      color: AdminColors.yellow,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '近 30 天另有 ${detail.limits.sharedAccounts30d} 個帳號從相同網路位置回報。'
                      '同一個家庭或公司網路也會這樣，停權前請一併比對回報內容。',
                    ),
                  ),
                ],
              ),
            ],
            section('回報紀錄'),
            _Counts(reports: detail.reports),
            if (detail.events.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('最近的回報時間（網路代號只用來分辨是否同一個網路）', style: muted),
              const SizedBox(height: 4),
              for (final e in detail.events.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${e.at == null ? '—' : _when(e.at!)}　網路 ${e.network}',
                    style: const TextStyle(
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
            section('回報的停車點與公開名稱'),
            if (detail.spots.isEmpty)
              Text('這個帳號沒有新增過停車點。', style: muted)
            else ...[
              Text(
                'App 在社群點上顯示回報者目前的名稱。名稱不當時可逐點清除；清除後即使改名也不會再顯示。',
                style: muted,
              ),
              const SizedBox(height: 6),
              for (final s in detail.spots)
                _SpotRow(
                  spot: s,
                  busy: users.writing,
                  onClear: () => onClearName(s),
                ),
              if (users.spotsError != null) ...[
                const SizedBox(height: 10),
                AdminNotice(users.spotsError!, error: true),
              ],
              if (users.hasMoreSpots) ...[
                const SizedBox(height: 10),
                Text(
                  '已列出 ${detail.spots.length}／${detail.reports['spots']} 個點位。',
                  style: muted,
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const ValueKey('more-spots'),
                    onPressed: users.spotsLoading ? null : users.loadMoreSpots,
                    child: Text(users.spotsLoading ? '載入中…' : '載入更早的點位'),
                  ),
                ),
              ],
            ],
            if (detail.history.isNotEmpty) ...[
              section('停權紀錄'),
              for (final h in detail.history)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${h.at == null ? '' : '${_when(h.at!)}　'}${h.label}'
                        '${h.action == 'ban_user' && h.bannedUntil != null ? '，至 ${_when(h.bannedUntil!)}' : ''}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (h.note.isNotEmpty) Text('原因：${h.note}'),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Facts extends StatelessWidget {
  const _Facts(this.facts);
  final List<(String, String)> facts;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in facts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$label　', style: muted),
                  TextSpan(text: value),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// The page's one loud element: whether this account may report, and the
/// action that changes it.
class _StatusBlock extends StatelessWidget {
  const _StatusBlock({
    required this.user,
    required this.busy,
    required this.onBan,
    required this.onLift,
  });
  final AdminUser user;
  final bool busy;
  final VoidCallback onBan, onLift;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final banned = user.banned;
    final (icon, title, body) = banned
        ? (
            Icons.block,
            '停權中',
            user.bannedIndefinitely
                ? '直到管理者解除。這段期間無法登入，也無法送出回報與投票。'
                : '至 ${_when(user.bannedUntil!)}。這段期間無法登入，也無法送出回報與投票。',
          )
        : user.isAdmin
        ? (
            Icons.verified_user_outlined,
            '管理者帳號',
            '管理者不能在這裡停權；需要移除管理權限時，請由專案擁有者處理。',
          )
        : (Icons.check_circle_outline, '可以回報', '這個帳號可以登入、新增停車點、投票與送出修改建議。');
    final accent = banned ? colors.error : colors.primary;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: banned ? colors.error.withValues(alpha: .08) : null,
          border: Border(left: BorderSide(color: accent, width: 6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: accent),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: banned ? colors.error : null,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(body),
            if (!user.isAdmin && !user.deleted) ...[
              const SizedBox(height: 12),
              banned
                  ? FilledButton.icon(
                      key: const ValueKey('lift-ban'),
                      onPressed: busy ? null : onLift,
                      icon: const Icon(Icons.lock_open),
                      label: const Text('解除停權'),
                    )
                  : OutlinedButton.icon(
                      key: const ValueKey('ban'),
                      onPressed: busy ? null : onBan,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colors.error,
                        side: BorderSide(color: colors.error),
                      ),
                      icon: const Icon(Icons.block),
                      label: const Text('停權帳號'),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Today's reports as a row of painted bays: one bay per allowed report.
class _Quota extends StatelessWidget {
  const _Quota({required this.limits});
  final ReportLimits limits;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final used = limits.today.clamp(0, limits.dailyLimit);
    final full = limits.today >= limits.dailyLimit;
    return Semantics(
      label: '今天已回報 ${limits.today} 次，上限 ${limits.dailyLimit} 次',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 0,
              runSpacing: 6,
              children: [
                for (var i = 0; i < limits.dailyLimit; i++)
                  Container(
                    width: 22,
                    height: 34,
                    decoration: BoxDecoration(
                      color: i < used
                          ? (full ? colors.error : colors.onSurface)
                          : null,
                      border: Border(
                        left: BorderSide(color: colors.onSurfaceVariant),
                        top: BorderSide(color: colors.onSurfaceVariant),
                        bottom: BorderSide(color: colors.onSurfaceVariant),
                        right: i == limits.dailyLimit - 1
                            ? BorderSide(color: colors.onSurfaceVariant)
                            : BorderSide.none,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              full
                  ? '今天 ${limits.today}／${limits.dailyLimit} 次，已達上限，台灣時間早上 8 點重新計算。'
                  : '今天 ${limits.today}／${limits.dailyLimit} 次，台灣時間早上 8 點重新計算。',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: full ? colors.error : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Counts extends StatelessWidget {
  const _Counts({required this.reports});
  final ReportCounts reports;

  @override
  Widget build(BuildContext context) {
    final rows = [
      (
        '新增停車點',
        '${reports['spots']} 個'
            '${reports['spots_hidden'] > 0 ? '，其中 ${reports['spots_hidden']} 個已隱藏' : ''}',
      ),
      (
        '現場投票',
        '仍在 ${reports['votes_still_there']} 次，已不存在 ${reports['votes_gone']} 次',
      ),
      (
        '修改建議',
        '待審 ${reports['flags_pending']}，採納 ${reports['flags_accepted']}，'
            '駁回 ${reports['flags_rejected']}，結案 ${reports['flags_closed']}',
      ),
    ];
    return _Facts(rows);
  }
}

class _SpotRow extends StatelessWidget {
  const _SpotRow({
    required this.spot,
    required this.busy,
    required this.onClear,
  });
  final UserSpot spot;
  final bool busy;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant, fontSize: 13);
    final shown = spot.nameCleared
        ? '公開名稱已清除'
        : spot.contributorName.isEmpty
        ? 'App 上沒有顯示名稱'
        : 'App 上顯示「${spot.contributorName}」';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton(
                  onPressed: () => context.go('/spots/${spot.id}'),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: Alignment.centerLeft,
                    minimumSize: const Size(44, 44),
                  ),
                  child: Text(
                    spot.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Text(
                  [
                    if (spot.place.isNotEmpty) spot.place,
                    if (spot.status == 'hidden') '已隱藏',
                  ].join('，'),
                  style: muted,
                ),
                Text(shown),
              ],
            ),
          ),
          if (!spot.nameCleared && spot.contributorName.isNotEmpty)
            OutlinedButton(
              key: ValueKey('clear-name-${spot.id}'),
              onPressed: busy ? null : onClear,
              child: const Text('清除這個名稱'),
            ),
        ],
      ),
    );
  }
}

class _BanDialog extends StatefulWidget {
  const _BanDialog({required this.user, required this.lift});
  final AdminUser user;
  final bool lift;

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

class _BanDialogState extends State<_BanDialog> {
  final reason = TextEditingController();
  BanLength length = BanLength.week;
  bool tried = false;

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (reason.text.trim().isEmpty) {
      setState(() => tried = true);
      return;
    }
    Navigator.pop(context, (widget.lift ? null : length, reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lift = widget.lift;
    return AlertDialog(
      scrollable: true,
      title: Text(
        lift ? '解除「${widget.user.label}」的停權？' : '停權「${widget.user.label}」？',
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              lift
                  ? '解除後這個帳號可以重新登入並回報。'
                  : '停權後這個帳號無法登入，也無法送出回報與投票；已回報的停車點維持不變。',
            ),
            if (!lift) ...[
              const SizedBox(height: 16),
              const Text('停權期間', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Semantics(
                container: true,
                label: '停權期間',
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final l in BanLength.values)
                      Semantics(
                        selected: length == l,
                        child: OutlinedButton(
                          key: ValueKey('ban-length-${l.key}'),
                          onPressed: () => setState(() => length = l),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            shape: const StadiumBorder(),
                            foregroundColor: length == l
                                ? colors.surface
                                : colors.onSurface,
                            backgroundColor: length == l
                                ? colors.onSurface
                                : null,
                          ),
                          child: Text(l.label),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('ban-reason'),
              controller: reason,
              autofocus: true,
              maxLength: 500,
              minLines: 2,
              maxLines: 4,
              onChanged: (_) {
                if (tried) setState(() {});
              },
              decoration: InputDecoration(
                labelText: lift ? '解除原因（寫入稽核紀錄）' : '停權原因（寫入稽核紀錄）',
                errorText: tried && reason.text.trim().isEmpty
                    ? '請填寫原因，之後查紀錄才知道為什麼。'
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-ban'),
          onPressed: _submit,
          style: lift
              ? null
              : FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                ),
          child: Text(lift ? '解除停權' : '停權帳號'),
        ),
      ],
    );
  }
}

class _ClearNameDialog extends StatefulWidget {
  const _ClearNameDialog({required this.spot});
  final UserSpot spot;

  @override
  State<_ClearNameDialog> createState() => _ClearNameDialogState();
}

class _ClearNameDialogState extends State<_ClearNameDialog> {
  final note = TextEditingController();

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('清除這個公開名稱？'),
    content: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '「${widget.spot.name}」不再顯示「${widget.spot.contributorName}」。'
            '只影響這個停車點，帳號之後改名也不會再顯示；無法從這裡復原。',
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('clear-name-note'),
            controller: note,
            maxLength: 500,
            decoration: const InputDecoration(labelText: '原因（選填，寫入稽核紀錄）'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('confirm-clear-name'),
        onPressed: () => Navigator.pop(context, note.text.trim()),
        child: const Text('清除名稱'),
      ),
    ],
  );
}

String _provider(String p) => switch (p) {
  'google' => 'Google',
  'apple' => 'Apple',
  'anonymous' => '訪客',
  _ => p,
};

String _two(int n) => n.toString().padLeft(2, '0');

String _when(DateTime t) =>
    '${t.year}/${_two(t.month)}/${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

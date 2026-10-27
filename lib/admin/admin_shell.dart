import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'admin_controller.dart';
import 'admin_layout.dart';
import 'admin_theme.dart';

typedef AdminTab = ({
  String path,
  String label,
  IconData icon,
  String title,
  String description,
});

const List<AdminTab> adminTabs = [
  (
    path: '/review',
    label: '審核',
    icon: Icons.fact_check_outlined,
    title: '待審回報',
    description: '騎士送出的修改建議與現場回報，會集中在這裡確認。',
  ),
  (
    path: '/spots',
    label: '點位',
    icon: Icons.location_on_outlined,
    title: '停車點位',
    description: '在這裡查詢官方與社群停車點，確認位置與停放資訊。',
  ),
  (
    path: '/rules',
    label: '規則',
    icon: Icons.rule_outlined,
    title: '各縣市停車規則',
    description: '設定各縣市普通機車與大型重機的路邊停放規則並發布新版本。',
  ),
  (
    path: '/imports',
    label: '匯入',
    icon: Icons.file_upload_outlined,
    title: '匯入停車資料',
    description: '在這裡匯入整理好的停車資料，並確認變更內容。',
  ),
  (
    path: '/users',
    label: '使用者',
    icon: Icons.people_outline,
    title: '使用者管理',
    description: '在這裡查看使用者的回報狀況與帳號管理資訊。',
  ),
];

/// `/review/<id>` belongs to the review tab.
String adminSection(String path) =>
    '/${path.split('/').where((p) => p.isNotEmpty).firstOrNull ?? ''}';

/// The frame around every signed-in page. Below [adminWideWidth] the top
/// bar is one asphalt row; below [adminCompactWidth] the tabs move to a
/// bottom navigation bar (C6 畫布 Main、Tablet). A short viewport drops the
/// authenticator notice and the bottom bar so the form keeps the room.
class AdminShell extends StatefulWidget {
  const AdminShell({
    super.key,
    required this.controller,
    required this.path,
    required this.onSignOut,
    required this.child,
  });
  final AdminController controller;
  final String path;
  final VoidCallback onSignOut;
  final Widget child;

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  /// The admin folded the authenticator notice away for this session.
  bool _noticeHidden = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final width = MediaQuery.sizeOf(context).width;
    final short = AdminLayout.shortOf(context);
    final wide = width >= adminWideWidth;
    final phone = width < adminCompactWidth;
    final section = adminSection(widget.path);
    final needsAuthenticator =
        controller.authenticatorCount < 2 && widget.path != '/security';
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (wide)
              _DesktopBar(
                controller: controller,
                section: section,
                onSignOut: widget.onSignOut,
              )
            else
              _CompactBar(
                controller: controller,
                section: section,
                phone: phone,
                short: short,
                onSignOut: widget.onSignOut,
              ),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: AdminNotice(controller.error!, error: true),
              ),
            if (needsAuthenticator && wide)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    const Text('尚未登記兩個驗證器 App，請補上備援方式。'),
                    TextButton.icon(
                      onPressed: () => context.go('/security'),
                      icon: const Icon(Icons.phonelink_lock),
                      label: const Text('登記備援驗證器'),
                    ),
                  ],
                ),
              )
            else if (needsAuthenticator && !short && !_noticeHidden)
              _AuthenticatorNotice(
                missing: 2 - controller.authenticatorCount,
                onHide: () => setState(() => _noticeHidden = true),
              ),
            Expanded(child: widget.child),
          ],
        ),
      ),
      bottomNavigationBar: phone && !short
          ? _BottomNav(section: section, pending: controller.pendingCount)
          : null,
    );
  }
}

/// ≥ 1040 px: the brand, the tabs and the account in one light row.
class _DesktopBar extends StatelessWidget {
  const _DesktopBar({
    required this.controller,
    required this.section,
    required this.onSignOut,
  });
  final AdminController controller;
  final String section;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final pending = controller.pendingCount;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          const SizedBox(width: 210, child: AdminBrand()),
          const SizedBox(width: 20),
          Expanded(
            child: Semantics(
              label: '管理功能',
              container: true,
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final tab in adminTabs)
                    Semantics(
                      selected: section == tab.path,
                      child: TextButton(
                        key: ValueKey('nav${tab.path}'),
                        onPressed: () => context.go(tab.path),
                        style: TextButton.styleFrom(
                          foregroundColor: section == tab.path
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                          backgroundColor: section == tab.path
                              ? colors.primary.withValues(alpha: .1)
                              : null,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              tab.label,
                              style: TextStyle(
                                fontWeight: section == tab.path
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                            if (tab.path == '/review') ...[
                              const SizedBox(width: 8),
                              Semantics(
                                label: _pendingLabel(pending),
                                child: Container(
                                  constraints: const BoxConstraints(
                                    minWidth: 24,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 1,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: AdminColors.yellow,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: ExcludeSemantics(
                                    child: Text(
                                      pending?.toString() ?? '—',
                                      style: const TextStyle(
                                        color: AdminColors.asphalt,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Icon(
            Icons.verified_user_outlined,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            '兩步驟驗證已通過',
            style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          IconButton(
            tooltip:
                '帳號安全${controller.access.email == null ? '' : '：${controller.access.email}'}',
            onPressed: () => context.go('/security'),
            icon: const Icon(Icons.manage_accounts_outlined),
          ),
          IconButton(
            tooltip: '登出',
            onPressed: controller.busy ? null : onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
    );
  }
}

String _pendingLabel(int? pending) =>
    pending == null ? '待審數尚未取得' : '$pending 筆待審';

const _barInk = Color(0xffd5d9dc);

/// Below 1040 px: one asphalt row. A phone shows the page name; a tablet
/// the tabs, the current one underlined in yellow like a road marking.
class _CompactBar extends StatelessWidget {
  const _CompactBar({
    required this.controller,
    required this.section,
    required this.phone,
    required this.short,
    required this.onSignOut,
  });
  final AdminController controller;
  final String section;
  final bool phone, short;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final height = short ? 48.0 : (phone ? 56.0 : 64.0);
    final title =
        adminTabs.where((t) => t.path == section).firstOrNull?.title ??
        (section == '/security' ? '帳號安全' : '停車指南管理');
    return Material(
      color: AdminColors.asphalt,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 4, 0),
          child: Row(
            children: [
              const _BrandMark(),
              const SizedBox(width: 10),
              if (phone)
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AdminColors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: Semantics(
                    label: '管理功能',
                    container: true,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tab in adminTabs)
                            _TopTab(
                              tab: tab,
                              selected: section == tab.path,
                              pending: tab.path == '/review'
                                  ? controller.pendingCount
                                  : null,
                              height: height,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              _AccountMenu(controller: controller, onSignOut: onSignOut),
            ],
          ),
        ),
      ),
    );
  }
}

/// The site's mark: a yellow-lined P, as on a parking sign.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '停車指南管理',
    image: true,
    child: Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        border: Border.all(color: AdminColors.yellow, width: 2),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const ExcludeSemantics(
        child: Text(
          'P',
          style: TextStyle(
            color: AdminColors.yellow,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    ),
  );
}

class _TopTab extends StatelessWidget {
  const _TopTab({
    required this.tab,
    required this.selected,
    required this.pending,
    required this.height,
  });
  final AdminTab tab;
  final bool selected;
  final int? pending;
  final double height;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    label: tab.path == '/review'
        ? '${tab.label}，${_pendingLabel(pending)}'
        : tab.label,
    excludeSemantics: true,
    child: InkWell(
      key: ValueKey('nav${tab.path}'),
      onTap: () => context.go(tab.path),
      child: Container(
        height: height,
        constraints: const BoxConstraints(minWidth: 48),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? AdminColors.yellow : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tab.label,
              style: TextStyle(
                color: selected ? AdminColors.white : _barInk,
                fontSize: 15,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
            if (pending case final n? when n > 0) ...[
              const SizedBox(width: 6),
              _CountBadge(n),
            ],
          ],
        ),
      ),
    ),
  );
}

class _CountBadge extends StatelessWidget {
  const _CountBadge(this.count);
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    // No alignment: an aligned box would stretch to the bar's height.
    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
    decoration: BoxDecoration(
      color: AdminColors.red,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      count > 99 ? '99+' : '$count',
      textAlign: TextAlign.center,
      style: const TextStyle(
        color: AdminColors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
    ),
  );
}

/// The account's security page and signing out, behind one 48 px button.
class _AccountMenu extends StatelessWidget {
  const _AccountMenu({required this.controller, required this.onSignOut});
  final AdminController controller;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final email = controller.access.email;
    return PopupMenuButton<String>(
      key: const ValueKey('account-menu'),
      tooltip: '帳號與安全',
      icon: const Icon(Icons.account_circle_outlined, color: AdminColors.white),
      iconSize: 24,
      onSelected: (value) =>
          value == 'out' ? onSignOut() : context.go('/security'),
      itemBuilder: (context) => [
        if (email != null)
          PopupMenuItem<String>(
            enabled: false,
            child: Text(email, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        const PopupMenuItem<String>(
          value: 'security',
          child: ListTile(
            leading: Icon(Icons.manage_accounts_outlined),
            title: Text('帳號安全'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem<String>(
          value: 'out',
          enabled: !controller.busy,
          child: const ListTile(
            leading: Icon(Icons.logout),
            title: Text('登出'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// One line under the top bar until a second authenticator is enrolled;
/// it folds away for the session.
class _AuthenticatorNotice extends StatelessWidget {
  const _AuthenticatorNotice({required this.missing, required this.onHide});
  final int missing;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.only(left: 16),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            AdminColors.yellow.withValues(alpha: .16),
            colors.surface,
          ),
          border: Border(
            bottom: BorderSide(color: AdminColors.yellow.withValues(alpha: .5)),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              size: 18,
              color: colors.onSurface,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                missing >= 2 ? '尚未登記驗證器 App' : '還要再登記一個驗證器 App',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
            TextButton(
              key: const ValueKey('enroll-authenticator'),
              onPressed: () => context.go('/security'),
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('登記'),
            ),
            IconButton(
              tooltip: '暫時收起提示',
              onPressed: onHide,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// Below 680 px: the five tabs at the bottom, the current one marked by a
/// yellow line above it.
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.section, required this.pending});
  final String section;
  final int? pending;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: Container(
          height: 72,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: Semantics(
            label: '管理功能',
            container: true,
            child: Row(
              children: [
                for (final tab in adminTabs)
                  Expanded(
                    child: _BottomTab(
                      tab: tab,
                      selected: section == tab.path,
                      pending: tab.path == '/review' ? pending : null,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomTab extends StatelessWidget {
  const _BottomTab({
    required this.tab,
    required this.selected,
    required this.pending,
  });
  final AdminTab tab;
  final bool selected;
  final int? pending;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ink = selected ? colors.onSurface : colors.onSurfaceVariant;
    return Semantics(
      selected: selected,
      button: true,
      label: tab.path == '/review'
          ? '${tab.label}，${_pendingLabel(pending)}'
          : tab.label,
      excludeSemantics: true,
      child: InkWell(
        key: ValueKey('nav${tab.path}'),
        onTap: () => context.go(tab.path),
        child: Stack(
          children: [
            if (selected)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: FractionallySizedBox(
                  widthFactor: .56,
                  child: SizedBox(
                    height: 4,
                    child: ColoredBox(color: AdminColors.yellow),
                  ),
                ),
              ),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Badge(
                    isLabelVisible: (pending ?? 0) > 0,
                    backgroundColor: AdminColors.red,
                    label: Text(
                      (pending ?? 0) > 99 ? '99+' : '${pending ?? 0}',
                    ),
                    child: Icon(tab.icon, size: 24, color: ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tab.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.2,
                      color: ink,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
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

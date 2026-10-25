import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import 'admin_auth_page.dart';
import 'admin_controller.dart';
import 'admin_mfa_page.dart';
import 'admin_theme.dart';
import 'review/hidden_page.dart';
import 'review/review_controller.dart';
import 'review/review_map.dart';
import 'review/review_page.dart';
import '../ui/location_picker.dart';
import 'spots/spot_models.dart';
import 'spots/spots_controller.dart';
import 'spots/spots_page.dart';

const _tabs = [
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
    description: '在這裡檢視各縣市的普通機車與大型重機停放規則。',
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

class AdminApp extends StatefulWidget {
  const AdminApp({
    super.key,
    required this.controller,
    this.initialLocation,
    this.themeMode = ThemeMode.system,
    this.reviewMapBuilder = googleReviewMap,
    this.locationMapBuilder,
    this.review,
  });
  final AdminController controller;
  final String? initialLocation;
  final ThemeMode themeMode;
  final ReviewMapBuilder reviewMapBuilder;

  /// Tests replace the location picker's Google map.
  final LocationMapBuilder? locationMapBuilder;

  /// Injected by tests; otherwise created over the controller's gateway.
  final ReviewController? review;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  late final ReviewController _review =
      widget.review ??
      ReviewController(
        widget.controller.gateway,
        onResolved: () => widget.controller.refreshCount(),
      );
  late final SpotsController _spots = SpotsController(
    widget.controller.gateway,
  );
  String? _reviewUser;

  @override
  void initState() {
    super.initState();
    _reviewUser = _readyUser();
    widget.controller.addListener(_accessChanged);
  }

  /// Queue data is private: drop it as soon as access is lost or changes.
  String? _readyUser() => widget.controller.stage == AdminStage.ready
      ? widget.controller.access.userId
      : null;

  void _accessChanged() {
    final user = _readyUser();
    if (user != _reviewUser) {
      _reviewUser = user;
      _review.reset();
      _spots.reset();
    }
  }

  /// A decision still in its undo window is written before signing out.
  Future<void> _signOut() async {
    await _review.flush();
    await widget.controller.signOut();
  }

  Widget _watch(Widget Function() build) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => build(),
  );

  late final GoRouter _router = GoRouter(
    initialLocation: widget.initialLocation,
    refreshListenable: widget.controller,
    redirect: (context, state) {
      final ready = widget.controller.stage == AdminStage.ready;
      if (!ready) return state.uri.path == '/auth' ? null : '/auth';
      return state.uri.path == '/auth' || state.uri.path == '/'
          ? '/review'
          : null;
    },
    routes: [
      GoRoute(path: '/', redirect: (context, state) => '/review'),
      GoRoute(
        path: '/auth',
        builder: (context, state) =>
            _watch(() => AdminAuthPage(controller: widget.controller)),
      ),
      ShellRoute(
        builder: (context, state, child) => _watch(
          () => _AdminShell(
            controller: widget.controller,
            path: state.uri.path,
            onSignOut: _signOut,
            child: child,
          ),
        ),
        routes: [
          // Declared before /review/:id so "hidden" is never read as an id.
          GoRoute(
            path: '/review/hidden',
            builder: (context, state) => HiddenSpotsPage(review: _review),
          ),
          for (final path in ['/review', '/review/:id'])
            GoRoute(
              path: path,
              builder: (context, state) => ReviewPage(
                admin: widget.controller,
                review: _review,
                selectedId: state.pathParameters['id'],
                mapBuilder: widget.reviewMapBuilder,
              ),
            ),
          for (final path in ['/spots', '/spots/:id'])
            GoRoute(
              path: path,
              builder: (context, state) => SpotsPage(
                spots: _spots,
                selectedId: state.pathParameters['id'],
                newKind: SpotKind.values
                    .asNameMap()[state.uri.queryParameters['kind']],
                locationMapBuilder: widget.locationMapBuilder,
              ),
            ),
          for (final tab in _tabs.skip(2))
            GoRoute(
              path: tab.path,
              builder: (context, state) => _watch(
                () => _AdminBody(
                  child: _WorkspacePage(
                    controller: widget.controller,
                    path: tab.path,
                  ),
                ),
              ),
            ),
          GoRoute(
            path: '/security',
            builder: (context, state) => _watch(
              () => _AdminBody(
                child: AdminPanel(
                  child: AdminMfaPage(
                    controller: widget.controller,
                    settings: true,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => context.go('/review'),
          child: const Text('返回審核桌'),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_accessChanged);
    if (widget.review == null) _review.dispose();
    _spots.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp.router(
      title: '停車指南管理',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        cu.GlobalCupertinoLocalizations.delegate,
      ],
      theme: adminTheme(Brightness.light),
      darkTheme: adminTheme(Brightness.dark),
      themeMode: widget.themeMode,
      // ignore: deprecated_member_use
      builder: (context, child) => MaterialUiCompatibilityBridge(child: child!),
    ),
  );
}

class _AdminShell extends StatelessWidget {
  const _AdminShell({
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(
                  bottom: BorderSide(color: colors.outlineVariant),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final compact = constraints.maxWidth < 1040;
                    final navigation = Semantics(
                      label: '管理功能',
                      container: true,
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          for (final tab in _tabs)
                            Semantics(
                              selected: _section(path) == tab.path,
                              child: TextButton(
                                key: ValueKey('nav${tab.path}'),
                                onPressed: () => context.go(tab.path),
                                style: TextButton.styleFrom(
                                  foregroundColor: _section(path) == tab.path
                                      ? colors.onSurface
                                      : colors.onSurfaceVariant,
                                  backgroundColor: _section(path) == tab.path
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
                                        fontWeight: _section(path) == tab.path
                                            ? FontWeight.w700
                                            : FontWeight.w400,
                                      ),
                                    ),
                                    if (tab.path == '/review') ...[
                                      const SizedBox(width: 8),
                                      Semantics(
                                        label: controller.pendingCount == null
                                            ? '待審數尚未取得'
                                            : '${controller.pendingCount} 筆待審',
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
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: ExcludeSemantics(
                                            child: Text(
                                              controller.pendingCount
                                                      ?.toString() ??
                                                  '—',
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
                    );
                    final account = Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!compact) ...[
                          Icon(
                            Icons.verified_user_outlined,
                            size: 18,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '兩步驟驗證已通過',
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                        ],
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
                    );
                    return compact
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(child: AdminBrand()),
                                  account,
                                ],
                              ),
                              const SizedBox(height: 12),
                              navigation,
                            ],
                          )
                        : Row(
                            children: [
                              const SizedBox(width: 210, child: AdminBrand()),
                              const SizedBox(width: 20),
                              Expanded(child: navigation),
                              account,
                            ],
                          );
                  },
                ),
              ),
            ),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: AdminNotice(controller.error!, error: true),
              ),
            if (controller.authenticatorCount < 2 && path != '/security')
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
              ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _AdminBody extends StatelessWidget {
  const _AdminBody({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 48),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: child,
        ),
      ),
    ),
  );
}

class _WorkspacePage extends StatelessWidget {
  const _WorkspacePage({required this.controller, required this.path});
  final AdminController controller;
  final String path;

  @override
  Widget build(BuildContext context) {
    final tab = _tabs.firstWhere((t) => t.path == path);
    final text = Theme.of(context).textTheme;
    return AdminPanel(
      width: 1400,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(tab.title, style: text.headlineMedium),
          ),
          const SizedBox(height: 24),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    Icon(
                      tab.icon,
                      size: 40,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '${tab.label}工作區準備中',
                      style: text.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      tab.description,
                      style: text.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '此工作區的操作功能尚未開放。',
                      style: text.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `/review/<id>` belongs to the review tab.
String _section(String path) =>
    '/${path.split('/').where((p) => p.isNotEmpty).firstOrNull ?? ''}';

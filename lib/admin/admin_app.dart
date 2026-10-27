import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../models/parking.dart';
import 'admin_auth_page.dart';
import 'admin_controller.dart';
import 'admin_layout.dart';
import 'admin_mfa_page.dart';
import 'admin_shell.dart';
import 'admin_theme.dart';
import 'import/file_pick.dart';
import 'import/import_controller.dart';
import 'import/import_page.dart';
import 'review/hidden_page.dart';
import 'review/review_controller.dart';
import 'review/review_map.dart';
import 'review/review_page.dart';
import '../ui/location_picker.dart';
import 'rules/rules_controller.dart';
import 'rules/rules_page.dart';
import 'spots/spot_map.dart';
import 'spots/spot_models.dart';
import 'spots/spots_controller.dart';
import 'spots/spots_page.dart';
import 'users/users_controller.dart';
import 'users/users_page.dart';

class AdminApp extends StatefulWidget {
  const AdminApp({
    super.key,
    required this.controller,
    this.initialLocation,
    this.themeMode = ThemeMode.system,
    this.reviewMapBuilder = googleReviewMap,
    this.locationMapBuilder,
    this.spotMapBuilder = googleSpotMap,
    this.review,
    this.pickFile = pickJsonFile,
    this.bundledRules,
  });
  final AdminController controller;
  final String? initialLocation;
  final ThemeMode themeMode;
  final ReviewMapBuilder reviewMapBuilder;

  /// Tests replace the location picker's Google map.
  final LocationMapBuilder? locationMapBuilder;

  /// Tests replace the spots page's Google map.
  final SpotMapBuilder spotMapBuilder;

  /// Injected by tests; otherwise created over the controller's gateway.
  final ReviewController? review;

  /// Tests replace the browser's file dialog.
  final FilePicker pickFile;

  /// Tests replace the app's bundled rule file.
  final Future<List<dynamic>> Function()? bundledRules;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  // A write on one page refreshes every other page showing the same data:
  // lists, map markers, the open form and the pending count (決定 49).
  late final ReviewController _review =
      widget.review ??
      ReviewController(
        widget.controller.gateway,
        onResolved: () => widget.controller.refreshCount(),
        onSpotChanged: (id) => _spotsWritten({id}),
      );
  late final SpotsController _spots = SpotsController(
    widget.controller.gateway,
    onChanged: _reviewStale,
  );
  late final ImportController _imports = ImportController(
    widget.controller.gateway,
    onApplied: (ids) {
      _spotsWritten(ids);
      _reviewStale();
    },
  );
  late final FeeConversionController _fees = FeeConversionController(
    widget.controller.gateway,
    onApplied: (ids) {
      _spotsWritten(ids);
      _reviewStale();
    },
  );
  late final RulesController _rules = RulesController(
    widget.controller.gateway,
    bundled: widget.bundledRules ?? bundledRules,
    onPublished: () => _spotMap.reloadRules(),
  );
  late final UsersController _users = UsersController(
    widget.controller.gateway,
  );
  late final SpotMapController _spotMap = SpotMapController(
    widget.controller.gateway,
  );
  String? _reviewUser;

  /// Spots changed outside the spots page.
  void _spotsWritten(Set<String> ids) {
    _spots.refresh(ids);
    _spotMap.refresh();
  }

  /// Spots changed outside the review page: the queue's current values
  /// and the hidden list read again.
  void _reviewStale() {
    if (_review.loaded) _review.load();
    if (_review.hiddenLoaded) _review.loadHidden();
  }

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
      _imports.reset();
      _fees.reset();
      _rules.reset();
      _users.reset();
      _spotMap.reset();
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
          () => AdminShell(
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
              // One page for the queue and every report (決定 48): picking
              // a report swaps the detail; the queue keeps its scroll,
              // filter and selection.
              pageBuilder: (context, state) => MaterialPage(
                key: const ValueKey('review'),
                child: ReviewPage(
                  admin: widget.controller,
                  review: _review,
                  selectedId: state.pathParameters['id'],
                  mapBuilder: widget.reviewMapBuilder,
                ),
              ),
            ),
          for (final path in ['/spots', '/spots/:id'])
            GoRoute(
              path: path,
              // One page for the list and every spot: the map keeps its
              // camera and loaded spots while forms open and close.
              pageBuilder: (context, state) => MaterialPage(
                key: const ValueKey('spots'),
                child: SpotsPage(
                  spots: _spots,
                  map: _spotMap,
                  selectedId: state.pathParameters['id'],
                  newKind: SpotKind.values
                      .asNameMap()[state.uri.queryParameters['kind']],
                  locationMapBuilder: widget.locationMapBuilder,
                  spotMapBuilder: widget.spotMapBuilder,
                ),
              ),
            ),
          for (final path in ['/imports', '/imports/fees'])
            GoRoute(
              path: path,
              builder: (context, state) => ImportPage(
                imports: _imports,
                fees: _fees,
                feeSection: path.endsWith('/fees'),
                pickFile: widget.pickFile,
              ),
            ),
          for (final path in ['/rules', '/rules/:city/:vehicle'])
            GoRoute(
              path: path,
              pageBuilder: (context, state) => MaterialPage(
                key: const ValueKey('rules'),
                child: RulesPage(
                  rules: _rules,
                  city: state.pathParameters['city'],
                  vehicle: VehicleType.values
                      .asNameMap()[state.pathParameters['vehicle']],
                ),
              ),
            ),
          for (final path in ['/users', '/users/:id'])
            GoRoute(
              path: path,
              pageBuilder: (context, state) => MaterialPage(
                key: const ValueKey('users'),
                child: UsersPage(
                  users: _users,
                  selectedId: state.pathParameters['id'],
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
    _imports.dispose();
    _fees.dispose();
    _rules.dispose();
    _users.dispose();
    _spotMap.dispose();
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
      builder: (context, child) =>
          // ignore: deprecated_member_use
          MaterialUiCompatibilityBridge(child: AdminViewport(child: child!)),
    ),
  );
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

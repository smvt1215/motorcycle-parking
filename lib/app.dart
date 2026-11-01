import 'dart:async';

import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:material_3_expressive/material_3_expressive.dart';

import 'core/update_gate.dart';
import 'data/account_deletion.dart';
import 'data/app_store.dart';
import 'ui/adaptive/adaptive.dart';
import 'features/map/map_legend_page.dart';
import 'features/map/map_page.dart';
import 'features/rules/rules_page.dart';
import 'features/my_parking/parking_page.dart';
import 'features/favorites/favorites_page.dart';
import 'features/settings/account_deletion_status.dart';
import 'features/settings/settings_page.dart';
import 'features/contribute/contribute_page.dart';
import 'features/contribute/my_contributions_page.dart';
import 'features/launch/launch_screen.dart';
import 'features/auth/sign_in.dart';
import 'features/update/update_required_page.dart';

class ParkingApp extends ConsumerStatefulWidget {
  const ParkingApp({
    super.key,
    this.themeMode = ThemeMode.system,
    this.updateGate,
  });
  final ThemeMode themeMode;

  /// Blocks the app while it is older than the backend's minimum (P14);
  /// read through the store's client by default.
  final UpdateGate? updateGate;
  @override
  ConsumerState<ParkingApp> createState() => _ParkingAppState();
}

class _ParkingAppState extends ConsumerState<ParkingApp> {
  late final UpdateGate updates =
      widget.updateGate ?? UpdateGate.forClient(ref.read(storeProvider).client);
  late final AccountDeletionController deletion = ref.read(
    accountDeletionProvider,
  );

  /// Checks again whenever the app returns, e.g. from the store.
  late final AppLifecycleListener lifecycle;

  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onResume: () => unawaited(updates.check()),
    );
    unawaited(updates.check());
    deletion.start();
  }

  late final GoRouter router = GoRouter(
    initialLocation: '/map',
    observers: [CNTabBarRouteObserver()],
    refreshListenable: Listenable.merge([updates, deletion]),
    // While blocked P14 is the only route: nothing to go back to, and its
    // PopScope keeps the system back button and gesture on it. Otherwise a
    // pending deletion (P15b ②) and the signed-out notice (①) come before
    // every other page (#215).
    redirect: (context, state) {
      final blocked = updates.required != null;
      final onUpdate = state.uri.path == updateRequiredPath;
      if (blocked && !onUpdate) return updateRequiredPath;
      if (!blocked && onUpdate) return '/map';
      if (blocked) return null;
      return accountDeletionRedirect(deletion, state.uri.path);
    },
    routes: [
      GoRoute(
        path: updateRequiredPath,
        builder: (context, state) => switch (updates.required) {
          final requirement? => UpdateRequiredPage(requirement: requirement),
          null => const SizedBox.shrink(),
        },
      ),
      GoRoute(
        path: pendingDeletionPath,
        builder: (context, state) => PendingDeletionPage(deletion: deletion),
      ),
      GoRoute(
        path: deletionNoticePath,
        builder: (context, state) => ListenableBuilder(
          listenable: deletion,
          builder: (context, _) => DeletionNoticePage(
            deletion: deletion,
            store: ref.read(storeProvider),
          ),
        ),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AnimatedBuilder(
          animation: ref.read(storeProvider),
          builder: (context, _) => AdaptiveScaffold(
            index: shell.currentIndex,
            onTab: (i) => shell.goBranch(i),
            onSettings: () => showSettings(context, ref.read(storeProvider)),
            child: Stack(
              children: [
                // A page of the map tab (地圖怎麼看) covers the map: the map
                // keeps its state (an open spot stays open behind the page)
                // but is neither read out nor animated while covered.
                ExcludeSemantics(
                  excluding: mapCovered(shell.currentIndex, state.uri.path),
                  child: TickerMode(
                    enabled: !mapCovered(shell.currentIndex, state.uri.path),
                    child: MapPage(
                      showControls: shell.currentIndex == 0,
                      covered: mapCovered(shell.currentIndex, state.uri.path),
                    ),
                  ),
                ),
                Offstage(
                  // The map tab shows its own pages (地圖怎麼看) over the map.
                  offstage: shell.currentIndex == 0 && state.uri.path == '/map',
                  child: Material(
                    color: shell.currentIndex == 1 || shell.currentIndex == 3
                        ? Theme.of(context).colorScheme.surface
                        : Colors.transparent,
                    child: shell,
                  ),
                ),
              ],
            ),
          ),
        ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (context, state) => const SizedBox.shrink(),
                routes: [
                  GoRoute(
                    path: 'legend',
                    builder: (context, state) =>
                        const MapLegendPage(fromMap: true),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/rules',
                builder: (context, state) => const RulesPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/parking',
                builder: (context, state) => const ParkingPage(),
                routes: [
                  GoRoute(
                    path: 'legend',
                    builder: (context, state) =>
                        const MapLegendPage(fromMap: false),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/favorites',
                builder: (context, state) => const FavoritesPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/contribute',
                builder: (context, state) => const ContributePage(),
                routes: [
                  GoRoute(
                    path: 'mine',
                    builder: (context, state) => const MyContributionsPage(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
  @override
  void dispose() {
    router.dispose();
    lifecycle.dispose();
    if (widget.updateGate == null) updates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DynamicColorBuilder(
    builder: (light, dark) => MaterialApp.router(
      title: '機車停車指南',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      themeMode: widget.themeMode,
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        cu.GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme:
            light ??
            ColorScheme.fromSeed(seedColor: brand).copyWith(
              surface: const Color(0xfff9fbfc),
              primaryContainer: const Color(0xffc9eaf2),
              onPrimaryContainer: const Color(0xff154b58),
            ),
        useMaterial3: true,
        fontFamily: 'Outfit',
      ),
      darkTheme: ThemeData(
        colorScheme:
            dark ??
            ColorScheme.fromSeed(seedColor: brand, brightness: Brightness.dark),
        useMaterial3: true,
        fontFamily: 'Outfit',
      ),
      builder: (context, child) => M3ETheme(
        data: M3EThemeData.fromMaterial(Theme.of(context)),
        child: cu.CupertinoTheme(
          data: cu.CupertinoThemeData(
            brightness: Theme.of(context).brightness,
            primaryColor: Theme.of(context).colorScheme.primary,
            scaffoldBackgroundColor: Theme.of(context).colorScheme.surface,
          ),
          // Compatibility required by cupertino_native_better, see docs/PLAN.md.
          // ignore: deprecated_member_use
          child: MaterialUiCompatibilityBridge(
            // ignore: deprecated_member_use
            child: cu.CupertinoUiCompatibilityBridge(
              child: ListenableBuilder(
                listenable: ref.read(storeProvider),
                builder: (context, child) {
                  final store = ref.read(storeProvider);
                  return AuthFeedback(
                    store: store,
                    child: DeletionBannerOverlay(
                      deletion: deletion,
                      child: LaunchCurtain(
                        visible: store.starting,
                        locating: store.locatingAtLaunch,
                        child: child!,
                      ),
                    ),
                  );
                },
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// P14 需要更新.
const updateRequiredPath = '/update-required';

/// Whether a page of the map tab, such as /map/legend, covers the map.
bool mapCovered(int tab, String path) => tab == 0 && path != '/map';

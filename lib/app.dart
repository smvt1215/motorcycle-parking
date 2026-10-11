import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:material_3_expressive/material_3_expressive.dart';

import 'data/app_store.dart';
import 'ui/adaptive/adaptive.dart';
import 'features/map/map_page.dart';
import 'features/rules/rules_page.dart';
import 'features/my_parking/parking_page.dart';
import 'features/favorites/favorites_page.dart';
import 'features/report/report_sheet.dart';
import 'features/contribute/contribute_page.dart';

class ParkingApp extends ConsumerStatefulWidget {
  const ParkingApp({super.key, this.themeMode = ThemeMode.system});
  final ThemeMode themeMode;
  @override
  ConsumerState<ParkingApp> createState() => _ParkingAppState();
}

class _ParkingAppState extends ConsumerState<ParkingApp> {
  late final GoRouter router = GoRouter(
    initialLocation: '/map',
    observers: [CNTabBarRouteObserver()],
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AnimatedBuilder(
          animation: ref.read(storeProvider),
          builder: (context, _) => AdaptiveScaffold(
            index: shell.currentIndex,
            onTab: (i) => shell.goBranch(i),
            onSettings: () => showSettings(context, ref.read(storeProvider)),
            child: Stack(
              children: [
                MapPage(showControls: shell.currentIndex == 0),
                Offstage(
                  offstage: shell.currentIndex == 0,
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
            child: cu.CupertinoUiCompatibilityBridge(child: child!),
          ),
        ),
      ),
    ),
  );
}

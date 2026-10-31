import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../data/app_store.dart';
import '../../domain/contribution_display.dart';
import '../../ui/adaptive/adaptive.dart';
import 'my_contributions.dart';

/// Where the contribute tab pushes the full list; the shell keeps the tab
/// bar under it.
const myContributionsPath = '/contribute/mine';

/// 我送出的建議 (P9): every contribution, pushed from the contribute tab.
class MyContributionsPage extends ConsumerWidget {
  const MyContributionsPage({super.key, this.now});

  /// Fixed in tests so dates read the same every run.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final store = ref.watch(storeProvider);
    final colors = Theme.of(context).colorScheme;
    void back() => context.canPop() ? context.pop() : context.go('/contribute');
    return Scaffold(
      backgroundColor: isCupertino
          ? colors.surfaceContainerLow
          : colors.surface,
      appBar: isCupertino
          ? cu.CupertinoNavigationBar(
              leading: cu.CupertinoNavigationBarBackButton(
                previousPageTitle: '貢獻',
                onPressed: back,
              ),
              middle: const Text(myContributionsTitle),
              backgroundColor: colors.surface.withValues(alpha: .9),
            )
          : M3EAppBar.top(
              titleText: myContributionsTitle,
              leading: IconButton(
                tooltip: '返回',
                onPressed: back,
                icon: const Icon(Icons.arrow_back),
              ),
            ),
      body: ListView(
        // The shell's iOS tab bar floats over the page (extendBody), and
        // its height already arrives as bottom padding; Android's bar sits
        // below the body. Either way only a small gap is added.
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [MyContributionsSection(store: store, now: now)],
      ),
    );
  }
}

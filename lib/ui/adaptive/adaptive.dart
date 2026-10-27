import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

import '../../core/location_access.dart';
import '../../models/parking.dart';

export 'package:material_ui/material_ui.dart';
export 'package:cupertino_native_better/cupertino_native_better.dart'
    show CNTabBarRouteObserver;

bool get isCupertino => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
bool get nativeGlass => isCupertino && PlatformVersion.isIOS26OrLater;
const brand = Color(0xff176273);
const allowedColor = Color(0xff186348);
const conditionalColor = Color(0xff865500);
const deniedColor = Color(0xffa13042);

/// The view's most likely action is prominent (HIG prominent style, M3
/// filled); pass [secondary] for alternatives shown beside it.
class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.secondary = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool secondary;
  @override
  Widget build(BuildContext context) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon), const SizedBox(width: 8)],
        Text(label),
      ],
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: nativeGlass
          ? CNButton(
              label: label,
              onPressed: onPressed,
              enabled: onPressed != null,
              tint: Theme.of(context).colorScheme.primary,
              config: CNButtonConfig(
                style: secondary
                    ? CNButtonStyle.glass
                    : CNButtonStyle.prominentGlass,
              ),
            )
          : isCupertino
          ? secondary
                ? cu.CupertinoButton.tinted(onPressed: onPressed, child: child)
                : cu.CupertinoButton.filled(onPressed: onPressed, child: child)
          : M3EButton(
              onPressed: onPressed,
              style: secondary ? M3EButtonStyle.tonal : M3EButtonStyle.filled,
              child: child,
            ),
    );
  }
}

class VehicleSelector extends StatelessWidget {
  const VehicleSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final VehicleType value;
  final ValueChanged<VehicleType> onChanged;
  @override
  Widget build(BuildContext context) {
    if (nativeGlass) {
      return SizedBox(
        height: 48,
        child: CNSegmentedControl(
          labels: VehicleType.values.map((v) => v.label).toList(),
          selectedIndex: value.index,
          onValueChanged: (i) => onChanged(VehicleType.values[i]),
          color: Theme.of(context).colorScheme.primary,
        ),
      );
    }
    if (isCupertino) {
      return SizedBox(
        height: 48,
        child: cu.CupertinoSlidingSegmentedControl<VehicleType>(
          groupValue: value,
          children: {
            for (final v in VehicleType.values)
              v: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(v.label),
              ),
          },
          onValueChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );
    }
    return M3EButtonGroup(
      actions: [
        for (final v in VehicleType.values)
          M3EButtonGroupAction(label: Text(v.label), semanticLabel: v.label),
      ],
      selectedIndex: value.index,
      selectionRequired: true,
      type: M3EButtonGroupType.connected,
      onSelectedIndexChanged: (i) {
        if (i != null) onChanged(VehicleType.values[i]);
      },
    );
  }
}

class AdaptiveScaffold extends StatelessWidget {
  const AdaptiveScaffold({
    super.key,
    required this.index,
    required this.onTab,
    required this.child,
    required this.onSettings,
  });
  final int index;
  final ValueChanged<int> onTab;
  final Widget child;
  final VoidCallback onSettings;
  @override
  Widget build(BuildContext context) {
    final selected = index == 0
        ? 0
        : index == 4
        ? 2
        : 1;
    void select(int i) {
      if (i == 2) {
        onTab(4);
      } else {
        onTab(i == 0 ? 0 : 2);
      }
    }

    const labels = ['探索', '個人中心', '貢獻'];
    const icons = [
      Icons.place_outlined,
      Icons.bookmark_outline,
      Icons.add_circle_outline,
    ];
    final bar = nativeGlass
        ? CNTabBar(
            items: const [
              CNTabBarItem(
                label: '探索',
                icon: CNSymbol('map'),
                activeIcon: CNSymbol('map.fill'),
              ),
              CNTabBarItem(
                label: '個人中心',
                icon: CNSymbol('bookmark'),
                activeIcon: CNSymbol('bookmark.fill'),
              ),
              CNTabBarItem(label: '貢獻', icon: CNSymbol('plus.circle')),
            ],
            currentIndex: selected,
            onTap: select,
          )
        : isCupertino
        ? cu.CupertinoTabBar(
            currentIndex: selected,
            onTap: select,
            items: [
              for (var i = 0; i < 3; i++)
                BottomNavigationBarItem(icon: Icon(icons[i]), label: labels[i]),
            ],
          )
        : M3ENavigationBar(
            selectedIndex: selected,
            onDestinationSelected: select,
            destinations: [
              for (var i = 0; i < 3; i++)
                M3ENavigationBarDestination(
                  icon: Icon(icons[i]),
                  label: labels[i],
                ),
            ],
          );
    final title = index == 1
        ? '停車規則'
        : index == 3
        ? '我的收藏'
        : '個人中心';
    final back = index == 1 || index == 3;
    return Scaffold(
      extendBody: isCupertino,
      // The keyboard overlays the map instead of resizing it: a resized
      // native map view lags behind and shows blank bands while it catches
      // up. Search results size themselves to the keyboard (MapPage).
      resizeToAvoidBottomInset: false,
      appBar: !back
          ? null
          : isCupertino
          ? cu.CupertinoNavigationBar(
              middle: Text(title),
              leading: back
                  ? cu.CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => onTab(2),
                      child: const Icon(Icons.arrow_back_ios_new),
                    )
                  : null,
              backgroundColor: Theme.of(context).colorScheme.surface
                  .withValues(alpha: .9),
              trailing: nativeGlass
                  ? CNButton.icon(
                      icon: const CNSymbol('gearshape'),
                      onPressed: onSettings,
                      tint: Theme.of(context).colorScheme.primary,
                    )
                  : cu.CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: onSettings,
                      child: const Icon(Icons.settings_outlined),
                    ),
            )
          : M3EAppBar.top(
              titleText: title,
              leading: back
                  ? IconButton(
                      tooltip: '返回個人中心',
                      onPressed: () => onTab(2),
                      icon: const Icon(Icons.arrow_back),
                    )
                  : null,
              actions: [
                IconButton(
                  tooltip: '設定與登入',
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
      body: child,
      bottomNavigationBar: bar,
    );
  }
}

/// Map actions: locate and record parking, bottom-trailing in thumb reach.
/// iOS: equal-size buttons, the record action prominent (HIG: style, not size).
/// Android: M3E floating toolbar for locate, the 80dp M3E FAB to record.
class MapActions extends StatelessWidget {
  const MapActions({super.key, required this.onLocate, required this.onRecord});
  final VoidCallback onLocate, onRecord;

  /// Horizontal space the actions take, so neighbors can stay clear of them.
  /// Compact, as in map apps: the map stays the focus.
  static double get width => isCupertino ? MapAction.size : 56;

  @override
  Widget build(BuildContext context) {
    if (isCupertino) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MapAction(
            label: '定位到我',
            icon: Icons.my_location,
            onPressed: onLocate,
          ),
          const SizedBox(height: 12),
          // Not a P: that is the map's "parkable" marker.
          MapAction(
            label: '我停這裡',
            icon: Icons.add_location_alt_outlined,
            primary: true,
            onPressed: onRecord,
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        M3EFab(
          key: const ValueKey('locate-fab'),
          size: M3EFabSize.regular,
          color: M3EFabColor.secondary,
          icon: const Icon(Icons.my_location),
          tooltip: '定位到我',
          onPressed: onLocate,
        ),
        const SizedBox(height: 12),
        M3EFab(
          key: const ValueKey('record-fab'),
          size: M3EFabSize.regular,
          icon: const Icon(Icons.add_location_alt_outlined),
          tooltip: '我停這裡',
          onPressed: onRecord,
        ),
      ],
    );
  }
}

/// One iOS map action; Android uses the M3E toolbar and FAB in [MapActions].
class MapAction extends StatelessWidget {
  const MapAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary;

  /// Still above the 44pt minimum touch target.
  static const size = 48.0;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (nativeGlass) {
      // Map controls are native Liquid Glass: no Flutter fill or shadow, so
      // the glass samples the map and follows system transparency settings.
      return SizedBox.square(
        dimension: size,
        child: CNButton.icon(
          icon: CNSymbol(primary ? 'mappin.and.ellipse' : 'location'),
          tint: colors.primary,
          config: CNButtonConfig(
            style: primary ? CNButtonStyle.prominentGlass : CNButtonStyle.glass,
            width: size,
            minHeight: size,
          ),
          onPressed: onPressed,
        ),
      );
    }
    return Material(
      color: primary ? colors.primary : colors.surface,
      elevation: 3,
      shadowColor: const Color(0x55000000),
      borderRadius: BorderRadius.circular(16),
      child: SizedBox.square(
        dimension: size,
        child: cu.CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: onPressed,
          child: Icon(
            icon,
            color: primary ? colors.onPrimary : colors.onSurface,
            semanticLabel: label,
          ),
        ),
      ),
    );
  }
}

Future<T?> showAdaptiveSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  bool detail = false,
}) {
  if (isCupertino) {
    // Overlay the map: Cupertino's stacked-card route scales the page below.
    return CNBottomSheet.show<T>(
      context: context,
      useRootNavigator: true,
      // Details keep the map undimmed above them, as map apps do; tapping
      // the map still closes the sheet.
      barrierColor: detail ? Colors.transparent : null,
      enableDrag: !detail,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: detail ? Colors.transparent : null,
      builder: (ctx) => detail
          ? builder(ctx)
          : Material(
              color: Theme.of(ctx).colorScheme.surface,
              child: SafeArea(child: builder(ctx)),
            ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    barrierColor: detail ? Colors.transparent : null,
    enableDrag: !detail,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: !detail,
    backgroundColor: detail ? Colors.transparent : null,
    builder: builder,
  );
}

void showMessage(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
Future<void> runAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } on LocationAccessError catch (e) {
    if (context.mounted) await showLocationPrompt(context, e.issue);
  } catch (e) {
    if (context.mounted) {
      showMessage(
        context,
        e is StateError ? e.message.toString() : '操作失敗，請確認連線後重試',
      );
    }
  }
}

/// Explains why location is unavailable and opens the settings page that
/// fixes it.
Future<void> showLocationPrompt(BuildContext context, LocationIssue issue) =>
    showAdaptiveDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        key: const ValueKey('location-prompt'),
        title: Text(issue.title),
        content: Text(issue.message),
        actions: [
          adaptiveDialogAction(
            ctx,
            label: issue.canOpenSettings ? '稍後' : '知道了',
            onPressed: () => Navigator.pop(ctx),
          ),
          if (issue.canOpenSettings)
            adaptiveDialogAction(
              ctx,
              label: issue.action,
              primary: true,
              onPressed: () {
                Navigator.pop(ctx);
                // Nothing more to offer if the page cannot open.
                unawaited(issue.openSettings().catchError((_) => false));
              },
            ),
        ],
      ),
    );

/// A dialog button in the platform's style: Cupertino on iOS, text button
/// elsewhere.
Widget adaptiveDialogAction(
  BuildContext context, {
  required String label,
  required VoidCallback onPressed,
  bool primary = false,
}) => isCupertino
    ? cu.CupertinoDialogAction(
        isDefaultAction: primary,
        onPressed: onPressed,
        child: Text(label),
      )
    : TextButton(onPressed: onPressed, child: Text(label));

/// Sheet heading with a close button, so every sheet can be dismissed
/// without relying on drag or tapping outside.
class SheetTitle extends StatelessWidget {
  const SheetTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
      ),
      IconButton(
        tooltip: '關閉',
        onPressed: () => Navigator.pop(context),
        icon: const Icon(Icons.close),
      ),
    ],
  );
}

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.children, this.lazy = true});
  final List<Widget> children;

  /// Whether rows build only as they scroll into view. A form whose
  /// sections hold their own [Form]s builds them all (false), so a check
  /// on send reaches every field, not only the ones on screen.
  final bool lazy;
  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(20, 16, 20, 110);
    return SafeArea(
      // Sized to its content: a short sheet does not fill the screen with
      // empty space, and a long one still scrolls at full height.
      child: lazy
          ? ListView(shrinkWrap: true, padding: padding, children: children)
          : SingleChildScrollView(
              padding: padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart' as cu;
import 'package:cupertino_native_better/cupertino_native_better.dart';
import 'package:material_3_expressive/material_3_expressive.dart';

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

class AdaptiveButton extends StatelessWidget {
  const AdaptiveButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
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
            )
          : isCupertino
          ? cu.CupertinoButton.filled(onPressed: onPressed, child: child)
          : M3EButton(onPressed: onPressed, child: child),
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

class MapAction extends StatelessWidget {
  const MapAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
    this.tonal = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool primary, tonal;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (nativeGlass) {
      // Map controls are native Liquid Glass: no Flutter fill or shadow, so
      // the glass samples the map and follows system transparency settings.
      return SizedBox.square(
        dimension: 56,
        child: CNButton.icon(
          icon: CNSymbol(
            primary
                ? 'arrow.turn.up.right'
                : tonal
                ? 'square.3.layers.3d'
                : 'location',
          ),
          tint: colors.primary,
          config: CNButtonConfig(
            style: primary ? CNButtonStyle.prominentGlass : CNButtonStyle.glass,
            width: 56,
            minHeight: 56,
          ),
          onPressed: onPressed,
        ),
      );
    }
    final color = primary
        ? colors.primary
        : tonal
        ? colors.primaryContainer
        : colors.surface;
    final foreground = primary
        ? colors.onPrimary
        : tonal
        ? colors.onPrimaryContainer
        : colors.onSurface;
    return Material(
      color: color,
      elevation: 3,
      shadowColor: const Color(0x55000000),
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        width: 56,
        height: 56,
        child: isCupertino
            ? cu.CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: onPressed,
                child: Icon(icon, color: foreground, semanticLabel: label),
              )
            : IconButton(
                tooltip: label,
                onPressed: onPressed,
                icon: Icon(icon, color: foreground, size: 26),
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
    if (!detail) {
      return CNBottomSheet.showCupertino<T>(
        context: context,
        pageBuilder: (ctx) => Material(
          color: Theme.of(ctx).colorScheme.surface,
          child: SafeArea(child: builder(ctx)),
        ),
      );
    }
    return CNBottomSheet.show<T>(
      context: context,
      useRootNavigator: true,
      enableDrag: false,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: builder,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
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
  } catch (e) {
    if (context.mounted) {
      showMessage(
        context,
        e is StateError ? e.message.toString() : '操作失敗，請確認連線後重試',
      );
    }
  }
}

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 110),
      children: children,
    ),
  );
}

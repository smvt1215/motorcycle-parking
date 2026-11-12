import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// The tablet layout (canvas T1 portrait, T2 landscape): the search field
/// and one panel share a column on the leading side, the map stays in view
/// beside them. Details, tab panels and sheets that opt in all take the
/// same place, so the map never jumps between them.
///
/// Two things decide it (user decision 2026-11-12): the device is a tablet,
/// and the app's window has room for the panel column beside a usable map.
///
/// The device: its display's shorter side is 600 or more, Android's own
/// line between phones and tablets (sw600dp). Every iPad is over it (744 at
/// the least), every phone under it however it is held (440 at the most),
/// and a foldable is a tablet while open and a phone while shut, since its
/// cover is another display.
const tabletMinShortSide = 600.0;

/// The window: the panel column (16 + 400 + 16) and 248 of map beside it,
/// on a window at least 600 high. Split View, Slide Over, a split screen
/// and a free-form window under that keep the phone layout on any device.
const tabletMinWidth = 680.0;
const tabletMinHeight = 600.0;

/// The panel's and the search field's width, and the space around them.
const sidePanelWidth = 400.0;
const sidePanelGutter = 16.0;

/// The gap between the search field and the panel under it (T1: 72 to 84).
const sidePanelGap = 12.0;

/// Android's navigation rail (T1, T2 Android): the panel column starts
/// after it.
const tabletRailWidth = 80.0;

bool get _cupertino => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// The narrowest window with the tablet layout: Android's adds its rail, so
/// the map keeps the same share and the filters more than one pill.
double get tabletWindowMinWidth =>
    tabletMinWidth + (_cupertino ? 0 : tabletRailWidth);

/// Whether a display of [size] (logical pixels) is a tablet's.
bool isTabletDisplay(Size size) => size.shortestSide >= tabletMinShortSide;

/// Whether a window of [size] has room for the tablet layout.
bool isTabletWindow(Size size) =>
    size.width >= tabletWindowMinWidth && size.height >= tabletMinHeight;

/// Whether the app runs on a tablet. A display that cannot be read (an
/// embedder that reports none, a size of zero) leaves the window to decide.
bool isTabletDevice(BuildContext context) {
  try {
    final display = View.of(context).display;
    final size = display.size / display.devicePixelRatio;
    if (size.isEmpty || !size.isFinite) return true;
    return isTabletDisplay(size);
  } on Object {
    return true;
  }
}

/// Whether the app gets the tablet layout: on a tablet, in a window with
/// room for it. Read from the window, not the widget's own box, so every
/// part of a screen agrees.
bool isTabletLayout(BuildContext context) =>
    isTabletWindow(MediaQuery.sizeOf(context)) && isTabletDevice(context);

/// The map's search field at the current text size.
double mapSearchHeight(BuildContext context) =>
    32 + MediaQuery.textScalerOf(context).scale(20);

/// The search field's top edge, under the status bar.
double mapSearchTop(BuildContext context) =>
    MediaQuery.paddingOf(context).top + 4;

/// The side panel's top edge: under the search field.
double sidePanelTop(BuildContext context) =>
    mapSearchTop(context) + mapSearchHeight(context) + sidePanelGap;

/// Where the panel column starts, from the window's leading edge: after
/// the display's inset and Android's navigation rail.
double sidePanelWindowLeft(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).left +
    (_cupertino ? 0 : tabletRailWidth) +
    sidePanelGutter;

/// The panel's top corners: 26 on iPad, 28 on Android (T1, T2).
double get sidePanelRadius => _cupertino ? 26 : 28;

/// The tablet panel's surface (T1, T2): the sheet's own colour, rounded at
/// the top, running to the bottom of the window, with the boards' shadow.
/// The caller places it with [SidePanelSlot] or its own [Positioned].
class SidePanel extends StatelessWidget {
  const SidePanel({super.key, required this.child, this.semanticLabel});
  final Widget child;

  /// Names the panel for assistive technology (停車點詳情).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(top: Radius.circular(sidePanelRadius));
    return Semantics(
      container: true,
      label: semanticLabel,
      explicitChildNodes: true,
      child: DecoratedBox(
        key: const ValueKey('side-panel'),
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: const [
            BoxShadow(
              color: Color(0x3816313a),
              blurRadius: 12,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: child,
        ),
      ),
    );
  }
}

/// The panel's grabber (T1, T2): 36×5 on iPad, 32×4 on Android. It marks
/// the panel as the sheet it replaces; the panel itself does not move.
class SidePanelGrabber extends StatelessWidget {
  const SidePanelGrabber({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ExcludeSemantics(
      child: Center(
        child: Container(
          width: _cupertino ? 36 : 32,
          height: _cupertino ? 5 : 4,
          margin: const EdgeInsets.only(top: 8, bottom: 6),
          decoration: BoxDecoration(
            color: _cupertino ? colors.outlineVariant : colors.outline,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}

/// Places [child] in the tablet panel's column of a full-window stack:
/// [left] from the stack's leading edge (the gutter by default; a route on
/// the root navigator passes [sidePanelWindowLeft]), from under the search
/// field to the bottom.
class SidePanelSlot extends StatelessWidget {
  const SidePanelSlot({super.key, required this.child, this.left});
  final Widget child;
  final double? left;

  @override
  Widget build(BuildContext context) => Positioned(
    left: left ?? sidePanelGutter,
    top: sidePanelTop(context),
    bottom: 0,
    width: sidePanelWidth,
    child: child,
  );
}

/// A sheet shown in the tablet panel's place (A7c ⑦⑧, P16b ④⑤): the scrim
/// over the whole window, the panel rising from the bottom of its column.
/// Tapping the scrim or going back closes it.
class SidePanelRoute<T> extends PopupRoute<T> {
  SidePanelRoute({required this.builder, super.settings});
  final WidgetBuilder builder;

  /// The boards' scrim, rgba(22,49,58,.38).
  @override
  Color get barrierColor => const Color(0x6116313a);

  @override
  bool get barrierDismissible => true;

  @override
  String get barrierLabel => '關閉';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 250);

  /// Keeps what the rider chose when the panel changes shape.
  final _content = GlobalKey(debugLabel: 'side-panel-route-content');

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final content = KeyedSubtree(key: _content, child: builder(context));
    // The window's own insets hold inside the panel: the keyboard and the
    // home indicator.
    Widget surface(Widget child) => Semantics(
      // A route of its own for assistive technology, as a sheet is.
      scopesRoute: true,
      explicitChildNodes: true,
      child: SidePanel(
        child: MediaQuery.removePadding(
          context: context,
          removeTop: true,
          removeLeft: true,
          removeRight: true,
          child: child,
        ),
      ),
    );
    if (!isTabletLayout(context)) {
      // The window shrank under the open panel (Split View, a resized
      // window): it becomes the sheet a phone shows, across the bottom.
      return SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: double.infinity,
            child: surface(
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SidePanelGrabber(),
                  Flexible(child: SafeArea(top: false, child: content)),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        SidePanelSlot(
          left: sidePanelWindowLeft(context),
          child: surface(
            Column(
              children: [
                const SidePanelGrabber(),
                // As a bottom sheet does: the content ends above the
                // home indicator.
                Expanded(child: SafeArea(top: false, child: content)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    return SlideTransition(
      position: Tween(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    );
  }
}

/// The panel's width share of a map [mapWidth] wide whose leading
/// [covered] pixels the panel column hides: how far right of the map's
/// centre a point sits when centred in what stays visible.
double sidePanelCenterShift({
  required double mapWidth,
  required double covered,
}) => math.min(covered, mapWidth) / 2;

import 'package:flutter/services.dart';

import '../../ui/adaptive/adaptive.dart';
import '../../ui/version_text.dart';

/// Covers the app while [AppStore.start] runs. It continues the native splash
/// so launch reads as one screen.
class LaunchCurtain extends StatefulWidget {
  const LaunchCurtain({
    super.key,
    required this.visible,
    required this.locating,
    required this.child,
  });
  final bool visible, locating;
  final Widget child;

  @override
  State<LaunchCurtain> createState() => _LaunchCurtainState();
}

class _LaunchCurtainState extends State<LaunchCurtain> {
  /// Stays true through the fade-out, then drops the screen from the tree.
  late bool painted = widget.visible;

  @override
  void didUpdateWidget(LaunchCurtain old) {
    super.didUpdateWidget(old);
    if (widget.visible) painted = true;
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // The map has no app bar to set system bar icons, so the app restores
      // a theme-matched style once the launch screen is gone.
      AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: widget.child,
      ),
      if (painted)
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !widget.visible,
            child: AnimatedOpacity(
              opacity: widget.visible ? 1 : 0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 450),
              curve: Curves.easeOutCubic,
              onEnd: () {
                if (!widget.visible) setState(() => painted = false);
              },
              child: LaunchScreen(locating: widget.locating),
            ),
          ),
        ),
    ],
  );
}

/// Native splash colors (flutter_native_splash.yaml): parking-sign blue in
/// light mode, asphalt in dark mode; the same icon on both.
const launchBlue = Color(0xff1f5fa8);
const launchAsphalt = Color(0xff1c2126);

/// Loading screen that continues the native splash: same background, same
/// mark at the same size and position, with the app name under the mark and
/// the loading status at the bottom.
class LaunchScreen extends StatelessWidget {
  const LaunchScreen({super.key, required this.locating});
  final bool locating;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final quiet = text.labelSmall?.copyWith(
      color: Colors.white.withValues(alpha: .85),
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Material(
        key: const ValueKey('launch-screen'),
        color: dark ? launchAsphalt : launchBlue,
        // The title is laid out below the screen when it has no room, so the
        // clip keeps it from painting over the edge.
        child: ClipRect(
          child: CustomMultiChildLayout(
            delegate: _LaunchLayout(),
            children: [
              LayoutId(
                id: _LaunchSlot.mark,
                child: Image.asset(
                  'assets/branding/png/splash_mark.png',
                  key: const ValueKey('launch-mark'),
                  excludeFromSemantics: true,
                  filterQuality: FilterQuality.medium,
                ),
              ),
              LayoutId(
                id: _LaunchSlot.title,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '機車停車指南',
                        key: const ValueKey('launch-title'),
                        textAlign: TextAlign.center,
                        style: text.headlineMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '普通機車・大型重機',
                        key: const ValueKey('launch-subtitle'),
                        textAlign: TextAlign.center,
                        style: text.titleSmall?.copyWith(
                          color: Colors.white.withValues(alpha: .78),
                          letterSpacing: 4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              LayoutId(
                id: _LaunchSlot.status,
                child: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          locating ? '正在取得目前位置…' : '正在載入停車資料…',
                          key: const ValueKey('launch-status'),
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(color: Colors.white),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        '停車前請確認現場標示',
                        textAlign: TextAlign.center,
                        style: quiet,
                      ),
                      const SizedBox(height: 4),
                      VersionText(style: quiet),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _LaunchSlot { mark, title, status }

/// Centers the mark on the whole screen like the native splash: a 288 logical
/// px image with the 150 px rounded icon in its middle, and the app name
/// under the icon. On short screens the mark shrinks so the icon never runs
/// into the title or the status text; when even a [minIconSide] icon leaves
/// the title no room, the title moves below the screen and the icon keeps
/// what is left.
class _LaunchLayout extends MultiChildLayoutDelegate {
  static const nativeSize = 288.0;

  /// The icon's share of the image side.
  static const iconShare = 150 / nativeSize;

  /// Space between the icon's bottom edge and the title.
  static const titleGap = 20.0;

  /// Smallest icon worth keeping the title for.
  static const minIconSide = 40.0;

  @override
  void performLayout(Size size) {
    final status = layoutChild(_LaunchSlot.status, BoxConstraints.loose(size));
    positionChild(
      _LaunchSlot.status,
      Offset((size.width - status.width) / 2, size.height - status.height),
    );
    final title = layoutChild(_LaunchSlot.title, BoxConstraints.loose(size));
    // Below the screen center: the icon's lower half, then the title.
    final below = size.height / 2 - status.height - 8;
    final iconHalfWithTitle = below - titleGap - title.height;
    final showTitle = iconHalfWithTitle >= minIconSide / 2;
    final room = 2 * (showTitle ? iconHalfWithTitle : below) / iconShare;
    final side = room.clamp(0.0, nativeSize).clamp(0.0, size.width);
    layoutChild(_LaunchSlot.mark, BoxConstraints.tight(Size.square(side)));
    positionChild(
      _LaunchSlot.mark,
      Offset((size.width - side) / 2, (size.height - side) / 2),
    );
    positionChild(
      _LaunchSlot.title,
      showTitle
          ? Offset(
              (size.width - title.width) / 2,
              (size.height + side * iconShare) / 2 + titleGap,
            )
          : Offset((size.width - title.width) / 2, size.height),
    );
  }

  @override
  bool shouldRelayout(_LaunchLayout oldDelegate) => false;
}

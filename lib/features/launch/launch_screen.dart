import 'package:flutter/services.dart';

import '../../ui/adaptive/adaptive.dart';

/// Covers the app while [AppStore.start] runs. Its brand background matches
/// the native splash so launch reads as one continuous screen.
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
      // a theme-matched style once the brand-colored screen is gone.
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

class LaunchScreen extends StatelessWidget {
  const LaunchScreen({super.key, required this.locating});
  final bool locating;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Material(
        key: const ValueKey('launch-screen'),
        color: brand,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -.35),
              radius: 1.1,
              colors: [Color(0xff21798c), brand, Color(0xff0f4652)],
              stops: [0, .55, 1],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 5),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: reduceMotion ? 1 : 0, end: 1),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.easeOutBack,
                  builder: (context, t, child) => Opacity(
                    opacity: t.clamp(0, 1),
                    child: Transform.scale(scale: .85 + .15 * t, child: child),
                  ),
                  child: const _Mark(),
                ),
                const SizedBox(height: 28),
                Text(
                  '機車停車指南',
                  style: text.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '普通機車・大型重機',
                  style: text.titleSmall?.copyWith(
                    color: Colors.white.withValues(alpha: .78),
                    letterSpacing: 4,
                  ),
                ),
                const Spacer(flex: 4),
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
                    style: text.bodyMedium?.copyWith(
                      color: Colors.white.withValues(alpha: .88),
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                Text(
                  '停車前請確認現場標示',
                  style: text.labelSmall?.copyWith(
                    color: Colors.white.withValues(alpha: .6),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Parking sign: a "P" over a motorcycle, drawn so no image asset is needed.
class _Mark extends StatelessWidget {
  const _Mark();

  @override
  Widget build(BuildContext context) => Container(
    width: 112,
    height: 112,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(32),
      boxShadow: const [
        BoxShadow(
          color: Color(0x40000000),
          blurRadius: 24,
          offset: Offset(0, 10),
        ),
      ],
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'P',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontFamily: 'Outfit',
            fontSize: 56,
            height: 1,
            fontWeight: FontWeight.w800,
            color: brand,
          ),
        ),
        SizedBox(height: 2),
        Icon(Icons.two_wheeler, size: 30, color: brand),
      ],
    ),
  );
}

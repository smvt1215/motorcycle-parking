import 'package:material_ui/material_ui.dart';

/// Below this width the admin site is one column with a bottom navigation
/// bar; from here to [adminWideWidth] it is two columns under a one-row top
/// bar (C6 畫布 Main／Tablet).
const adminCompactWidth = 680.0;

/// From this width the shell keeps its desktop top bar.
const adminWideWidth = 1040.0;

/// A viewport shorter than this (an on-screen keyboard, an iPad held
/// landscape with the keyboard up) is "short": notices fold away, action
/// bars scroll with the content and the spot form's small map becomes a
/// button (C6 畫布 KeyboardForm，便條 s1、s3).
const adminShortHeight = 500.0;

/// Whether the visible viewport is short; read once above the scaffolds,
/// which hide the keyboard inset from what they build.
class AdminLayout extends InheritedWidget {
  const AdminLayout({super.key, required this.short, required super.child});

  final bool short;

  /// False outside the admin app (widget tests of a single page).
  static bool shortOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminLayout>()?.short ?? false;

  @override
  bool updateShouldNotify(AdminLayout old) => old.short != short;
}

/// Measures the viewport for [AdminLayout] and keeps the focused field in
/// view when the viewport shrinks. A mobile browser's keyboard often
/// resizes the page instead of reporting an inset, and Flutter only scrolls
/// to the caret for an inset (G3、G4).
class AdminViewport extends StatefulWidget {
  const AdminViewport({super.key, required this.child});
  final Widget child;

  @override
  State<AdminViewport> createState() => _AdminViewportState();
}

class _AdminViewportState extends State<AdminViewport>
    with WidgetsBindingObserver {
  /// The visible viewport as last built.
  Size? _visible;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // Only a field the admin is looking at follows the keyboard: one they
    // scrolled away from stays where it is. Measured now, on the old layout.
    final before = _visible;
    final focused = FocusManager.instance.primaryFocus?.context;
    final seen =
        before != null &&
        focused != null &&
        focused.mounted &&
        _onScreen(focused.findRenderObject(), before);
    // The new size is laid out in the next frame; scroll after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !seen) return;
      final now = _visible;
      if (now != null && now.height < before.height) revealFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final visible = Size(
      media.size.width,
      media.size.height - media.viewInsets.bottom,
    );
    _visible = visible;
    return AdminLayout(
      short: visible.height < adminShortHeight,
      child: widget.child,
    );
  }
}

/// Whether [box] is painted and at least partly inside [screen].
bool _onScreen(RenderObject? box, Size screen) {
  if (box is! RenderBox || !box.attached || !box.hasSize) return false;
  // A list keeps a focused field alive after it scrolls away, unpainted.
  RenderObject child = box;
  for (var parent = box.parent; parent != null; parent = parent.parent) {
    if (!parent.paintsChild(child)) return false;
    child = parent;
  }
  final rect = box.localToGlobal(Offset.zero) & box.size;
  return rect.overlaps(Offset.zero & screen);
}

/// Scrolls the focused widget into view, if it sits in a scrollable.
void revealFocus() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null || !focused.mounted) return;
  focused.findRenderObject()?.showOnScreen(
    duration: const Duration(milliseconds: 150),
    curve: Curves.easeOut,
  );
}

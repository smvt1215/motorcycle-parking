import 'package:go_router/go_router.dart';

import 'adaptive/adaptive.dart';

/// Tab panels sit over the map; modal details use the root navigator above them.
/// Dragging a panel to the bottom closes it and returns to the map tab.
class MapPanel extends StatefulWidget {
  const MapPanel({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  State<MapPanel> createState() => _MapPanelState();
}

class _MapPanelState extends State<MapPanel> {
  final extent = DraggableScrollableController();
  bool closing = false;

  @override
  void initState() {
    super.initState();
    extent.addListener(_closeAtBottom);
  }

  void _closeAtBottom() {
    if (closing || extent.size > .01) return;
    closing = true;
    context.go('/map');
    // The tab stays mounted offstage; restore its size for the next visit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      closing = false;
      if (mounted && extent.isAttached) extent.reset();
    });
  }

  @override
  void dispose() {
    extent.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title = widget.title, trailing = widget.trailing;
    return SafeArea(
      bottom: false,
      child: DraggableScrollableSheet(
        controller: extent,
        initialChildSize: .9,
        minChildSize: 0,
        maxChildSize: 1,
        snap: true,
        shouldCloseOnMinExtent: false,
        snapSizes: const [.55, .9, 1],
        builder: (context, scroll) => Material(
          color: colors.surface,
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 120),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 28),
              ...widget.children,
            ],
          ),
        ),
      ),
    );
  }
}

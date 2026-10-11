import 'adaptive/adaptive.dart';

/// Tab panels sit over the map; modal details use the root navigator above them.
class MapPanel extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: DraggableScrollableSheet(
        initialChildSize: .9,
        minChildSize: .55,
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
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

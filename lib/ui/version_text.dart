import '../core/app_version.dart';
import 'adaptive/adaptive.dart';

/// The installed version and build, e.g. `v0.2.0 · Build 1234 · Beta`.
/// Empty until the platform answers, so it never shifts the layout.
class VersionText extends StatelessWidget {
  const VersionText({super.key, this.style, this.selectable = false});
  final TextStyle? style;

  /// Selectable where testers copy it into feedback.
  final bool selectable;

  @override
  Widget build(BuildContext context) => FutureBuilder<AppVersion>(
    future: AppVersion.current,
    builder: (context, snapshot) {
      final label = snapshot.data?.label ?? '';
      return selectable
          ? SelectableText(
              label,
              key: const ValueKey('app-version'),
              style: style,
              textAlign: TextAlign.center,
            )
          : Text(
              label,
              key: const ValueKey('app-version'),
              style: style,
              textAlign: TextAlign.center,
            );
    },
  );
}

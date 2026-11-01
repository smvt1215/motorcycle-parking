import '../../domain/availability_beta_display.dart';
import '../../ui/adaptive/adaptive.dart';

/// The Beta tag (A13 Beta 標籤): sea-blue outline, no fill, Outfit 11/600.
/// Sea blue is the brand's, kept for the app's own notes, so it never reads
/// as an eligibility colour or a count. On a selected (dark) chip the
/// outline and text turn white ([color]).
class BetaTag extends StatelessWidget {
  const BetaTag({super.key, this.color});

  /// Outline and text; the brand sea blue by default, the theme's primary
  /// on a dark surface.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final ink =
        color ??
        (colors.brightness == Brightness.dark ? colors.primary : brand);
    return Container(
      key: const ValueKey('beta-tag'),
      // Sized to the word: no alignment, which would stretch it to fill.
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: ink, width: 1.25),
      ),
      child: Text(
        betaTagLabel,
        style: TextStyle(
          fontFamily: 'Outfit',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          height: 1.15,
          color: ink,
        ),
      ),
    );
  }
}

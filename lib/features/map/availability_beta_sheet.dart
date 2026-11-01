import '../../domain/availability_beta_display.dart';
import '../../domain/availability_display.dart';
import '../../domain/eligibility.dart';
import '../../ui/adaptive/adaptive.dart';
import 'availability_capsule.dart';
import 'beta_tag.dart';
import 'map_legend.dart';

/// How the rider left the Beta sheet.
enum BetaIntroChoice {
  /// 知道了: never shown again.
  done,

  /// 看「地圖怎麼看」: the legend opens next.
  legend,
}

/// The first-time 即時車位 Beta sheet (A13): slides up once the map first
/// shows a count in [city], a Beta city. [provider] names who counts
/// (「臺北市停管處」). Null when dismissed without choosing.
Future<BetaIntroChoice?> showAvailabilityBetaIntro(
  BuildContext context, {
  required String city,
  required String provider,
}) => showAdaptiveSheet<BetaIntroChoice>(
  context,
  (ctx) => AvailabilityBetaIntro(city: city, provider: provider),
);

/// The sheet's content: a title with the Beta tag, three rows (the count,
/// that it may differ, that the marker still decides) and two actions.
class AvailabilityBetaIntro extends StatelessWidget {
  const AvailabilityBetaIntro({
    super.key,
    required this.city,
    required this.provider,
  });
  final String city, provider;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final body = text.bodyLarge?.copyWith(height: 1.5);
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('availability-beta-intro'),
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Center(
          child: ConstrainedBox(
            // A tablet keeps a phone-width column.
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        betaIntroTitle(city),
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const BetaTag(),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                for (final (visual, line) in <(Widget, String)>[
                  (
                    const AvailabilityCapsuleView(
                      capsule: AvailabilityCapsule(
                        text: '剩 4',
                        style: CapsuleStyle.live,
                        semantics: '',
                      ),
                    ),
                    betaIntroSource(provider),
                  ),
                  (
                    Icon(
                      Icons.schedule,
                      size: 24,
                      color: colors.onSurfaceVariant,
                    ),
                    betaIntroCaution,
                  ),
                  (
                    const SpotMarker(
                      look: (EligibilityStatus.allowed, null),
                      size: 24,
                    ),
                    betaIntroEligibility,
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 56,
                          height: 26,
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: ExcludeSemantics(child: visual),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(child: Text(line, style: body)),
                      ],
                    ),
                  ),
                const SizedBox(height: 4),
                AdaptiveButton(
                  key: const ValueKey('beta-intro-done'),
                  label: betaIntroDone,
                  onPressed: () => Navigator.pop(context, BetaIntroChoice.done),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(minHeight: isCupertino ? 44 : 48),
                  child: TextButton(
                    key: const ValueKey('beta-intro-legend'),
                    onPressed: () =>
                        Navigator.pop(context, BetaIntroChoice.legend),
                    child: const Text(betaIntroLegend),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

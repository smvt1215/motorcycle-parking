import '../../domain/availability_beta_display.dart';
import '../../domain/availability_display.dart';
import '../../ui/adaptive/adaptive.dart';
import 'beta_tag.dart';

/// 有沒有位 in the details (A14): a large count (30/600) beside 「剩餘」, the
/// capacity and whose bays (「／ 共 24 格（大型重機）」), the time and the
/// source, or the reason there is none. Ink only, never a status colour,
/// so it never competes with the eligibility banner. A count in a Beta
/// city ends with a Beta line. Its own widget so PR-D's full-page details
/// can move it whole.
class SpotSeatSection extends StatelessWidget {
  const SpotSeatSection({super.key, required this.fact, this.betaCities});
  final AvailabilityFact fact;

  /// The Beta cities, when the spot is in one; null otherwise.
  final List<String>? betaCities;

  @override
  Widget build(BuildContext context) {
    final beta = fact.count == null ? null : betaCities;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final muted = text.labelSmall?.copyWith(color: colors.onSurfaceVariant);
    const figures = [FontFeature.tabularFigures()];
    return Semantics(
      key: const ValueKey('availability-summary'),
      label: [
        fact.semantics,
        if (beta != null) '$betaTagLabel，${betaDetailNote(beta)}',
      ].join('，'),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(fact.title, style: muted),
          const SizedBox(height: 4),
          if (fact.count case final count?)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$count',
                    style: text.headlineMedium?.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      fontFeatures: figures,
                    ),
                  ),
                  TextSpan(
                    text: ' ${fact.headline}',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (fact.capacity case final capacity?)
                    TextSpan(
                      text: ' $capacity',
                      style: text.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontFeatures: figures,
                      ),
                    ),
                ],
              ),
              key: const ValueKey('availability-count'),
            )
          else
            Text(
              fact.headline,
              key: const ValueKey('availability-headline'),
              style: text.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                height: 1.4,
              ),
            ),
          if (fact.caption.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(fact.caption, style: muted),
          ],
          for (final note in fact.notes) ...[
            const SizedBox(height: 10),
            Text(
              note.text,
              style: text.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                fontFeatures: figures,
              ),
            ),
            const SizedBox(height: 2),
            Text(note.caption, style: muted),
          ],
          if (beta != null) ...[
            const SizedBox(height: 10),
            Row(
              key: const ValueKey('availability-beta-note'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: BetaTag(),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    betaDetailNote(beta),
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/semantics.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/policy_links.dart';
import '../../domain/lookup_consent_display.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/location_picker.dart';

double get _target => isCupertino ? 44 : 48;

/// The quiet text buttons of the lookup rows: the platform's touch target,
/// the app's link colour.
ButtonStyle _linkStyle(BuildContext context) => TextButton.styleFrom(
  foregroundColor: Theme.of(context).colorScheme.primary,
  minimumSize: Size.square(_target),
  padding: const EdgeInsets.symmetric(horizontal: 8),
  shape: const StadiumBorder(),
  tapTargetSize: MaterialTapTargetSize.padded,
  textStyle: Theme.of(context).textTheme.labelLarge
      ?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
);

/// How wide [label] is drawn as a [_linkStyle] or choice button's text.
double _labelWidth(BuildContext context, String label, double fontSize) {
  final painter = TextPainter(
    text: TextSpan(
      text: label,
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontSize: fontSize, fontWeight: FontWeight.w600),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Icons beside text grow with it, up to a size that still fits a phone.
double _iconSize(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(20).clamp(20, 32).toDouble();

/// The explanation under the map of a picker form, before anything is
/// looked up (N1c, #462). It never blocks the form: the county and
/// district below can be picked by hand without answering.
///
/// The two answers are the same size and style, side by side, stacked
/// with 不同意 first when either would not fit on one line.
class LookupConsentCard extends StatelessWidget {
  const LookupConsentCard({
    super.key,
    required this.doorAvailable,
    required this.signedIn,
    required this.onDecline,
    required this.onAgree,
  });

  /// Whether this build may show an approximate door at all; without a
  /// Google map the card leaves the door out.
  final bool doorAvailable;

  /// Signed out, only the county and district are looked up for now; the
  /// card says what signing in adds, as one answer covers both.
  final bool signedIn;
  final VoidCallback onDecline, onAgree;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final door = doorAvailable && signedIn;
    final body = TextStyle(
      fontSize: 14,
      height: 1.55,
      color: colors.onSurfaceVariant,
    );
    final policy = policyUri(policyUrls.privacy);
    return Semantics(
      key: const ValueKey('lookup-consent-card'),
      container: true,
      explicitChildNodes: true,
      label: lookupCardLabel,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineVariant, width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(14, 14, 14, policy == null ? 14 : 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  lookupCardTitle(door: door),
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.35,
                    fontWeight: FontWeight.w700,
                    color: colors.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(lookupCardLead, style: body),
              const SizedBox(height: 10),
              _Sent(
                icon: Icons.account_balance_outlined,
                name: lookupTownName,
                detail: lookupTownDetail,
                style: body,
              ),
              if (doorAvailable) ...[
                const SizedBox(height: 8),
                _Sent(
                  key: const ValueKey('lookup-consent-door'),
                  icon: Icons.signpost_outlined,
                  name: lookupDoorName,
                  detail: signedIn
                      ? lookupDoorDetail
                      : lookupDoorSignedOutDetail,
                  style: body,
                  // Not looked up for now.
                  quiet: !signedIn,
                ),
              ],
              const SizedBox(height: 8),
              _Sent(
                icon: Icons.my_location,
                detail: lookupMyLocationDetail,
                style: body,
              ),
              const SizedBox(height: 10),
              Text(
                lookupDeclineNote(door: door),
                style: body.copyWith(fontSize: 13),
              ),
              const SizedBox(height: 10),
              Semantics(
                container: true,
                explicitChildNodes: true,
                label: lookupChoiceLabel,
                child: _Choices(onDecline: onDecline, onAgree: onAgree),
              ),
              if (policy != null) ...[
                const SizedBox(height: 4),
                Center(
                  child: TextButton(
                    key: const ValueKey('lookup-consent-policy'),
                    style: _linkStyle(context),
                    // The in-app browser, as the policy rows of 帳號與設定:
                    // closing it returns to the form as it was.
                    onPressed: () => runAction(context, () async {
                      if (!await launchUrl(
                        policy,
                        mode: LaunchMode.inAppBrowserView,
                      )) {
                        throw StateError('無法開啟隱私權政策');
                      }
                    }),
                    child: const Text(
                      lookupPolicyLink,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One thing the lookups send, and to whom.
class _Sent extends StatelessWidget {
  const _Sent({
    super.key,
    required this.icon,
    required this.detail,
    required this.style,
    this.name,
    this.quiet = false,
  });
  final IconData icon;
  final String? name;
  final String detail;
  final TextStyle style;
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(
            icon,
            size: _iconSize(context),
            color: quiet ? colors.onSurfaceVariant : colors.primary,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              children: [
                if (name != null)
                  TextSpan(
                    text: '$name　',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                TextSpan(text: detail),
              ],
            ),
            style: style,
          ),
        ),
      ],
    );
  }
}

/// 不同意，自己選 and 同意，自動查詢: equal in size and style, neither one
/// preselected or emphasised.
class _Choices extends StatelessWidget {
  const _Choices({required this.onDecline, required this.onAgree});
  final VoidCallback onDecline, onAgree;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final style = OutlinedButton.styleFrom(
      foregroundColor: colors.primary,
      side: BorderSide(color: colors.primary, width: 1.5),
      shape: const StadiumBorder(),
      minimumSize: Size(0, isCupertino ? 50 : 48),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      tapTargetSize: MaterialTapTargetSize.padded,
      textStyle: theme.textTheme.labelLarge?.copyWith(
        fontSize: 15,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
    );
    final decline = OutlinedButton(
      key: const ValueKey('lookup-consent-decline'),
      style: style,
      onPressed: onDecline,
      child: const Text(lookupDecline, textAlign: TextAlign.center),
    );
    final agree = OutlinedButton(
      key: const ValueKey('lookup-consent-agree'),
      style: style,
      onPressed: onAgree,
      child: const Text(lookupAgree, textAlign: TextAlign.center),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final widest = [
          lookupDecline,
          lookupAgree,
        ].map((label) => _labelWidth(context, label, 15)).reduce(_max);
        // Each label on one line inside its padding and outline.
        final stacked = (box.maxWidth - 8) / 2 < widest + 24;
        return stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [decline, const SizedBox(height: 8), agree],
              )
            : Row(
                children: [
                  Expanded(child: decline),
                  const SizedBox(width: 8),
                  Expanded(child: agree),
                ],
              );
      },
    );
  }
}

double _max(double a, double b) => a > b ? a : b;

/// Says 已關閉自動查詢 once 關閉自動查詢 took effect. A form sheet covers the
/// page's messages, so it is spoken too; what shows is the row under the
/// county turning into [LookupOffRow].
void showLookupTurnedOff(BuildContext context) {
  showMessage(context, lookupTurnedOff);
  unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      lookupTurnedOff,
      Directionality.of(context),
    ),
  );
}

/// Under the county and district while the lookups are off and the marker
/// moved since they were picked or looked up (Q462-1 C): they are kept, and
/// may belong to the old position. Spoken when it appears.
class TownMovedNote extends StatelessWidget {
  const TownMovedNote({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: const LocationNote(
      key: ValueKey('lookup-moved'),
      icon: Icons.edit_location_outlined,
      text: lookupMovedNote,
      tone: NoteTone.caution,
    ),
  );
}

/// Under the county and district while the lookups are on (N1d ①②): the
/// usual hint, with 關閉自動查詢 at its right, or on the next line when
/// the two do not fit.
class LookupAutoRow extends StatelessWidget {
  const LookupAutoRow({super.key, required this.onTurnOff});
  final VoidCallback onTurnOff;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 8,
    children: [
      Text(
        lookupAutoHint,
        style: TextStyle(
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      TextButton(
        key: const ValueKey('lookup-turn-off'),
        style: _linkStyle(context),
        onPressed: onTurnOff,
        child: const Text(lookupTurnOff),
      ),
    ],
  );
}

/// Under the county and district once declined (N1d ③): the rider picks
/// them, and 開啟自動查詢 brings the explanation back.
class LookupOffRow extends StatelessWidget {
  const LookupOffRow({super.key, required this.onTurnOn});
  final VoidCallback onTurnOn;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final note = Row(
      children: [
        Icon(
          Icons.location_off_outlined,
          size: _iconSize(context),
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(
              lookupOffNote,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
    final button = TextButton(
      key: const ValueKey('lookup-turn-on'),
      style: _linkStyle(context),
      onPressed: onTurnOn,
      child: const Text(lookupTurnOn),
    );
    return Semantics(
      key: const ValueKey('lookup-off'),
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: LayoutBuilder(
            builder: (context, box) {
              final buttonWidth = _labelWidth(context, lookupTurnOn, 14) + 16;
              // The sentence keeps 150 px beside its icon; otherwise the
              // button goes under it.
              final beside =
                  box.maxWidth - buttonWidth - 8 - _iconSize(context) - 8 >=
                  150;
              return beside
                  ? Row(
                      children: [
                        Expanded(child: note),
                        const SizedBox(width: 8),
                        button,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [note, button],
                    );
            },
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import '../../data/account_suspended.dart';
import '../../data/app_store.dart';
import '../../data/sightings_repository.dart';
import '../../domain/four_sign.dart';
import '../../domain/rider_meter_display.dart';
import '../../domain/sighting_display.dart';
import '../../domain/spot_detail_display.dart' show detailPlaceName;
import '../../models/parking.dart';
import '../../models/sighting.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/detail_tokens.dart';
import '../account/suspended_sheet.dart';
import '../report/report_sheet.dart' show SignInPrompt;

/// Opens 回報現場狀況 for [spot] (A7, A7b), judged by [sign]; says so once it
/// went through. The caller checks [sightingPlaces] first.
Future<void> showSightingSheet(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
  FourSign sign,
) async {
  final sent = await showAdaptiveSheet<bool>(
    context,
    (_) => SightingSheet(
      store: store,
      spot: spot,
      places: sightingPlaces(sign) ?? const [],
    ),
  );
  if (sent == true && context.mounted) showMessage(context, sightingSent);
}

/// One choice of the scale: a level, or nobody can park ([level] null).
typedef _Choice = ({RiderLevel? level});

/// 回報現場狀況 (A7 a segment, A7b a zone): the place, then the state, then
/// 送出回報, off until both are chosen. A closed spot has no place to choose
/// (the backend records it for the whole spot). A failure keeps what was
/// chosen.
class SightingSheet extends StatefulWidget {
  const SightingSheet({
    super.key,
    required this.store,
    required this.spot,
    required this.places,
  });
  final AppStore store;
  final ParkingSpot spot;

  /// The places open now; empty for a spot standing as one.
  final List<SignArea> places;

  @override
  State<SightingSheet> createState() => _SightingSheetState();
}

class _SightingSheetState extends State<SightingSheet> {
  /// Several places: the rider says which, so a default never lands a
  /// report on the wrong one.
  late SignArea? place = widget.places.length == 1
      ? widget.places.single
      : null;
  _Choice? choice;
  bool sending = false;
  String? error;

  bool get street => !widget.spot.isFacility;
  bool get whole => widget.places.isEmpty;
  bool get closed => choice != null && choice!.level == null;

  bool get ready =>
      choice != null &&
      (closed || whole || place != null) &&
      !sending &&
      widget.store.canReport;

  SightingReport get report {
    final spot = widget.spot, vehicle = widget.store.vehicle;
    if (closed) return SightingReport.closed(spotId: spot.id, vehicle: vehicle);
    return SightingReport.level(
      spotId: spot.id,
      vehicle: vehicle,
      level: choice!.level!.bars,
      zoneId: street ? null : place?.id,
      segmentId: street ? place?.id : null,
    );
  }

  Future<void> submit() async {
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.store.submitSighting(report);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (accountSuspendedFrom(e) case final s?) {
        if (mounted) {
          await showSuspendedSheet(context, s.until, untilKnown: s.untilKnown);
        }
        return;
      }
      if (mounted) {
        setState(
          () => error = e is SightingRefused
              ? sightingRefusalText(e.reason, street: street, whole: whole)
              : sightingFailed,
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final c = DetailColors.of(context);
    final hint = TextStyle(fontSize: 14, color: c.ink);
    return Column(
      key: const ValueKey('sighting-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!widget.store.canReport) ...[
                  SignInPrompt(store: widget.store, message: sightingSignIn),
                  const SizedBox(height: 12),
                ],
                if (!whole) ...[
                  Text.rich(
                    TextSpan(
                      text: sightingPlaceQuestion(street: street),
                      children: [
                        TextSpan(
                          text: '　${sightingPlaceHint(street: street)}',
                          style: TextStyle(color: c.muted),
                        ),
                      ],
                    ),
                    style: hint,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (i, a) in widget.places.indexed)
                        _PlaceChip(
                          key: ValueKey('sighting-place-$i'),
                          label: detailPlaceName(a),
                          selected: identical(a, place),
                          onTap: sending
                              ? null
                              : () => setState(() => place = a),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                Text(sightingLevelQuestion, style: hint),
                const SizedBox(height: 8),
                for (final level in RiderLevel.values.reversed) ...[
                  _Option(
                    key: ValueKey('sighting-level-${level.name}'),
                    label: level.label,
                    leading: _Bars(filled: level.bars),
                    selected: choice?.level == level,
                    onTap: sending
                        ? null
                        : () => setState(() => choice = (level: level)),
                  ),
                  const SizedBox(height: 8),
                ],
                _Option(
                  key: const ValueKey('sighting-closed'),
                  label: sightingClosedLabel,
                  note: sightingClosedNote(street: street),
                  leading: Icon(
                    Icons.construction,
                    size: 24,
                    color: c.conditional,
                  ),
                  selected: closed,
                  onTap: sending
                      ? null
                      : () => setState(() => choice = (level: null)),
                ),
                const SizedBox(height: 12),
                Text(
                  sightingNote(street: street, whole: whole),
                  style: TextStyle(fontSize: 12, color: c.muted, height: 1.5),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error case final message?) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    key: const ValueKey('sighting-error'),
                    style: TextStyle(fontSize: 14, color: c.denied),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              AdaptiveButton(
                key: const ValueKey('sighting-submit'),
                label: sending ? sightingSending : sightingSubmit,
                onPressed: ready ? submit : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// iOS 取消 and a centred title; Android a close icon and the title left
  /// (FIX-DECISIONS).
  Widget _header(BuildContext context) {
    final c = DetailColors.of(context);
    void cancel() => Navigator.pop(context);
    if (isCupertino) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 60, minHeight: 44),
              child: TextButton(
                key: const ValueKey('sighting-cancel'),
                onPressed: cancel,
                child: const Text(sightingCancel),
              ),
            ),
            Expanded(
              child: Text(
                sightingTitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: c.ink,
                ),
              ),
            ),
            const SizedBox(width: 60),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 16),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('sighting-cancel'),
            tooltip: '關閉',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: cancel,
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              sightingTitle,
              style: TextStyle(fontSize: 22, color: c.ink),
            ),
          ),
        ],
      ),
    );
  }
}

/// A place: pill, ink when chosen.
class _PlaceChip extends StatelessWidget {
  const _PlaceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    final height = isCupertino ? 44.0 : 48.0;
    final surface = Theme.of(context).colorScheme.surface;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? c.ink : Colors.transparent,
        shape: StadiumBorder(
          side: selected ? BorderSide.none : BorderSide(color: c.muted),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: height),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    Icon(Icons.check, size: 18, color: surface),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected ? surface : c.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One of the five states: chosen, a 2px outline, a light ground and a tick.
class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.label,
    required this.leading,
    required this.selected,
    required this.onTap,
    this.note,
  });
  final String label;
  final String? note;
  final Widget leading;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: [label, ?note].join('，'),
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? c.chip : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? c.link : c.border,
            width: selected ? 2 : 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                children: [
                  SizedBox(width: 34, child: Center(child: leading)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: c.ink,
                          ),
                        ),
                        if (note case final text?)
                          Text(
                            text,
                            style: TextStyle(fontSize: 12, color: c.muted),
                          ),
                      ],
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check_circle, size: 24, color: c.link),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The options' meter (A7): larger than the plates'.
class _Bars extends StatelessWidget {
  const _Bars({required this.filled});
  final int filled;

  @override
  Widget build(BuildContext context) {
    final c = DetailColors.of(context);
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final (i, h) in const [6.0, 12.0, 18.0].indexed) ...[
            if (i > 0) const SizedBox(width: 3),
            Container(
              width: 9,
              height: h,
              decoration: BoxDecoration(
                color: i < filled ? c.ink : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: c.ink, width: 1.5),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

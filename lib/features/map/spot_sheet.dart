import 'dart:async';
import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../models/availability.dart';
import '../../models/parking.dart';
import '../../models/spot_history.dart';
import '../../domain/availability_beta_display.dart';
import '../../domain/availability_display.dart';
import '../../domain/eligibility.dart';
import '../../domain/eligibility_display.dart';
import '../../domain/four_sign.dart';
import '../../domain/four_sign_display.dart';
import '../../domain/hidden_riders_display.dart' show contentHeldNote;
import '../../domain/parking_decision.dart';
import '../../domain/sighting_display.dart';
import '../../domain/spot_detail_display.dart';
import '../../models/sighting.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/detail_tokens.dart';
import '../../ui/four_sign_plates.dart';

import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderProxyBox;

import '../auth/sign_in.dart';
import '../hidden_riders/spot_more_menu.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:share_plus/share_plus.dart';

import '../report/spot_suggestions.dart';
import '../sighting/sighting_sheet.dart';
import 'closure_card.dart';
import 'spot_details.dart';
import 'spot_fees.dart';
import 'spot_photos.dart';
import 'spot_preview.dart';
import 'spot_detail.dart';
import 'spot_seat_section.dart';

/// Peek height: the preview (name, the four signs and the actions), with
/// the map left visible above, the way map apps open a place.
/// The sheet's resting height, as a fraction of the space it opens in: at
/// least this much, more when the plates need it (A15).
const spotSheetPeek = .42;

/// The tallest the resting preview grows: past it the plates scroll inside
/// the card (A15b ③).
const spotSheetPeekMax = .62;

/// The space below the plates, and above the handle, in the preview.
const _previewMargins = 10.0 + 8.0;

/// A size-reporting wrapper: tells [onHeight] its child's height after
/// layout.
class _MeasuredHeight extends SingleChildRenderObjectWidget {
  const _MeasuredHeight({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasuredHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMeasuredHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderMeasuredHeight extends RenderProxyBox {
  _RenderMeasuredHeight(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(height));
  }
}

/// Opens a spot's details over another page. The map embeds [SpotSheet]
/// instead, so it stays movable and other spots stay tappable.
Future<void> showSpot(BuildContext context, AppStore store, ParkingSpot spot) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => SpotSheet(store: store, spot: spot),
      detail: true,
    );

class SpotSheet extends StatefulWidget {
  const SpotSheet({
    super.key,
    required this.store,
    required this.spot,
    this.onClose,
    this.sourceActions,
    this.onPeek,
    this.panel = false,
  });
  final AppStore store;
  final ParkingSpot spot;

  /// Closes an embedded sheet; a modal sheet pops its route by default.
  final VoidCallback? onClose;

  /// Actions on the spot's source, at the foot of 資料與查核 (where #280's
  /// ⋯ menu goes); null shows none.
  final Widget? sourceActions;

  /// The resting preview's height as a share of the sheet's space (A15),
  /// whenever it changes.
  final ValueChanged<double>? onPeek;

  /// The tablet's side panel (T1, T2) in place of the sheet: the name and
  /// the plates stay at the top, the details scroll under them and the
  /// actions hold the foot. It has no resting height, so it never calls
  /// [onPeek]; whoever shows it places it.
  final bool panel;
  @override
  State<SpotSheet> createState() => _SpotSheetState();
}

class _SpotSheetState extends State<SpotSheet> {
  void close(BuildContext context) =>
      (widget.onClose ?? () => Navigator.pop(context))();

  final extent = DraggableScrollableController();

  /// The preview's own scroll, for plates past the card's 62% limit (A15b
  /// ③): a sheet resting at its minimum would otherwise take every drag.
  final previewScroll = ScrollController();

  /// The side panel's scroll (T1, T2).
  final panelScroll = ScrollController();

  /// The preview's measured height (handle, name, plates), once laid out;
  /// the sheet stays invisible until then so it opens at its final height.
  double? previewHeight;

  /// The resting height (A15): enough for the plates, within 42–62%.
  double peek = spotSheetPeek;

  /// The plates need more than the card's limit, so they scroll within it.
  bool overflowing = false;

  double? _reportedPeek;

  void _measuredPreview(double height) {
    if (!mounted || height == previewHeight) return;
    setState(() => previewHeight = height);
  }

  /// [peek] for the space the sheet opens in; a resting sheet follows it.
  void _layoutPeek(BuildContext context, double available) {
    final height = previewHeight;
    final was = peek;
    if (height == null || !available.isFinite || available <= 0) return;
    final need = height + _previewMargins + _footerHeight(context);
    peek = (need / available).clamp(spotSheetPeek, spotSheetPeekMax);
    overflowing = need > spotSheetPeekMax * available + .5;
    if (peek < was && extent.isAttached && extent.size <= was + .001) {
      // Only a smaller peek can leave a dragged sheet above it; a larger
      // one the sheet clamps to itself.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && extent.isAttached) extent.jumpTo(peek);
      });
    }
    if (peek != _reportedPeek) {
      _reportedPeek = peek;
      final value = peek;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPeek?.call(value);
      });
    }
  }

  /// A drag on the handle, where the plates scroll and the sheet no longer
  /// takes drags from them (A15b ③).
  void _dragHandle(DragUpdateDetails details) {
    if (!extent.isAttached) return;
    final delta = extent.pixelsToSize(details.delta.dy);
    extent.jumpTo((extent.size - delta).clamp(peek, 1.0));
  }

  void _endHandleDrag(DragEndDetails details) {
    if (!extent.isAttached) return;
    final velocity = details.primaryVelocity ?? 0;
    final up =
        velocity < -300 || (velocity <= 300 && extent.size > (peek + 1) / 2);
    unawaited(
      extent.animateTo(
        up ? 1 : peek,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// Each plate's section in the details (A2, decision 10).
  final sections = {for (final face in FourSignFace.values) face: GlobalKey()};

  /// Pulled up to the full page (A2): the pinned header with the table of
  /// contents replaces the preview.
  bool full = false;

  /// The section the table of contents marks.
  FourSignFace current = FourSignFace.verdict;

  /// A jump under way: the mark stays on its target while the page moves.
  FourSignFace? jumping;

  /// The street segment the rider chose in 停哪裡 (A10): 能不能停 reads it.
  String? selectedSegment;

  /// Where no motorcycle may park (A2b): 有沒有位 and 怎麼算錢 opened.
  bool unfolded = false;

  /// 複製 just copied the address.
  bool copied = false;
  Timer? copiedTimer;

  /// The scroll the section mark follows.
  ScrollController? spied;

  /// Opens the details at [face]'s section.
  Future<void> showSection(FourSignFace face) async {
    setState(() {
      current = face;
      jumping = face;
    });
    if (extent.isAttached && extent.size < 1) {
      await extent.animateTo(
        1,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
    // The page swaps the preview for its header once full.
    await WidgetsBinding.instance.endOfFrame;
    final target = sections[face]!.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
    jumping = null;
  }

  /// Marks the section at the top of the page as the rider scrolls.
  void spy() {
    final scroll = spied;
    if (jumping != null ||
        !(full || widget.panel) ||
        scroll == null ||
        !scroll.hasClients) {
      return;
    }
    final position = scroll.position;
    var active = FourSignFace.verdict;
    for (final face in FourSignFace.values) {
      final box = sections[face]!.currentContext?.findRenderObject();
      if (box == null || !box.attached) continue;
      final viewport = RenderAbstractViewport.maybeOf(box);
      if (viewport == null) continue;
      if (position.pixels + 12 >= viewport.getOffsetToReveal(box, 0).offset) {
        active = face;
      }
    }
    if (active != current) setState(() => current = active);
  }

  Future<void> copyLocation() async {
    await Clipboard.setData(ClipboardData(text: copiedLocation(shown)));
    if (!mounted) return;
    setState(() => copied = true);
    copiedTimer?.cancel();
    copiedTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => copied = false);
    });
  }

  /// The spot's latest public changes (#141), read once per spot.
  late Future<List<HistoryEntry>> history = _history();

  /// The spot as last read back (#280): whoever opened the sheet handed a
  /// snapshot (a favourite's keeps no `is_own`, handle or held fields, and
  /// a content report changes what it names), so it is read again on
  /// opening, after a report and when the account changes.
  ParkingSpot? reread;

  /// What the sheet shows: [reread], else the spot it was opened with.
  ParkingSpot get shown => reread ?? widget.spot;

  late int _reports;

  /// Who the shown copy was read for: `is_own` and held text follow them.
  late String? _account;

  /// Numbers each read-back: only the newest may land.
  int _reads = 0;

  @override
  void initState() {
    super.initState();
    _reports = widget.store.reportsSent;
    _account = widget.store.riderId;
    widget.store.addListener(_storeChanged);
    unawaited(_reread());
    unawaited(widget.store.followSightings(widget.spot));
  }

  void _storeChanged() {
    final store = widget.store;
    if (store.reportsSent == _reports && store.riderId == _account) return;
    _reports = store.reportsSent;
    _account = store.riderId;
    unawaited(_reread());
  }

  /// Reads the spot again and swaps it in, nothing cleared first. One that
  /// cannot be read (offline, a TDX spot) keeps the copy shown, whose
  /// `is_own` [AppStore.ownSpot] no longer trusts across accounts.
  Future<void> _reread() async {
    final id = widget.spot.id, read = ++_reads;
    final ParkingSpot? latest;
    try {
      latest = await widget.store.latestSpot(id);
    } catch (_) {
      return;
    }
    if (mounted && latest != null && widget.spot.id == id && read == _reads) {
      setState(() => reread = latest);
    }
  }

  Future<List<HistoryEntry>> _history() => widget.store.parking
      .history(widget.spot.id)
      .catchError((Object _) => const <HistoryEntry>[]);

  @override
  void didUpdateWidget(SpotSheet old) {
    super.didUpdateWidget(old);
    if (old.spot.id != widget.spot.id) {
      reread = null;
      unawaited(_reread());
      history = _history();
      selectedSegment = null;
      unfolded = false;
      widget.store.unfollowSightings(old.spot);
      unawaited(widget.store.followSightings(widget.spot));
    }
  }

  Offset? start;
  bool dismissGesture = false;
  bool closing = false;
  String? feedback;
  Future<void> share(BuildContext buttonContext) async {
    final spot = shown;
    final text =
        '${spot.name}\nhttps://www.google.com/maps/search/?api=1&query=${spot.lat},${spot.lng}';
    final box = buttonContext.findRenderObject() as RenderBox;
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          text: text,
          subject: spot.name,
          sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
          downloadFallbackEnabled: false,
        ),
      );
      if (!kIsWeb || result.status != ShareResultStatus.unavailable) return;
    } catch (_) {
      if (!kIsWeb) rethrow;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) setState(() => feedback = '位置連結已複製，可貼上分享。');
  }

  @override
  void dispose() {
    widget.store.removeListener(_storeChanged);
    widget.store.unfollowSightings(widget.spot);
    spied?.removeListener(spy);
    copiedTimer?.cancel();
    extent.dispose();
    previewScroll.dispose();
    panelScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildDetails(context),
  );

  Widget _buildDetails(BuildContext context) {
    final store = widget.store, spot = shown;
    final colors = Theme.of(context).colorScheme;
    final photos = SpotPhotos.usable(spot.photoUrls);
    if (widget.panel) {
      return PointerInterceptor(
        intercepting: kIsWeb,
        child: _panel(context, store, spot, photos),
      );
    }
    // A wide window without the tablet layout keeps a phone-width sheet.
    return Align(
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        // Over a Google map on the web, the sheet must take its own clicks.
        child: PointerInterceptor(
          intercepting: kIsWeb,
          child: _sheet(context, store, spot, colors, photos),
        ),
      ),
    );
  }

  /// The details in the tablet's side panel (T1, T2).
  Widget _panel(
    BuildContext context,
    AppStore store,
    ParkingSpot spot,
    List<String> photos,
  ) {
    if (!identical(spied, panelScroll)) {
      spied?.removeListener(spy);
      spied = panelScroll..addListener(spy);
    }
    return SidePanel(
      // The same handle as the sheet: one name for the open spot's details.
      key: const ValueKey('parking-spot-sheet'),
      semanticLabel: '停車點詳情',
      child: AnimatedBuilder(
        animation: store,
        builder: (ctx, _) => MinuteTicker(
          clock: store.clock,
          builder: (ctx, now) =>
              _content(ctx, panelScroll, store, spot, photos, now),
        ),
      ),
    );
  }

  Widget _sheet(
    BuildContext context,
    AppStore store,
    ParkingSpot spot,
    ColorScheme colors,
    List<String> photos,
  ) {
    return NotificationListener<DraggableScrollableNotification>(
      onNotification: (n) {
        final pulled = n.extent >= .999;
        if (pulled != full) {
          // The full page scrolls as a whole; nothing stays offset in here.
          if (pulled && previewScroll.hasClients) previewScroll.jumpTo(0);
          setState(() => full = pulled);
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, box) {
          _layoutPeek(context, box.maxHeight);
          return _draggable(context, store, spot, photos);
        },
      ),
    );
  }

  Widget _draggable(
    BuildContext context,
    AppStore store,
    ParkingSpot spot,
    List<String> photos,
  ) {
    return DraggableScrollableSheet(
      key: const ValueKey('parking-spot-sheet'),
      controller: extent,
      initialChildSize: peek,
      minChildSize: peek,
      maxChildSize: 1,
      snap: true,
      shouldCloseOnMinExtent: false,
      expand: false,
      builder: (ctx, scroll) {
        if (!identical(spied, scroll)) {
          spied?.removeListener(spy);
          spied = scroll..addListener(spy);
        }
        return Listener(
          onPointerDown: (event) {
            start = event.position;
            dismissGesture =
                extent.isAttached &&
                extent.size <= peek + .001 &&
                scroll.hasClients &&
                scroll.offset <= 0 &&
                (!previewScroll.hasClients || previewScroll.offset <= 0);
          },
          onPointerMove: (event) {
            if (start == null || !dismissGesture || closing) return;
            final delta = event.position - start!;
            if (delta.dy > 80 && delta.dy > delta.dx.abs() * 1.2) {
              closing = true;
              close(ctx);
            }
          },
          onPointerUp: (_) {
            start = null;
            dismissGesture = false;
          },
          onPointerCancel: (_) {
            start = null;
            dismissGesture = false;
          },
          child: Opacity(
            opacity: previewHeight == null ? 0 : 1,
            child: Material(
              color: Theme.of(ctx).colorScheme.surface,
              // The full page is square; the preview floats over the map.
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(full ? 0 : 28),
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedBuilder(
                animation: store,
                builder: (ctx, _) => MinuteTicker(
                  // Each minute too: whether a time slot holds now is part
                  // of the decision (#120), not only the rate.
                  clock: store.clock,
                  builder: (ctx, now) =>
                      _content(ctx, scroll, store, spot, photos, now),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _content(
    BuildContext ctx,
    ScrollController scroll,
    AppStore store,
    ParkingSpot spot,
    List<String> photos,
    DateTime now,
  ) {
    final colors = Theme.of(ctx).colorScheme;
    final vehicle = store.vehicle;
    final decision = store.decide(spot);
    final availability = store.availabilityOf(spot);
    final closures = store.riderClosures(spot);
    FourSign signOver(int window) => fourSign(
      spot,
      vehicle,
      store.rules,
      now: now,
      availability: availability,
      riders: store.riderSeats(window),
      closures: closures,
      decision: decision,
    );
    // The details read riders' reports of 30 minutes, the preview's plates
    // those of 15 (A6, A10).
    final detail = signOver(sightingDetailWindow);
    // The panel shows the details at once, so its plates read them too.
    final sign = full || widget.panel ? detail : signOver(sightingMapWindow);
    // A chosen segment (A10) decides 能不能停; the other plates stay the
    // street's overview (user decision 2026-10-31).
    final selected = sign.street
        ? sign.areas
              .where((a) => a.id != null && a.id == selectedSegment)
              .firstOrNull
        : null;
    // Neither vehicle may park here (A2b): one plate, whichever is chosen.
    final notParkable =
        sign.denied &&
        fourSignVerdict(
              spot,
              vehicle == VehicleType.heavy
                  ? VehicleType.scooter
                  : VehicleType.heavy,
              store.rules,
              now: now,
            ).status ==
            EligibilityStatus.notAllowed;
    final signPlates = fourSignPlates(sign, now);
    final plates = [
      if (notParkable)
        notParkablePlate(signPlates.first)
      else
        for (final p in signPlates)
          if (p.face == FourSignFace.verdict && selected != null)
            selectedVerdictPlate(sign, selected)
          else
            p,
    ];
    // Only where it has a place to go (A7, A7b); see [sightingPlaces].
    final reportable = sightableSpot(spot.id) && sightingPlaces(detail) != null;
    // Keyed by spot: another spot's bar starts at its left end (A15a ②).
    SpotPreviewActions actionsAt(double edge) => SpotPreviewActions(
      key: ValueKey(spot.id),
      street: !spot.isFacility,
      navigateSecondary: notParkable,
      edge: edge,
      onNavigate: () => runAction(ctx, () => navigateTo(spot.lat, spot.lng)),
      onReport: reportable
          ? () => runAction(
              ctx,
              () => showSightingSheet(ctx, store, spot, detail),
            )
          : null,
      onSuggest: () => runAction(ctx, () async {
        final wasHidden = store.riderHidden(spot);
        await showSpotSuggestions(ctx, store, spot);
        // The rider was hidden from a content report there (#280): the
        // details close, as after ⋯'s 隱藏.
        if (ctx.mounted && !wasHidden && store.riderHidden(spot)) close(ctx);
      }),
    );
    final subtitle = previewSubtitle(
      spot,
      meters: store.located
          ? distanceMeters(store.lat, store.lng, spot.lat, spot.lng)
          : null,
    );
    final favorite = store.favorites.any((s) => s.id == spot.id);
    void toggleFavorite() => runAction(ctx, () => store.toggleFavorite(spot));
    final body = _body(
      ctx,
      store,
      spot,
      detail,
      plates,
      decision,
      availability,
      selected,
      photos,
      now,
      notParkable: notParkable,
    );
    // The spot's own name held for review (P17b ⑪): under the title.
    final heldName = store.heldForOwner(spot, 'spot_name')
        ? const ContentHeldNote()
        : null;
    if (widget.panel) {
      return _panelContent(
        ctx,
        scroll,
        store,
        spot,
        preview: SpotPreview(
          spot: spot,
          titleNote: heldName,
          plates: plates,
          subtitle: subtitle,
          favorite: favorite,
          onFavorite: toggleFavorite,
          onShare: share,
          onClose: () => close(ctx),
          onPlate: showSection,
        ),
        body: body,
        actionsAt: actionsAt,
      );
    }
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final width = constraints.maxWidth - (full ? 32 : 40);
        final footer = _footerHeight(ctx);
        // A short sheet (a phone in landscape) keeps the actions in the
        // scrolling list so the header is never squeezed out.
        final pinned = constraints.maxHeight - footer >= _minDetailHeight;
        // Likewise the full page's header: pinned while the page keeps
        // room to read below it.
        final headerPinned =
            full &&
            pinned &&
            constraints.maxHeight - footer - _headerHeight(ctx, spot, width) >=
                _minDetailHeight;
        final titleNote = heldName;
        final header = SpotDetailHeader(
          spot: spot,
          titleNote: titleNote,
          subtitle: subtitle,
          plates: plates,
          current: current,
          favorite: favorite,
          onFavorite: toggleFavorite,
          onShare: share,
          onBack: () => close(ctx),
          onPlate: showSection,
        );
        return Column(
          children: [
            if (headerPinned)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(
                    bottom: BorderSide(color: DetailColors.of(ctx).divider),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x14000000),
                      blurRadius: 6,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: header,
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, viewport) => _detailScroll(
                  scroll,
                  height: viewport.maxHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!full) ...[
                        _MeasuredHeight(
                          onHeight: _measuredPreview,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _handle(colors),
                              // A hidden rider's spot opened from a list
                              // (P17d).
                              HiddenSpotBanner(store: store, spot: spot),
                              SpotPreview(
                                spot: spot,
                                titleNote: titleNote,
                                plates: plates,
                                subtitle: subtitle,
                                favorite: favorite,
                                onFavorite: toggleFavorite,
                                onShare: share,
                                onClose: () => close(ctx),
                                onPlate: showSection,
                                besideRow: seatBesideRow(sign, now),
                                closureLines: closureLines(
                                  sign,
                                  now,
                                  details: false,
                                ),
                                disagrees: sign.seat.disagrees,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Divider(height: 1, color: colors.outlineVariant),
                      ] else if (!headerPinned) ...[
                        const SizedBox(height: 6),
                        header,
                        Divider(height: 1, color: DetailColors.of(ctx).divider),
                      ],
                      if (full) ...[
                        const SizedBox(height: 12),
                        HiddenSpotBanner(store: store, spot: spot),
                      ],
                      ...body,
                      if (!pinned) ...[
                        const SizedBox(height: 16),
                        actionsAt(0),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (pinned)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: colors.outlineVariant)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: actionsAt(full ? 16 : 20),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The side panel (T1, T2): the grabber, the name and the plates stay at
  /// the top, the four sections scroll under them, the actions hold the
  /// foot above whatever the window keeps there (the iPad's tab bar). A
  /// panel too short for all three lets the top, then the actions, scroll
  /// with the rest.
  Widget _panelContent(
    BuildContext ctx,
    ScrollController scroll,
    AppStore store,
    ParkingSpot spot, {
    required Widget preview,
    required List<Widget> body,
    required Widget Function(double edge) actionsAt,
  }) {
    final colors = Theme.of(ctx).colorScheme;
    final divider = DetailColors.of(ctx).divider;
    final bottom = MediaQuery.paddingOf(ctx).bottom;
    final head = Column(
      key: const ValueKey('spot-panel-header'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [const SidePanelGrabber(), preview, const SizedBox(height: 12)],
    );
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final footer = _footerHeight(ctx);
        final pinned = constraints.maxHeight - footer >= _minDetailHeight;
        final headPinned =
            pinned &&
            constraints.maxHeight -
                    footer -
                    _panelHeaderHeight(ctx, spot, constraints.maxWidth - 32) >=
                _minDetailHeight;
        return Column(
          children: [
            if (headPinned)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(bottom: BorderSide(color: divider)),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: head,
                ),
              ),
            Expanded(
              // Not lazy: a plate can open any section at once.
              child: SingleChildScrollView(
                key: const ValueKey('spot-panel-scroll'),
                controller: scroll,
                padding: EdgeInsets.fromLTRB(
                  16,
                  0,
                  16,
                  24 + (pinned ? 0 : bottom),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!headPinned) ...[
                      head,
                      Divider(height: 1, color: divider),
                    ],
                    const SizedBox(height: 12),
                    HiddenSpotBanner(store: store, spot: spot),
                    ...body,
                    if (!pinned) ...[const SizedBox(height: 16), actionsAt(0)],
                  ],
                ),
              ),
            ),
            if (pinned)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  border: Border(top: BorderSide(color: divider)),
                ),
                child: SafeArea(
                  top: false,
                  left: false,
                  right: false,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: actionsAt(16),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The details' scroll. Two nested scroll views, so the same tree serves
  /// both ways of moving: normally the sheet's own [scroll] takes every
  /// drag (and grows the sheet from rest); with the plates past the card's
  /// limit it stands still and [previewScroll] moves them within the card
  /// (A15b ③): it fills the card, so it wins every drag there. The sheet's
  /// own scroll keeps its physics throughout — switching them off would
  /// cancel a drag pulling the full page down, and the sheet would spring
  /// back. Not lazy: a plate can open any section at once, however far
  /// down it sits.
  Widget _detailScroll(
    ScrollController scroll, {
    required double height,
    required Widget child,
  }) {
    final inCard = overflowing && !full;
    return SingleChildScrollView(
      controller: scroll,
      child: SizedBox(
        height: inCard ? height : null,
        child: SingleChildScrollView(
          controller: previewScroll,
          physics: inCard ? null : const NeverScrollableScrollPhysics(),
          padding: full
              ? const EdgeInsets.fromLTRB(16, 0, 16, 24)
              : const EdgeInsets.fromLTRB(20, 10, 20, 24),
          child: child,
        ),
      ),
    );
  }

  /// The preview's drag handle; it moves the sheet itself while the plates
  /// scroll in the card (A15b ③).
  Widget _handle(ColorScheme colors) {
    final handle = Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: colors.outline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
    if (!overflowing) return handle;
    return GestureDetector(
      key: const ValueKey('spot-sheet-handle'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _dragHandle,
      onVerticalDragEnd: _endHandleDrag,
      child: handle,
    );
  }

  /// The four sections (A2), then the notes the canvas leaves out and the
  /// sources in small print (user decision 2026-10-31).
  List<Widget> _body(
    BuildContext ctx,
    AppStore store,
    ParkingSpot spot,
    FourSign sign,
    List<SignPlate> plates,
    ParkingDecision decision,
    SpotAvailability availability,
    SignArea? selected,
    List<String> photos,
    DateTime now, {
    required bool notParkable,
  }) {
    final vehicle = store.vehicle;
    final display = eligibilityDisplay(
      spot,
      vehicle,
      decision.eligibility,
      decision: decision,
    );
    final rules = detailRules(sign, spot);
    final rows = seatRows(sign, availability, now);
    final fees = feeSection(sign, spot, now);
    final cards = whereCards(sign, spot, now);
    final (address, coordinates) = addressAndCoordinates(spot);
    final unit = detailUnit(sign);
    final seatPlate = plates
        .where((p) => p.face == FourSignFace.seat)
        .firstOrNull;
    final legacy = spot.available;
    // Live counts come from snapshots; a lot's own legacy count is shown
    // the old way only when no snapshot exists for it.
    final live =
        spot.isFacility &&
        (!availability.isEmpty || legacy == null || legacy < 0);
    // A spot standing as one: its report under the answer, or as the answer.
    final report = sign.seat.rider ?? sign.seat.beside;
    final wholeReport = rows.isEmpty && report != null
        ? SeatRiderBox(
            key: const ValueKey('detail-seat-rider'),
            line: riderLineOf(report, now),
          )
        : null;
    final seatTitle = rows.isEmpty || (spot.isFacility && !live)
        ? '有沒有位'
        : '有沒有位（${vehicle.label}能停的$unit）';
    final Widget seat;
    if (spot.isFacility && !live) {
      // A lot's own legacy count, where no snapshot exists for it.
      final total = spot.scooterTotal;
      final at =
          spot.availabilityUpdatedAt ??
          (spot.source == 'tdx' ? spot.updatedAt : null);
      seat = SeatWholeView(
        main: legacy == 0 ? '已滿' : '剩 $legacy 格',
        explanation: [
          if (total != null && total >= legacy!) '共 $total 格',
          at == null ? '車位時間未提供' : formatSpotTime(at),
        ].join('・'),
      );
    } else if (rows.isEmpty && sign.seat.kind == SeatKind.rider) {
      seat = wholeReport!;
    } else if (rows.isNotEmpty) {
      seat = SeatRowsView(
        rows: rows,
        note: seatRowsNote(sign),
        riderLine: (row) => seatRiderLine(
          row,
          store.riderSeats(sightingDetailWindow).of(spot.id),
          now,
        ),
        wholeLine: wholeRiderLine(
          store.riderSeats(sightingDetailWindow).of(spot.id),
          now,
        ),
        wholeTitle: wholeRiderTitle(street: sign.street),
        betaCities: inAvailabilityBeta(spot.city, store.availabilityBetaCities)
            ? store.availabilityBetaCities
            : null,
      );
    } else if (live) {
      seat = SpotSeatSection(
        fact: availabilityFact(spot, availability, vehicle, decision, now),
        sectionTitle: seatTitle,
        betaCities: inAvailabilityBeta(spot.city, store.availabilityBetaCities)
            ? store.availabilityBetaCities
            : null,
      );
    } else {
      seat = SeatWholeView(
        main: seatPlate?.main ?? '空位未知',
        explanation: seatExplanation(sign),
      );
    }
    final selectable =
        sign.street && cards.where((c) => c.area.id != null).length > 1;
    final small = Theme.of(ctx).textTheme;
    return [
      if (feedback != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(feedback!),
        ),
      DetailSection(
        key: sections[FourSignFace.verdict],
        title: '能不能停',
        children: [
          // Works or a closure (#116), above the verdict: it overrides it
          // while it holds.
          if (spot.closure case final closure?)
            ClosureCard(
              closure: closure,
              now: now,
              onReopened: () => runAction(ctx, () async {
                final message = await reportReopened(store, spot);
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx)
                      .showSnackBar(SnackBar(content: Text(message)));
                }
              }),
              onStillClosed: () =>
                  runAction(ctx, () => showGoneReport(ctx, store, spot)),
            ),
          if (notParkable)
            // A2b: one red conclusion for both vehicles, and why.
            VerdictCard(
              status: EligibilityStatus.notAllowed,
              headline: notParkableHeadline,
              explanation: notParkableExplanation,
              basis: display.basis,
              notices: display.notices,
            )
          else if (selected == null && sign.verdict.riderClosed != null)
            // Riders closed it (A7d ④): for every vehicle, by their word.
            VerdictCard(
              status: EligibilityStatus.notAllowed,
              headline: verdictHeadline(sign)!,
              explanation: riderClosedNote(sign.verdict.riderClosed!, now),
            )
          else
            VerdictCard(
              status: selected?.riderClosed ?? false
                  ? EligibilityStatus.notAllowed
                  : selected?.status ?? sign.verdict.status,
              headline:
                  verdictHeadline(sign, selected: selected) ??
                  undecidedHeadline(vehicle, display.label),
              // The rows below say what limits it; the decision's reason
              // stays only where no row does.
              explanation: selected != null
                  ? selectedNote(sign, selected)
                  // Dropped only where the rows below say all of it.
                  : (sign.verdict.status == EligibilityStatus.allowed ||
                            sign.verdict.status ==
                                EligibilityStatus.conditional) &&
                        rulesCover(display.explanation, rules)
                  ? ''
                  : display.explanation,
              basis: display.basis,
              notices: display.notices,
              reported: display.reported && !display.lapsed,
              banned: selected == null && sign.verdict.noParkingNow,
            ),
          if (!notParkable)
            for (final (i, line) in closureLines(
              sign,
              now,
              details: true,
            ).indexed)
              ClosureLineView(key: ValueKey('detail-closure-$i'), line: line),
          if (notParkable)
            DetailRulesView(
              rules: notParkableRules(sign, spot, decision.eligibility.reason),
              vehicle: vehicle,
              scope: false,
            )
          else if (rules.isNotEmpty)
            DetailRulesView(rules: rules, vehicle: vehicle),
        ],
      ),
      // A2b: 有沒有位 and 怎麼算錢 folded into one row, opened in place.
      if (notParkable)
        DetailSection(
          title: '有沒有位・怎麼算錢',
          children: [
            NotParkableFold(
              expanded: unfolded,
              onToggle: () => setState(() => unfolded = !unfolded),
            ),
          ],
        ),
      if (!notParkable || unfolded) ...[
        DetailSection(
          key: sections[FourSignFace.seat],
          title: seatTitle,
          gap: 8,
          children: [
            seat,
            if (wholeReport != null && !identical(seat, wholeReport))
              wholeReport,
          ],
        ),
        DetailSection(
          key: sections[FourSignFace.fee],
          title: fees.title,
          children: [
            FeeSectionView(
              section: fees,
              vehicle: vehicle,
              extraNote: _additionalFeeNote(spot),
            ),
          ],
        ),
      ],
      DetailSection(
        key: sections[FourSignFace.where],
        title: notParkable ? '停哪裡' : '停哪裡（${vehicle.label}）',
        trailing: photos.isEmpty ? null : '點照片可放大',
        last: true,
        children: [
          WhereView(
            cards: cards,
            heldNote: store.heldForOwner(spot, 'text')
                ? const ContentHeldNote()
                : null,
            entrance: spot.isFacility ? spot.entranceNote.trim() : '',
            guide: spot.parkingGuide.trim(),
            photos: photos,
            closedNote: closedNote(sign),
            pendingNote: pendingNote(sign),
            selectedId: selected?.id,
            onSelect: selectable
                ? (id) => setState(() => selectedSegment = id)
                : null,
            address: address,
            coordinates: coordinates,
            onCopy: () => runAction(ctx, copyLocation),
            copied: copied,
          ),
        ],
      ),
      // Not drawn on the canvas: kept as before until decided.
      if (spot.specialRules.trim().isNotEmpty || spot.note.trim().isNotEmpty)
        _DetailSection(
          title: '補充說明',
          icon: Icons.notes_outlined,
          children: [
            if (spot.specialRules.trim().isNotEmpty)
              _DetailField(
                label: '特殊規則',
                value: spot.specialRules,
                held: store.heldForOwner(spot, 'text'),
              ),
            if (spot.note.trim().isNotEmpty)
              _DetailField(
                label: '備註',
                value: spot.note,
                held: store.heldForOwner(spot, 'text'),
              ),
          ],
        ),
      // Sources and history in small print, after the address (user
      // decision 2026-10-31).
      Theme(
        data: Theme.of(ctx).copyWith(
          textTheme: small.copyWith(
            bodyMedium: small.bodySmall,
            titleMedium: small.titleSmall,
            labelLarge: small.labelMedium,
          ),
        ),
        child: _DetailSection(
          title: '資料與查核',
          icon: Icons.verified_outlined,
          children: [
            _DetailField(
              label: '資料來源',
              value: sourceSummary(spot, demo: store.demo),
              held: store.heldForOwner(spot, 'rider_name'),
            ),
            if (!spot.isOfficial)
              _ConfirmationField(lines: confirmationLines(spot)),
            _LatestUpdateField(spot: spot, history: history),
            // 隱藏這位車友, 檢舉內容不當 (P17a).
            widget.sourceActions ??
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: SpotMoreButton(
                    store: store,
                    spot: spot,
                    onClose: () => close(ctx),
                  ),
                ),
          ],
        ),
      ),
      if (!store.canReport)
        TextButton(
          onPressed: () => showSignIn(ctx, store),
          child: const Text('登入後提出修改建議'),
        ),
    ];
  }
}

String _additionalFeeNote(ParkingSpot spot) {
  if (spot.fee != null) return '';
  final rates = [
    for (final zone in spot.zones) ...[
      zone.feeNote,
      zone.scooterFeeText,
      zone.heavyFeeText,
      // A car's old text is not shown (decision 45).
    ],
  ];
  if (!rates.any((rate) => rate.trim().isNotEmpty)) return '';
  final note = spot.feeNote.trim();
  if (note == '0' && rates.any((rate) => rate.trim() == '免費')) return '';
  if ([
        '',
        '請依現場公告',
        '依現場公告',
        '依車種計費',
        '依車種與分區計費',
        '依車種與停放區計費',
        '依分區計費',
      ].contains(note) ||
      rates.any((rate) => rate.trim() == note)) {
    return '';
  }
  return note;
}

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  bool _missing(Widget child) =>
      child is _DetailField &&
      (child.value.trim().isEmpty || child.value.trim() == '未提供') &&
      child.secondary.isEmpty;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final missing = children
        .where(_missing)
        .cast<_DetailField>()
        .map((field) => field.label)
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Row(
              children: [
                Icon(icon, size: 19, color: colors.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: colors.outlineVariant),
          const SizedBox(height: 16),
          ...children.where((child) => !_missing(child)),
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '尚未提供：${missing.join('、')}',
                key: ValueKey('missing-$title'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// 部分內容審核中, in amber beside a held field's title (P17b ⑪).
class ContentHeldNote extends StatelessWidget {
  const ContentHeldNote({super.key});
  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('content-held'),
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.schedule, size: 14, color: conditionalColor),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          contentHeldNote,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: conditionalColor, fontWeight: FontWeight.w600),
        ),
      ),
    ],
  );
}

class _DetailField extends StatelessWidget {
  const _DetailField({
    required this.label,
    required this.value,
    this.secondary = '',
    this.action,
    this.held = false,
  });

  /// The contributor's own text under review (P17b ⑪).
  final bool held;

  final String label, value, secondary;

  /// A link or toggle under the value (看更新紀錄, 還有 N 項).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final labelText = Text(
      label,
      style: Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: colors.onSurfaceVariant),
    );
    final labelWidget = held
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [labelText, const ContentHeldNote()],
          )
        : labelText;
    final valueWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (value.trim().isNotEmpty)
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(height: 1.5),
          ),
        if (secondary.isNotEmpty) ...[
          if (value.trim().isNotEmpty) const SizedBox(height: 5),
          Text(
            secondary,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: colors.onSurfaceVariant, height: 1.5),
          ),
        ],
        ?action,
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 300 ||
              MediaQuery.textScalerOf(context).scale(14) > 18) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labelWidget, const SizedBox(height: 6), valueWidget],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 76, child: labelWidget),
              const SizedBox(width: 12),
              Expanded(child: valueWidget),
            ],
          );
        },
      ),
    );
  }
}

/// 確認狀態 (decision 52): the newest confirmation, the rest folded under
/// 「還有 N 項」; 尚未確認 when there is none.
class _ConfirmationField extends StatefulWidget {
  const _ConfirmationField({required this.lines});
  final List<String> lines;

  @override
  State<_ConfirmationField> createState() => _ConfirmationFieldState();
}

class _ConfirmationFieldState extends State<_ConfirmationField> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines;
    if (lines.length < 2) {
      return _DetailField(label: '確認狀態', value: lines.firstOrNull ?? '尚未確認');
    }
    final colors = Theme.of(context).colorScheme;
    return _DetailField(
      label: '確認狀態',
      value: (expanded ? lines : lines.take(1)).join('\n'),
      action: Semantics(
        expanded: expanded,
        child: TextButton.icon(
          key: const ValueKey('spot-confirmations-more'),
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 40),
            alignment: AlignmentDirectional.centerStart,
            foregroundColor: colors.primary,
          ),
          onPressed: () => setState(() => expanded = !expanded),
          iconAlignment: IconAlignment.end,
          icon: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text(expanded ? '收起' : '還有 ${lines.length - 1} 項'),
        ),
      ),
    );
  }
}

/// 最近更新 (#141, AppHistory): the latest change's kinds and date, and
/// 「看更新紀錄」 for the last 10. Until the history answers, or where there
/// is none, the spot's own update time stands in.
class _LatestUpdateField extends StatelessWidget {
  const _LatestUpdateField({required this.spot, required this.history});
  final ParkingSpot spot;
  final Future<List<HistoryEntry>> history;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<HistoryEntry>>(
    future: history,
    builder: (context, snapshot) {
      final entries = snapshot.data ?? const <HistoryEntry>[];
      final latest = entries.firstOrNull;
      final updated = spot.updatedAt;
      // History covers administrators' writes, decided reports, owners'
      // edits and votes (decision 56); an update it does not cover (an older
      // server) keeps its later time.
      final covered =
          latest != null &&
          (updated == null ||
              !updated.isAfter(latest.at.add(const Duration(minutes: 1))));
      return _DetailField(
        label: '最近更新',
        value: covered
            ? '${latest.title(app: true)}，${formatSpotDate(latest.at)}'
            : updated == null
            ? '未提供'
            : formatSpotTime(updated),
        // An old spot says so under its date, in the small print.
        secondary: spot.stale ? '停放資訊可能過時，請確認現場公告。' : '',
        action: latest == null
            ? null
            : TextButton(
                key: const ValueKey('spot-history-open'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(48, 40),
                  alignment: AlignmentDirectional.centerStart,
                ),
                onPressed: () => showSpotHistory(context, spot, entries),
                child: const Text('看更新紀錄'),
              ),
      );
    },
  );
}

/// The app's 更新紀錄 sheet (AppHistory): the latest 10 changes, each its
/// kinds, what it changed to where the spot still holds it, and the date
/// with where it came from. No reporter or administrator is named, and no
/// before value is shown.
Future<void> showSpotHistory(
  BuildContext context,
  ParkingSpot spot,
  List<HistoryEntry> entries,
) => showAdaptiveSheet<void>(
  context,
  (ctx) => ContentPage(
    children: [
      SheetTitle('更新紀錄'),
      const SizedBox(height: 8),
      for (final (i, entry) in entries.take(10).indexed)
        _HistoryItem(
          key: ValueKey('spot-history-$i'),
          entry: entry,
          official: spot.isOfficial,
          last: i == math.min(entries.length, 10) - 1,
        ),
      const SizedBox(height: 12),
      Text(
        '只列最近 10 筆，不顯示回報者名稱。',
        style: Theme.of(ctx).textTheme.bodySmall
            ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
      ),
    ],
  ),
);

class _HistoryItem extends StatelessWidget {
  const _HistoryItem({
    super.key,
    required this.entry,
    required this.official,
    required this.last,
  });
  final HistoryEntry entry;
  final bool official, last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summary = historySummary(entry);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: last
            ? null
            : Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.title(app: true),
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(summary, style: text.bodyMedium),
          ],
          const SizedBox(height: 2),
          Text(
            '${formatSpotDate(entry.at)}・${historySourceText(entry, official: official)}',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Room the scrolling details keep above a pinned action footer: the drag
/// handle, the name and the start of the eligibility summary.
const _minDetailHeight = 160.0;

/// Upper estimate of the full page's header at [width]: 返回, the name,
/// the subtitle and the table of contents.
double _headerHeight(BuildContext context, ParkingSpot spot, double width) {
  final scale = MediaQuery.textScalerOf(context);
  final target = isCupertino ? 44.0 : 48.0;
  final nameWidth = isCupertino ? width : width - target * 3 - 8;
  final painter = TextPainter(
    text: TextSpan(
      text: spot.name,
      style: TextStyle(fontSize: scale.scale(20), height: 1.3),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: nameWidth.clamp(1, double.infinity));
  final name = painter.height;
  painter.dispose();
  final title = name + scale.scale(13) * 1.4 * 2 + 2;
  final top = isCupertino ? target + 2 + title : math.max(target, title + 10);
  final rows = FourSignPlates.gridFor(context, width) ? 2 : 1;
  final plate =
      math.max(target, scale.scale(11) * 1.3 + scale.scale(14) * 1.25 + 8) + 8;
  return 6 + top + 10 + rows * plate + (rows - 1) * 8 + 6;
}

/// Upper estimate of the side panel's top at [width]: the grabber, the
/// name beside its three buttons, the subtitle and the plates.
double _panelHeaderHeight(
  BuildContext context,
  ParkingSpot spot,
  double width,
) {
  final scale = MediaQuery.textScalerOf(context);
  final painter = TextPainter(
    text: TextSpan(
      text: spot.name,
      style: TextStyle(fontSize: scale.scale(20), height: 1.3),
    ),
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: (width - 48 * 3).clamp(1, double.infinity));
  final name = painter.height;
  painter.dispose();
  final title = math.max(48.0, 6 + name + 2 + scale.scale(13) * 1.4 * 2);
  final rows = FourSignPlates.gridFor(context, width) ? 2 : 1;
  final plate = math.max(
    64.0,
    scale.scale(11) * 1.3 * 2 + scale.scale(16) * 1.3 + 16,
  );
  return 19 + title + 12 + rows * plate + (rows - 1) * 8 + 12;
}

/// The pinned footer: border, 20 padding, the safe area and the row of
/// buttons at the current text size.
double _footerHeight(BuildContext context) =>
    21 +
    MediaQuery.paddingOf(context).bottom +
    SpotPreviewActions.heightFor(context);

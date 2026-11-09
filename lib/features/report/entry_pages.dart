// Where a spot's bays are (#190): the zone list S1b, the segment list S3b,
// and the page that edits them, S2 and S4. From a suggestion the edit page
// sends its own patch (C6); from a new spot (N1) it hands its one entry back
// and N1 sends everything together (C14).
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../data/account_suspended.dart';
import '../../data/app_store.dart';
import '../../domain/precheck.dart';
import '../../models/condition_text.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';
import '../../models/zone_entries.dart';
import '../../ui/adaptive/adaptive.dart';
import '../account/suspended_sheet.dart';
import '../auth/sign_in.dart';
import '../map/space_type_sheet.dart';
import 'entry_drafts.dart';
import 'form_parts.dart';
import 'report_sheet.dart';
import 'spot_suggestions.dart' show reportSummary;

/// Whether stored fee text says nothing: 費率沒寫一律未提供
/// (PM_ANS_20261101_56).
bool noFeeText(String text) => const {
  '',
  '依現場公告',
  '請以現場公告為準',
  defaultFeeNote,
  '費率未確認',
}.contains(text.trim());

/// 全場費率 or 整條路費率 in words: the rates, the stored text, or 未提供.
String wholeFeeText(Fee? rates, String? text) {
  if (rates != null && !rates.isEmpty) {
    return _samePrice(rates) ?? feeNoteOf(rates);
  }
  return text == null || noFeeText(text) ? '未提供' : text;
}

/// 全場同價 read once, as a sign does, without the rule in brackets: every
/// vehicle that applies pays the same, a follow as what it follows. Null
/// when they differ, a vehicle has no rate, or the rate goes by the hour of
/// day.
String? _samePrice(Fee fee) {
  Rate? paid(Rate? r) => switch (r?.mode) {
    FeeMode.sameAsScooter => fee.scooter,
    FeeMode.sameAsCar => fee.car,
    _ => r,
  };
  final rates = [fee.scooter, paid(fee.heavy), fee.car];
  if (rates.contains(null)) return null;
  final applied = [
    for (final r in rates)
      if (r!.mode != FeeMode.notApplicable) r,
  ];
  if (applied.isEmpty ||
      applied.first.mode == FeeMode.byTime ||
      applied.any((r) => r != applied.first)) {
    return null;
  }
  final text = applied.first.text.replaceFirst(RegExp(r'（.*）$'), '');
  return text.isEmpty ? null : text;
}

/// On the card of a street spot without segments: what sending it does.
const firstSegmentNote = '改了送出後，這裡會成為這條路的第一段；其他段請用「新增一段」補上。';

/// A form's pages pushed inside its sheet (S1b, S2…): the sheet stays while
/// its pages step forward and back, and system back steps first.
class FormFlow extends StatefulWidget {
  const FormFlow({super.key, required this.child});

  /// The first page.
  final Widget child;

  @override
  State<FormFlow> createState() => _FormFlowState();
}

class _FormFlowState extends State<FormFlow> {
  final navigator = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) => NavigatorPopHandler<Object?>(
    onPopWithResult: (_) => navigator.currentState?.maybePop(),
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .92,
      child: Navigator(
        key: navigator,
        onGenerateInitialRoutes: (_, _) => [formRoute<void>(widget.child)],
      ),
    ),
  );
}

/// A page of a [FormFlow].
Route<T> formRoute<T>(Widget page) => MaterialPageRoute<T>(
  builder: (context) =>
      Material(color: Theme.of(context).colorScheme.surface, child: page),
);

/// Closes the whole sheet from any page of its [FormFlow].
void closeFlow(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).pop();

/// A form page: its top bar, the scrolling [children], and what stays
/// pinned at the bottom.
class FormPage extends StatelessWidget {
  const FormPage({
    super.key,
    required this.header,
    required this.children,
    this.footer,
    this.controller,
  });
  final Widget header;
  final List<Widget> children;
  final Widget? footer;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: SingleChildScrollView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
        ?footer,
      ],
    ),
  );
}

/// Sends a suggestion: true when it went. A refusal keeps the form as it
/// is; a suspended account gets the shared panel (#331), a signed-out rider
/// 登入 (C2).
Future<bool> sendSuggestion(
  BuildContext context,
  AppStore store,
  Map<String, Object?> body,
) async {
  if (!store.canReport) {
    await showSignIn(context, store);
    return false;
  }
  try {
    await store.submit(body);
    return true;
  } catch (e) {
    if (!context.mounted) return false;
    if (accountSuspendedFrom(e) case final s?) {
      await showSuspendedSheet(context, s.until, untilKnown: s.untilKnown);
    } else {
      showMessage(
        context,
        e is StateError ? e.message.toString() : '建議沒有送出，內容還在，請確認網路後再送一次。',
      );
    }
    return false;
  }
}

/// Who the zone lets [vehicle] park, as S1b's tag reads; a 共用時段 for it
/// makes it 有條件 in those hours.
EntryTag vehicleTag(
  String short,
  Eligible? value,
  ParkingCondition? condition,
  SlotVehicle vehicle,
) {
  if (value == Eligible.allowed) {
    final slot = condition?.schedule
        .where((s) => s.vehicles.contains(vehicle))
        .firstOrNull;
    if (slot?.from case final from?) {
      return EntryTag(
        '$short 有條件・$from–${slot!.to}',
        tone: EntryTagTone.conditional,
      );
    }
  }
  return switch (value) {
    Eligible.allowed => EntryTag('$short 可停', tone: EntryTagTone.ok),
    Eligible.notAllowed => EntryTag('$short 不能停', tone: EntryTagTone.denied),
    Eligible.notStated => EntryTag(
      '$short ${Eligible.notStated.label}',
      tone: EntryTagTone.unknown,
    ),
    null => EntryTag('$short 待確認', tone: EntryTagTone.unknown),
  };
}

/// A segment's tags (S3b): who may park, then what limits it.
List<EntryTag> segmentTags(EntryDraft draft) {
  final c = draft.stored;
  return [
    if (draft.scooter == Eligible.allowed && draft.heavy == Eligible.allowed)
      const EntryTag('普機・重機可停')
    else ...[
      vehicleTag('普機', draft.scooter, null, SlotVehicle.scooter),
      vehicleTag('重機', draft.heavy, null, SlotVehicle.heavy),
    ],
    for (final l in c?.limits ?? const <ParkingLimit>[])
      if (l.kind == LimitKind.timeLimit || l.kind == LimitKind.noParking)
        EntryTag(limitText(l)),
    for (final slot in c?.schedule ?? const <ScheduleSlot>[])
      EntryTag(scheduleSlotText(slot)),
  ];
}

/// A list icon on a light patch, as wide as a marking.
class EntryIconTile extends StatelessWidget {
  const EntryIconTile(this.icon, {super.key});
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Icon(icon),
  );
}

Widget entryMarking(SpaceKind? kind) => kind == null
    ? const SizedBox(width: 44, height: 44, child: Icon(Icons.grid_view))
    : GroundMarking(
        type: kind.markingType,
        shared: kind == SpaceKind.scooterHeavy,
      );

/// What opening a list's entry does: a new spot edits a copy of its draft;
/// a suggestion opens all of them, and sends from the page it opens.
class EntryListArgs {
  const EntryListArgs({
    required this.store,
    required this.type,
    required this.subtitle,
    required this.city,
    this.district = '',
    this.spot,
    this.drafts,
    this.onChanged,
    required this.fee,
    this.onSpotFee,
    this.onEntryFee,
    this.whole,
    this.onWhole,
  }) : assert((spot == null) != (drafts == null));
  final AppStore store;
  final EntryType type;
  final String subtitle;
  final String? city;

  /// The spot's district, which a city's rule may name.
  final String district;

  /// The spot a suggestion is about; null in a new spot.
  final ParkingSpot? spot;

  /// A new spot's entries (N1's draft); [onChanged] follows each change.
  final List<EntryDraft>? drafts;
  final VoidCallback? onChanged;

  /// 整條路費率 as it stands: S3b's first card, which its page may change.
  final Fee Function() fee;
  final Future<void> Function(BuildContext context)? onSpotFee;

  /// A segment's 費率 row (F1).
  final Future<void> Function(BuildContext context, EntryDraft draft)?
  onEntryFee;

  /// A new spot's 全區 or 整條路, kept with its draft; a suggestion's is
  /// judged from its entries' values ([entryWholeOf]).
  final EntryWhole? Function()? whole;
  final ValueChanged<EntryWhole>? onWhole;

  bool get adding => spot == null;
}

/// 全區 or 整條路, as a list and its pages call it.
String entryWholeName(EntryType type) => type == EntryType.zone ? '全區' : '整條路';

/// The drafts of [spot]'s entries; a street spot without segments reads as
/// one (GAP risk 7).
List<EntryDraft> draftsOf(ParkingSpot spot, EntryType type) =>
    type == EntryType.zone
    ? [for (final z in spot.zones) EntryDraft.ofZone(z)]
    : spot.segments.isEmpty
    ? [EntryDraft.ofSpot(spot)]
    : [for (final s in spot.segments) EntryDraft.ofSegment(s, spot: spot)];

/// S1b 停哪裡 and S3b 路段與格位.
class EntryListPage extends StatefulWidget {
  const EntryListPage({super.key, required this.args, this.onEntrance});
  final EntryListArgs args;

  /// S1b's 入口 row, hidden in a new spot (C5).
  final VoidCallback? onEntrance;

  @override
  State<EntryListPage> createState() => _EntryListPageState();
}

class _EntryListPageState extends State<EntryListPage> {
  EntryListArgs get args => widget.args;
  EntryType get type => args.type;
  bool get zones => type == EntryType.zone;

  late final List<EntryDraft> drafts =
      args.drafts ?? draftsOf(args.spot!, type);

  /// A new spot's as set, a suggestion's as its entries read (Z1).
  EntryWhole? get whole =>
      args.adding ? args.whole?.call() : entryWholeOf(drafts);

  /// 全區 is for a list of entries; a street without segments is one.
  bool get showsWhole =>
      args.adding || (drafts.length >= 2 && !drafts.any((d) => d.wholeSpot));

  /// Whether [d] already says something 全區 would not.
  bool _setApart(EntryDraft d) =>
      whole != null && d.stated && !whole!.matches(d);

  /// Z1 ④: 沿用全區, or how a set-apart entry differs.
  EntryTag? _wholeTag(EntryDraft d) {
    final w = whole;
    if (w == null || !d.stated || !showsWhole) return null;
    if (w.matches(d)) return EntryTag('沿用${entryWholeName(type)}');
    final name = entryWholeName(type);
    final String differs;
    if (d.scooter != w.scooter && d.heavy == w.heavy) {
      differs = '有差異：$name普機${w.scooter.label}';
    } else if (d.heavy != w.heavy && d.scooter == w.scooter) {
      differs = '有差異：$name重機${w.heavy.label}';
    } else {
      differs = '有差異';
    }
    return EntryTag(differs, tone: EntryTagTone.conditional);
  }

  /// 全區 or 整條路 (Z1): nothing goes until its page sends each entry its
  /// value.
  Future<void> _openWhole() async {
    final name = entryWholeName(type);
    final current = args.adding ? drafts : draftsOf(args.spot!, type);
    final set = await Navigator.of(context).push<EntryWhole>(
      formRoute(
        EntryWholePage(
          store: args.store,
          type: type,
          name: name,
          subtitle: args.subtitle,
          spot: args.spot,
          drafts: current,
          whole: args.adding ? args.whole?.call() : entryWholeOf(current),
          notStated: args.spot?.source == 'official',
        ),
      ),
    );
    if (set == null || !mounted) return;
    setState(() => args.onWhole?.call(set));
    args.onChanged?.call();
  }

  Widget _wholeRow() {
    final name = entryWholeName(type);
    final w = whole;
    final unit = type.unit;
    final unitName = zones ? '分區' : '路段';
    final apart = [
      for (final d in drafts)
        if (!d.removed && _setApart(d)) d,
    ].length;
    final String subtitle;
    if (w == null) {
      subtitle = '尚未設定，各$unit各自填\n一次設定普機、重機能不能停';
    } else if (drafts.isEmpty) {
      subtitle = '${w.summary}\n新增的$unitName沿用這裡，也可以在該$unit另設';
    } else {
      subtitle =
          '${w.summary}\n沒有另設的$unitName沿用$name'
          '${apart == 0 ? '' : '；另設的 $apart $unit有差異'}';
    }
    return EntryDashedCard(
      child: EntryRow(
        key: const ValueKey('entry-whole-row'),
        leading: EntryIconTile(zones ? Icons.domain : Icons.add_road),
        title: name,
        subtitle: subtitle,
        onTap: _openWhole,
      ),
    );
  }

  Future<void> open(EntryDraft? draft) async {
    if (args.adding) {
      final edit = draft?.copy() ?? EntryDraft.create(type);
      if (draft == null) {
        args.whole?.call()?.applyTo(edit);
      }
      final result = await Navigator.of(context).push<EntryEditResult>(
        formRoute(
          EntryEditPage(
            store: args.store,
            type: type,
            city: args.city,
            district: args.district,
            subtitle: args.subtitle,
            drafts: [edit],
            adding: true,
            canDelete: draft != null,
            whole: args.whole?.call(),
          ),
        ),
      );
      if (result == null || !mounted) return;
      setState(() {
        final at = draft == null ? -1 : drafts.indexOf(draft);
        if (result.delete) {
          drafts.removeAt(at);
        } else if (at < 0) {
          drafts.add(edit);
        } else {
          drafts[at] = edit;
        }
      });
      args.onChanged?.call();
      return;
    }
    // Fresh copies, so a page left without sending leaves nothing behind.
    final all = draftsOf(args.spot!, type);
    final index = draft == null ? -1 : drafts.indexOf(draft);
    await Navigator.of(context).push<void>(
      formRoute(
        EntryEditPage(
          store: args.store,
          type: type,
          city: args.city,
          district: args.district,
          subtitle: args.subtitle,
          spot: args.spot,
          drafts: all,
          openIndex: index,
        ),
      ),
    );
  }

  /// 整條路費率 in words: the rates, a spot's stored text, or 未提供.
  String get _wholeFee => wholeFeeText(args.fee(), args.spot?.feeNote);

  Widget _zoneRow(EntryDraft d) => EntryRow(
    leading: entryMarking(d.kind),
    title: d.displayName,
    subtitle: d.kind?.label,
    tags: [
      vehicleTag('普機', d.scooter, d.stored, SlotVehicle.scooter),
      vehicleTag('重機', d.heavy, d.stored, SlotVehicle.heavy),
      ?_wholeTag(d),
    ],
    onTap: d.editable ? () => open(d) : null,
  );

  Widget _segmentCard(EntryDraft d) {
    final range = [
      if (d.wholeSpot) '整個停車點' else if (d.range.isNotEmpty) d.range,
      if (d.total.isNotEmpty) '共 ${d.total} 格',
    ].join('・');
    final whole = _wholeFee;
    final fee = switch (d.fee) {
      final fee? when !fee.isEmpty => feeNoteOf(fee),
      _ => whole == '未提供' ? whole : '沿用整條路：$whole',
    };
    final onFee = args.onEntryFee;
    return EntrySection(
      rows: [
        EntryRow(
          leading: entryMarking(d.kind),
          title: d.wholeSpot
              ? (d.kind?.label ?? '整段')
              : (d.name.trim().isEmpty
                    ? (d.kind?.label ?? '路段')
                    : d.name.trim()),
          subtitle: d.wholeSpot
              ? '$range\n$firstSegmentNote'
              : range.isEmpty
              ? null
              : range,
          tags: [...segmentTags(d), ?_wholeTag(d)],
          onTap: d.editable ? () => open(d) : null,
        ),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Semantics(
            label: onFee == null
                ? '費率，目前 $fee'
                : '改${d.displayName}的費率，目前 $fee',
            child: EntryRow(
              leading: const Icon(Icons.payments_outlined),
              title: '費率',
              value: fee,
              onTap: onFee == null ? null : () => _entryFee(onFee, d),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _entryFee(
    Future<void> Function(BuildContext, EntryDraft) onFee,
    EntryDraft d,
  ) async {
    await onFee(context, d);
    if (mounted) setState(() {});
  }

  /// [drafts] by side, in the order a street reads.
  List<Widget> _bySide() {
    const order = [
      RoadSide.north,
      RoadSide.south,
      RoadSide.east,
      RoadSide.west,
      RoadSide.both,
      null,
    ];
    return [
      for (final side in order)
        if (drafts.where((d) => d.side == side).toList() case final group
            when group.isNotEmpty) ...[
          if (side != null || drafts.any((d) => d.side != null))
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 8),
              child: Semantics(
                header: true,
                child: Text(
                  side?.label ?? '其他',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 12),
          for (final (i, d) in group.indexed) ...[
            if (i > 0) const SizedBox(height: 8),
            _segmentCard(d),
          ],
        ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final spot = args.spot;
    final whole = _wholeFee;
    return FormPage(
      header: FormHeader(
        title: zones ? '停哪裡' : '路段與格位',
        subtitle: args.subtitle,
        leading: FormHeaderLeading.back,
      ),
      children: [
        Text(
          zones
              ? (args.adding
                    ? '每區各自有格位、可停車種和指引。全區先設好，新增的分區會沿用。'
                    : showsWhole
                    ? '要改哪一區？每區各自有格位、可停車種和指引；一起改就按「全區」。'
                    : '要改哪一區？每區各自有格位、可停車種和指引。')
              : '同一側可能有不同格位、不同費率，一段一段分開記。'
                    '${showsWhole ? '整條路一起改就按「整條路」。' : ''}'
                    '點路段改格位、格數和可停車種，'
                    '點下方「費率」另設那段的費率；沒另設的段用整條路費率。',
          style: TextStyle(color: colors.onSurface),
        ),
        const SizedBox(height: 12),
        if (zones) ...[
          if (widget.onEntrance != null && spot != null) ...[
            EntrySection(
              rows: [
                EntryRow(
                  leading: const EntryIconTile(Icons.login),
                  title: '入口',
                  subtitle: spot.entranceNote.isEmpty
                      ? '未填'
                      : spot.entranceNote,
                  onTap: widget.onEntrance,
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
          for (final d in drafts) ...[
            EntrySection(rows: [_zoneRow(d)]),
            const SizedBox(height: 8),
          ],
          if (showsWhole) ...[_wholeRow(), const SizedBox(height: 8)],
        ] else ...[
          // Above the road's rates (Z1 ⑦).
          if (showsWhole) ...[_wholeRow(), const SizedBox(height: 8)],
          Semantics(
            label: '改整條路費率，目前 $whole',
            child: EntrySection(
              rows: [
                EntryRow(
                  leading: const EntryIconTile(Icons.add_road),
                  title: '整條路費率',
                  subtitle: '$whole\n沒有另設費率的路段用整條路費率',
                  onTap: args.onSpotFee == null
                      ? null
                      : () async {
                          await args.onSpotFee!(context);
                          if (mounted) setState(() {});
                        },
                ),
              ],
            ),
          ),
          ..._bySide(),
          const SizedBox(height: 12),
        ],
        AddEntryButton(
          label: drafts.length >= type.maxEntries
              ? '最多 ${type.maxEntries} ${zones ? '區' : '段'}'
              : '新增一${type.unit}',
          onPressed: drafts.length >= type.maxEntries ? null : () => open(null),
        ),
        const SizedBox(height: 12),
        if (zones && !args.adding)
          const FormInfoNote(
            icon: Icons.info_outline,
            text: '整區都不存在了，進該區選「這區已撤除」；整個停車點不能停，回上一頁選「這裡已經不能停車」。',
          ),
        if (!zones)
          FormInfoNote(
            icon: Icons.info_outline,
            text:
                '每一段各自有格位、格數和費率。'
                '${args.city == null ? '' : '可停車種依${args.city}規則帶入建議，現場不同可在該段裡改。'}',
          ),
      ],
    );
  }
}

/// What a new spot's edit page hands back: the draft it edited, or that the
/// rider took the entry out.
class EntryEditResult {
  const EntryEditResult({this.delete = false});
  final bool delete;
}

/// The suggestion of [drafts] for [spot] (C6): one line per change, and the
/// patch of the entries changed.
Map<String, Object?> entriesSuggestionBody(
  EntryType type,
  ParkingSpot spot,
  List<EntryDraft> drafts,
) {
  final lines = [
    for (final d in drafts)
      if (entrySent(d, drafts))
        for (final l in entryLines(d, drafts))
          '${d.displayName} ${l.label}：${l.from} → ${l.to}',
  ];
  return {
    'action': 'flag',
    'source_id': spot.id,
    'reason': reportSummary(
      '${type == EntryType.zone ? '分區與格位' : '路段與格位'}：${lines.join('；')}',
    ),
    'field': type.field,
    'proposed': {type.key: entriesPatchOf(drafts, spotFee: spot.fee)},
  };
}

/// Z1 ②③⑧ 全區 or 整條路: who may park, set once for every entry not set
/// apart; entries set apart change only with the 開關 on. Nothing about
/// 全區 is stored: a suggestion sends each changed entry's own value, a new
/// spot's page writes into its drafts (#408).
class EntryWholePage extends StatefulWidget {
  const EntryWholePage({
    super.key,
    required this.store,
    required this.type,
    required this.name,
    required this.subtitle,
    required this.drafts,
    required this.whole,
    required this.notStated,
    this.spot,
  });
  final AppStore store;
  final EntryType type;

  /// 全區 or 整條路.
  final String name;
  final String subtitle;

  /// A suggestion's fresh copies, or a new spot's drafts.
  final List<EntryDraft> drafts;

  /// The value before this edit; null when it is not set.
  final EntryWhole? whole;

  /// Whether 官方未標示 is offered: an official spot's (#408).
  final bool notStated;

  /// The spot a suggestion is about; null in a new spot.
  final ParkingSpot? spot;

  @override
  State<EntryWholePage> createState() => _EntryWholePageState();
}

class _EntryWholePageState extends State<EntryWholePage> {
  late Eligible? scooter = _offered(widget.whole?.scooter);
  late Eligible? heavy = _offered(widget.whole?.heavy);

  /// 另設的 N 區也一起改: off unless the rider says.
  bool overwrite = false;
  bool sending = false;
  String? refusal;

  Eligible? _offered(Eligible? value) =>
      value == Eligible.notStated && !widget.notStated ? null : value;

  bool get adding => widget.spot == null;
  String get unit => widget.type.unit;

  /// The entries this page may change.
  List<EntryDraft> get _entries => [
    for (final d in widget.drafts)
      if (!d.removed && d.editable) d,
  ];

  /// Those set apart: changed only with the 開關 on.
  List<EntryDraft> get _apart => [
    for (final d in _entries)
      if (!entryFollows(d, widget.whole)) d,
  ];

  EntryWhole? get _chosen =>
      scooter != null && heavy != null ? EntryWhole(scooter!, heavy!) : null;

  bool _willChange(EntryDraft d) => entryFollows(d, widget.whole) || overwrite;

  /// The drafts with the value applied: copies, or [EntryWholePage.drafts]
  /// themselves when a new spot's page is done.
  List<EntryDraft> _applied({bool inPlace = false}) {
    final chosen = _chosen!;
    final all = inPlace
        ? widget.drafts
        : [for (final d in widget.drafts) d.copy()];
    for (final (i, d) in all.indexed) {
      final original = widget.drafts[i];
      if (original.removed || !original.editable) continue;
      if (_willChange(original)) chosen.applyTo(d);
    }
    return all;
  }

  /// How many entries the suggestion changes.
  int get _changes {
    if (_chosen == null) return 0;
    final drafts = _applied();
    return [
      for (final d in drafts)
        if (entrySent(d, drafts)) d,
    ].length;
  }

  Future<void> _submit() async {
    if (adding) {
      _applied(inPlace: true);
      Navigator.of(context).pop(_chosen);
      return;
    }
    final drafts = _applied();
    final payload = entriesSuggestionBody(widget.type, widget.spot!, drafts);
    final blocking = precheckBlocking(
      precheck(
        payload,
        current: {
          widget.type.key: [for (final d in drafts) ?d.original],
        },
      ),
    );
    if (blocking.firstOrNull case final issue?) {
      setState(() => refusal = issue.message);
      return;
    }
    setState(() => sending = true);
    final sent = await sendSuggestion(context, widget.store, payload);
    if (!mounted) return;
    setState(() => sending = false);
    if (!sent) return;
    closeFlow(context);
    showMessage(
      context,
      widget.store.demo ? '範例模式：建議沒有實際送出，只用來測試流程。' : '建議已送出。管理員審核通過後會更新地圖。',
    );
  }

  /// What 這次會影響 says of [d]: 沿用, 另設, or a heavy bay's limit.
  String _effect(EntryDraft d) {
    final chosen = _chosen;
    final kept =
        chosen != null &&
        d.kind == SpaceKind.heavy &&
        chosen.scooter == Eligible.allowed;
    if (entryFollows(d, widget.whole)) {
      return kept ? '重機專用格，普機不會改' : '沿用${widget.name}';
    }
    if (!overwrite) return '已另設，不會改';
    return kept ? '會一起改，重機專用格普機不會改' : '會一起改成${widget.name}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final name = widget.name;
    final entries = _entries;
    final apart = _apart;
    final count = _changes;
    final parent = widget.type == EntryType.zone ? '停哪裡' : '路段與格位';
    final unitName = widget.type == EntryType.zone ? '分區' : '路段';
    return FormPage(
      header: FormHeader(
        title: name,
        subtitle: '$parent・${widget.subtitle}',
        leading: FormHeaderLeading.back,
      ),
      footer: SubmitBar(
        label: adding ? '完成' : '送出 $count 項建議',
        note: adding ? null : '管理員審核後才會更新地圖',
        sending: sending,
        onPressed: adding
            ? (_chosen == null ? null : _submit)
            : count == 0
            ? null
            : _submit,
      ),
      children: [
        Text('一次設定普通機車、大型重機能不能停。沒有另設的$unitName沿用這裡。'),
        const SizedBox(height: 12),
        EligibilitySegments(
          vehicle: VehicleType.scooter,
          value: scooter,
          notStated: widget.notStated,
          keyPrefix: 'whole-scooter',
          onChanged: (v) => setState(() {
            scooter = v;
            refusal = null;
          }),
        ),
        const SizedBox(height: 10),
        EligibilitySegments(
          vehicle: VehicleType.heavy,
          value: heavy,
          notStated: widget.notStated,
          keyPrefix: 'whole-heavy',
          onChanged: (v) => setState(() {
            heavy = v;
            refusal = null;
          }),
        ),
        const SizedBox(height: 8),
        Text(
          '現場有告示牌或地面標字時，才選「可停」。',
          style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
        ),
        if (entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          const FormLabel('這次會影響'),
          const SizedBox(height: 6),
          EntrySection(
            rows: [
              for (final d in entries)
                EntryRow(
                  key: ObjectKey(d),
                  title: d.displayName,
                  value: _effect(d),
                ),
            ],
          ),
        ],
        if (apart.isNotEmpty) ...[
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            key: const ValueKey('whole-overwrite'),
            contentPadding: EdgeInsets.zero,
            value: overwrite,
            title: Text('另設的 ${apart.length} $unit也一起改成$name'),
            subtitle: const Text('打開後，已另設的內容也會改成這裡的設定。'),
            onChanged: (v) => setState(() {
              overwrite = v;
              refusal = null;
            }),
          ),
        ],
        if (refusal != null) ...[
          const SizedBox(height: 12),
          FormInfoNote(
            icon: Icons.error_outline,
            text: refusal!,
            tone: FormNoteTone.error,
          ),
        ],
      ],
    );
  }
}

/// Why [draft] cannot go as it stands, by field; empty when it can.
Map<String, String> entryProblems(EntryDraft draft) {
  final zone = draft.type == EntryType.zone;
  final name = draft.name.trim();
  final street = !zone;
  bool missing(Eligible? v) => v == null || (street && v == Eligible.notStated);
  final total = draft.total.trim();
  final count = int.tryParse(total);
  return {
    if (zone && draft.isNew && name.isEmpty) 'name': '請填寫分區名稱，或刪除此分區',
    'name': ?textHint(
      name,
      zone ? zoneNameMaxLength : segmentNameMaxLength,
      name: true,
    ),
    if (draft.kind == null) 'kind': '請選地面畫的格位',
    if (missing(draft.scooter)) 'scooter': '請選擇普通機車能不能停',
    if (missing(draft.heavy)) 'heavy': '請選擇大型重機能不能停',
    'bay': ?bayAllowProblem(draft.kind, draft.scooter),
    'guide': ?textHint(draft.guide, draft.type.guideMax),
    if (draft.range.length > segmentRangeMaxLength)
      'range': '「從」和「到」合起來最多 $segmentRangeMaxLength 個字元'
    else
      'range': ?textHint(draft.range, segmentRangeMaxLength),
    if (total.isNotEmpty &&
        (count == null ||
            count < segmentTotalRange.$1 ||
            count > segmentTotalRange.$2))
      'total': '請填 ${segmentTotalRange.$1} 到 ${segmentTotalRange.$2}',
    'evidence': ?evidenceUrlHint(draft.evidence),
  };
}

/// S2 分區與格位 and S4 路段與格位. A suggestion edits every entry here and
/// sends what changed, one item per line; a new spot's page edits one entry
/// and hands it back ([adding], C14).
class EntryEditPage extends StatefulWidget {
  const EntryEditPage({
    super.key,
    required this.store,
    required this.type,
    required this.city,
    required this.subtitle,
    required this.drafts,
    this.district = '',
    this.spot,
    this.openIndex = 0,
    this.adding = false,
    this.canDelete = false,
    this.whole,
  });
  final AppStore store;
  final EntryType type;
  final String? city;
  final String district;
  final String subtitle;
  final List<EntryDraft> drafts;

  /// The spot a suggestion is about.
  final ParkingSpot? spot;

  /// A new spot's 全區 or 整條路; a suggestion's reads from [drafts].
  final EntryWhole? whole;

  /// Which entry opens; negative starts a new one.
  final int openIndex;
  final bool adding;

  /// Whether a new spot's entry already exists, so it can be taken out.
  final bool canDelete;

  @override
  State<EntryEditPage> createState() => _EntryEditPageState();
}

class _EntryEditPageState extends State<EntryEditPage> {
  late final drafts = widget.drafts;
  late EntryDraft current;
  bool showErrors = false, sending = false;
  String? refusal;
  final linkForm = GlobalKey<FormState>();

  bool get adding => widget.adding;
  bool get zones => widget.type == EntryType.zone;
  String get unit => widget.type.unit;

  /// 全區 or 整條路: a new spot's as set, a suggestion's as its entries read
  /// when the page opened, so it stays put while one of them is edited.
  late final EntryWhole? whole =
      widget.whole ??
      (adding || drafts.length < 2 || drafts.any((d) => d.wholeSpot)
          ? null
          : entryWholeOf(drafts));

  @override
  void initState() {
    super.initState();
    if (widget.openIndex < 0) {
      current = EntryDraft.create(widget.type);
      whole?.applyTo(current);
      drafts.add(current);
    } else {
      current = drafts[widget.openIndex];
    }
  }

  void update(VoidCallback change) => setState(() {
    change();
    refusal = null;
  });

  void add() => update(() {
    current = EntryDraft.create(widget.type);
    whole?.applyTo(current);
    drafts.add(current);
    showErrors = false;
  });

  /// Takes a new entry out: from a new spot's list, or from this page.
  void delete() {
    if (adding) {
      Navigator.of(context).pop(const EntryEditResult(delete: true));
      return;
    }
    drafts.remove(current);
    if (drafts.isEmpty) {
      Navigator.of(context).pop();
    } else {
      update(() => current = drafts.first);
    }
  }

  /// The entries that go: those changed.
  List<EntryDraft> get changed => [
    for (final d in drafts)
      if (entrySent(d, drafts)) d,
  ];

  int get items => changed.fold(0, (n, d) => n + entryLines(d, drafts).length);

  Map<String, Object?> body() =>
      entriesSuggestionBody(widget.type, widget.spot!, drafts);

  /// Opens the first changed entry that cannot go and says why.
  bool check() {
    final list = adding ? [current] : changed;
    for (final d in list) {
      final problems = entryProblems(d);
      if (!d.removed && problems.isNotEmpty) {
        setState(() {
          current = d;
          showErrors = true;
        });
        // The link says its own error; alone, it is what to scroll to.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (problems.keys.first == 'evidence') {
            SuggestionLink.check(linkForm);
          } else {
            linkForm.currentState?.validate();
          }
        });
        return false;
      }
    }
    return true;
  }

  Future<void> submit() async {
    if (!check()) return;
    final payload = body();
    final blocking = precheckBlocking(
      precheck(
        payload,
        current: {
          widget.type.key: [for (final d in drafts) ?d.original],
        },
      ),
    );
    if (blocking.firstOrNull case final issue?) {
      setState(() => refusal = issue.message);
      return;
    }
    setState(() => sending = true);
    final sent = await sendSuggestion(context, widget.store, payload);
    if (!mounted) return;
    setState(() => sending = false);
    if (!sent) return;
    closeFlow(context);
    showMessage(
      context,
      widget.store.demo ? '範例模式：建議沒有實際送出，只用來測試流程。' : '建議已送出。管理員審核通過後會更新地圖。',
    );
  }

  /// 地圖上目前寫的, from what was loaded: it stays put while the rider
  /// edits. Null with nothing on the map yet.
  String? get mapNote {
    if (zones) {
      final all = [
        for (final d in drafts)
          if (!d.isNew) d.storedLabel,
      ];
      return all.isEmpty ? null : '地圖上目前寫的：${all.join('、')}。改你確定的那一區就好。';
    }
    final detail = current.storedDetail;
    return detail.isEmpty ? null : '地圖上目前寫的：$detail。改你確定的就好。';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final others = adding
        ? const <EntryDraft>[]
        : [
            for (final d in drafts)
              if (!identical(d, current)) d,
          ];
    final pending = changed;
    final count = items;
    final full = drafts.length >= widget.type.maxEntries;
    return FormPage(
      header: FormHeader(
        title: zones ? '分區與格位' : current.displayName,
        subtitle: '停哪裡・${widget.subtitle}',
        leading: FormHeaderLeading.back,
      ),
      footer: SubmitBar(
        label: adding ? '完成' : '送出 $count 項建議',
        note: adding ? null : '管理員審核後才會更新地圖',
        sending: sending,
        onPressed: adding
            ? () {
                if (check()) {
                  Navigator.of(context).pop(const EntryEditResult());
                }
              }
            : count == 0
            ? null
            : submit,
      ),
      children: [
        if (mapNote case final note? when !adding) ...[
          FormInfoNote(icon: Icons.map_outlined, text: note),
          const SizedBox(height: 12),
        ],
        _EntryCard(
          key: ObjectKey(current),
          draft: current,
          adding: adding,
          canDelete: widget.canDelete,
          city: widget.city,
          district: widget.district,
          rules: widget.store.rules,
          showErrors: showErrors,
          linkForm: linkForm,
          onChanged: update,
          onDelete: delete,
          whole: whole,
          wholeName: entryWholeName(widget.type),
        ),
        for (final d in others) ...[
          const SizedBox(height: 8),
          EntrySection(
            rows: [
              EntryRow(
                title: d.rowLabel,
                value: d.removed
                    ? '將撤除'
                    : entrySent(d, drafts)
                    ? '已修改'
                    : '沒有改',
                onTap: d.editable
                    ? () => setState(() {
                        current = d;
                        showErrors = false;
                      })
                    : null,
              ),
            ],
          ),
        ],
        if (!adding) ...[
          const SizedBox(height: 8),
          AddEntryButton(
            label: full ? '最多 ${widget.type.maxEntries} $unit' : '新增一$unit',
            onPressed: full ? null : add,
          ),
        ],
        if (!adding && pending.isNotEmpty) ...[
          const SizedBox(height: 16),
          Divider(color: colors.outlineVariant),
          const SizedBox(height: 8),
          const FormLabel('你要改的內容'),
          for (final d in pending)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ChangeSummary(
                title: d.displayName,
                lines: entryLines(d, drafts),
              ),
            ),
        ],
        if (refusal != null) ...[
          const SizedBox(height: 12),
          FormInfoNote(
            icon: Icons.error_outline,
            text: refusal!,
            tone: FormNoteTone.error,
          ),
        ],
      ],
    );
  }
}

/// The open entry: S2's and S4's card.
class _EntryCard extends StatefulWidget {
  const _EntryCard({
    super.key,
    required this.draft,
    required this.adding,
    required this.canDelete,
    required this.city,
    required this.district,
    required this.rules,
    required this.showErrors,
    required this.linkForm,
    required this.onChanged,
    required this.onDelete,
    this.whole,
    this.wholeName = '全區',
  });
  final GlobalKey<FormState> linkForm;
  final EntryDraft draft;
  final bool adding, canDelete, showErrors;
  final String? city;
  final String district;
  final List<CityRule> rules;
  final ValueChanged<VoidCallback> onChanged;
  final VoidCallback onDelete;

  /// 全區 or 整條路, when there is one (Z1 ⑤⑥).
  final EntryWhole? whole;
  final String wholeName;

  @override
  State<_EntryCard> createState() => _EntryCardState();
}

class _EntryCardState extends State<_EntryCard> {
  EntryDraft get d => widget.draft;
  bool get zone => d.type == EntryType.zone;

  /// The vehicles are this entry's own, not 全區's (Z1 ⑥).
  late bool setApart =
      widget.whole == null ||
      !widget.whole!.matches(d) ||
      // A segment cannot show 官方未標示 read-only: it asks 可停 or 不可停.
      (!zone &&
          (widget.whole!.scooter == Eligible.notStated ||
              widget.whole!.heavy == Eligible.notStated));
  late final name = TextEditingController(text: d.name);
  late final from = TextEditingController(text: d.from);
  late final to = TextEditingController(text: d.to);
  late final total = TextEditingController(text: d.total);
  late final guide = TextEditingController(text: d.guide);
  late final evidence = TextEditingController(text: d.evidence);

  @override
  void dispose() {
    for (final c in [name, from, to, total, guide, evidence]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A city's suggestion for this bay, in words; null when it has none.
  String? get suggestion {
    final kind = d.kind;
    if (zone || kind == null) return null;
    final words = baySuggestion(
      widget.rules,
      kind,
      widget.city,
      district: widget.district,
    );
    if (words == null) return null;
    final filled = d.isNew && !d.vehiclesEdited;
    return '$words。${filled ? '已先帶入，' : ''}現場不同再改。';
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final errors = widget.showErrors
        ? entryProblems(d)
        : const <String, String>{};
    final unit = d.type.unit;
    final removed = d.removed;
    Widget gap([double h = 14]) => SizedBox(height: h);
    InputDecoration field(String label, {String? hint, String? error}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: error,
          errorMaxLines: 4,
          counterText: '',
          alignLabelWithHint: true,
        );
    final sideField = DropdownButtonFormField<RoadSide?>(
      key: const ValueKey('entry-side'),
      initialValue: d.side,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '哪一側'),
      items: [
        const DropdownMenuItem(child: Text('未選')),
        for (final side in RoadSide.values)
          DropdownMenuItem(value: side, child: Text(side.label)),
      ],
      onChanged: (v) => widget.onChanged(() => d.side = v),
    );
    final nameField = TextField(
      key: const ValueKey('entry-name'),
      controller: name,
      maxLength: segmentNameMaxLength,
      decoration: field('路段名稱（選填）', hint: '例：靠松江路口', error: errors['name']),
      onChanged: (v) => widget.onChanged(() => d.name = v),
    );
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: brand, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  zone ? (d.isNew ? '新的分區' : d.displayName) : '這一$unit',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // C14: nothing is being changed in a spot not yet sent.
              if (!widget.adding)
                Text(
                  removed ? '將撤除' : '修改中',
                  style: TextStyle(
                    fontSize: 13,
                    color: removed ? colors.error : colors.primary,
                  ),
                ),
            ],
          ),
          gap(10),
          if (removed) ...[
            Text(
              '送出後由管理員確認，再從地圖移除。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ] else ...[
            if (zone && d.isNew) ...[
              TextField(
                key: const ValueKey('entry-name'),
                controller: name,
                maxLength: zoneNameMaxLength,
                decoration: field(
                  '分區名稱',
                  hint: '例：B2 機車區',
                  error: errors['name'],
                ),
                onChanged: (v) => widget.onChanged(() => d.name = v),
              ),
              gap(),
            ],
            if (!zone) ...[
              LayoutBuilder(
                builder: (context, box) => box.maxWidth < 280
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [sideField, gap(10), nameField],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: sideField),
                          const SizedBox(width: 10),
                          Expanded(child: nameField),
                        ],
                      ),
              ),
              gap(10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('entry-from'),
                      controller: from,
                      decoration: field('從', error: errors['range']),
                      onChanged: (v) => widget.onChanged(() => d.from = v),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      key: const ValueKey('entry-to'),
                      controller: to,
                      decoration: field('到'),
                      onChanged: (v) => widget.onChanged(() => d.to = v),
                    ),
                  ),
                ],
              ),
              gap(),
            ],
            const FormLabel('地面畫的是哪一種格位？'),
            gap(8),
            BayKindGrid(
              value: d.kind,
              onChanged: (v) => widget.onChanged(() {
                d.kind = v;
                if (!zone) {
                  d.applyDefaults(
                    widget.rules,
                    widget.city,
                    district: widget.district,
                  );
                }
              }),
            ),
            if (errors['kind'] case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  error,
                  style: TextStyle(fontSize: 13, color: colors.error),
                ),
              ),
            if (!zone) ...[
              gap(),
              FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: .5,
                child: TextField(
                  key: const ValueKey('entry-total'),
                  controller: total,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: field('共幾格（選填）', error: errors['total']),
                  onChanged: (v) => widget.onChanged(() => d.total = v),
                ),
              ),
            ],
            gap(),
            FormLabel(
              '哪些車種可停？',
              aside: widget.adding ? '兩種車都要選' : '改這一$unit時兩種車都要選',
            ),
            gap(8),
            if (suggestion case final text?) ...[
              FormInfoNote(
                icon: Icons.rule,
                text: text,
                tone: FormNoteTone.warning,
              ),
              gap(8),
            ],
            if (widget.whole case final whole? when !setApart) ...[
              // Z1 ⑤: follows 全區 until the rider sets it apart here.
              FormInfoNote(
                key: const ValueKey('entry-follows-whole'),
                icon: Icons.link,
                text: '沿用${widget.wholeName}：${whole.summary}',
              ),
              gap(8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton(
                  key: const ValueKey('entry-set-apart'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: () => setState(() => setApart = true),
                  child: Text('在這一$unit另設'),
                ),
              ),
              gap(8),
              Text(
                '格位、指引等其他項目不受${widget.wholeName}影響。',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ] else ...[
              if (widget.whole != null &&
                  d.stated &&
                  !widget.whole!.matches(d)) ...[
                FormInfoNote(
                  key: const ValueKey('entry-set-apart-note'),
                  icon: Icons.tune,
                  text: '另設中，和${widget.wholeName}不同',
                  tone: FormNoteTone.warning,
                ),
                gap(8),
              ],
              LayoutBuilder(
                builder: (context, box) {
                  final scooter = EligibilitySegments(
                    vehicle: VehicleType.scooter,
                    value: d.scooter,
                    notStated: zone,
                    error: errors['scooter'],
                    keyPrefix: 'entry-scooter',
                    onChanged: (v) => widget.onChanged(() {
                      d.scooter = v;
                      d.vehiclesEdited = true;
                    }),
                  );
                  final heavy = EligibilitySegments(
                    vehicle: VehicleType.heavy,
                    value: d.heavy,
                    notStated: zone,
                    error: errors['heavy'],
                    keyPrefix: 'entry-heavy',
                    onChanged: (v) => widget.onChanged(() {
                      d.heavy = v;
                      d.vehiclesEdited = true;
                    }),
                  );
                  // A street bay's two choices fit side by side (S4); a lot's
                  // three, narrow screens and large text do not.
                  final wide =
                      !zone &&
                      box.maxWidth >= 300 &&
                      MediaQuery.textScalerOf(context).scale(16) <= 20;
                  return wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: scooter),
                            const SizedBox(width: 10),
                            Expanded(child: heavy),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [scooter, gap(10), heavy],
                        );
                },
              ),
              // Before sending too: the pick cannot go as it stands.
              if (bayAllowProblem(d.kind, d.scooter) case final error?) ...[
                gap(8),
                FormInfoNote(
                  key: const ValueKey('entry-bay-problem'),
                  icon: Icons.error_outline,
                  text: error,
                  tone: FormNoteTone.error,
                ),
              ],
              if (widget.whole case final whole?) ...[
                gap(8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const ValueKey('entry-back-to-whole'),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => widget.onChanged(() {
                      whole.applyTo(d);
                      setApart = false;
                    }),
                    child: Text('改回沿用${widget.wholeName}'),
                  ),
                ),
                gap(4),
                Text(
                  '${widget.wholeName}目前：${whole.summary}。這一$unit的內容不會因為改${widget.wholeName}而變。',
                  style: TextStyle(
                    fontSize: 13,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            gap(8),
            if (zone)
              Text(
                '現場有告示牌或地面標字時才選「可停」；停車場與營運業者都沒寫，選「官方未標示」。',
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              )
            else
              const FormInfoNote(
                icon: Icons.fact_check_outlined,
                text: '費率在「怎麼算錢」改，共用格的開放時段在「限時／禁停／共用時段」改。',
              ),
            gap(),
            TextField(
              key: const ValueKey('entry-guide'),
              controller: guide,
              maxLength: d.type.guideMax,
              maxLines: 2,
              decoration: field(
                zone ? '怎麼停到這一區' : '怎麼找到這段格位',
                error: errors['guide'],
              ),
              onChanged: (v) => widget.onChanged(() => d.guide = v),
            ),
            gap(),
            SuggestionLink(
              form: widget.linkForm,
              controller: evidence,
              field: EvidenceUrlField(
                controller: evidence,
                onChanged: (v) => widget.onChanged(() => d.evidence = v),
              ),
            ),
          ],
          if (!widget.adding && !d.isNew) ...[
            gap(),
            RemoveEntryButton(
              label: removed ? '取消撤除' : '這$unit已撤除',
              note: removed
                  ? null
                  : zone
                  ? '整區格線撤除或改作他用才選；送出後由管理員確認再從地圖移除'
                  : '整段格線撤除才選；送出後由管理員確認再從地圖移除',
              onPressed: () => widget.onChanged(() => d.removed = !removed),
            ),
          ],
          if (widget.canDelete ||
              (!widget.adding && d.isNew && !d.wholeSpot)) ...[
            gap(),
            RemoveEntryButton(
              label: '刪除這一$unit',
              icon: Icons.delete_outline,
              onPressed: widget.onDelete,
            ),
          ],
        ],
      ),
    );
  }
}

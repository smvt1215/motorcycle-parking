// F0 and F1: a spot's rates, whole or by zone or segment. From a suggestion
// F1 sends its own patch (C6); from a new spot 完成 hands the rates back and
// N1 sends them together (C14). F2 is F1's 更多收費規則, in the shared editor.
import '../../data/app_store.dart';
import '../../domain/eligibility.dart';
import '../../domain/precheck.dart';
import '../../domain/segment_decision.dart';
import '../../models/fee.dart';
import '../../models/holiday_calendar.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_editor.dart';
import 'entry_drafts.dart';
import 'entry_pages.dart';
import 'fee_suggestion.dart';
import 'form_parts.dart';
import 'spot_suggestions.dart' show reportSummary;

/// [fee]'s [v] in a few words for F0's tags: 20/時・上限 100, 不適用, 未提供.
String rateBrief(Fee fee, FeeVehicle v) {
  var rate = rateOf(fee, v);
  if (rate?.mode == FeeMode.sameAsScooter) rate = fee.scooter;
  if (rate?.mode == FeeMode.sameAsCar) rate = fee.car;
  if (rate == null) return '未提供';
  return switch (rate.mode) {
    FeeMode.notApplicable => '不適用',
    FeeMode.free => '免費',
    FeeMode.hourly => [
      '${FeeWords.money(rate.amount)}/${rate.perMinutes == 60 ? '時' : '${rate.perMinutes}分'}',
      if (rate.dailyCap case final cap?) '上限 ${FeeWords.money(cap)}',
    ].join('・'),
    FeeMode.perVisit => '${FeeWords.money(rate.amount)}/次',
    FeeMode.byTime => '依時段',
    _ => '未提供',
  };
}

const _shortNames = {
  FeeVehicle.scooter: '普機',
  FeeVehicle.heavy: '重機',
  FeeVehicle.car: '汽車',
};

/// A vehicle's tag on F0: three on every row, 汽車 未提供 too (C10).
EntryTag feeTag(Fee fee, FeeVehicle v) {
  final brief = rateBrief(fee, v);
  return EntryTag(
    '${_shortNames[v]} $brief',
    tone: switch (brief) {
      '不適用' => EntryTagTone.denied,
      '未提供' => EntryTagTone.unknown,
      _ => EntryTagTone.neutral,
    },
  );
}

/// Why each vehicle does not apply to [d]'s bay.
Map<FeeVehicle, String> whyNotApplicable(EntryDraft d) {
  final bay = d.kind?.label;
  final named = bay == null ? '' : '$bay，';
  return {
    if (d.kind == SpaceKind.heavy || d.scooter == Eligible.notAllowed)
      FeeVehicle.scooter: '$named普通機車不能停',
    if (d.heavy == Eligible.notAllowed) FeeVehicle.heavy: '$named大型重機不能停',
    if (d.kind != null &&
        !const {
          SpaceKind.car,
          SpaceKind.carMotorcycle,
          SpaceKind.disabled,
        }.contains(d.kind))
      FeeVehicle.car: '這${d.type.unit}沒有汽車格',
  };
}

/// What F1 starts from for [d]: its own rates, else the spot's with the
/// vehicles its bay has no room for marked 不適用, as a fee written whole
/// must (#188 layer 2).
Fee startFee(EntryDraft d, Fee spot) {
  if (d.fee case final own? when !own.isEmpty) return own;
  final why = whyNotApplicable(d);
  Rate? rate(FeeVehicle v) =>
      why.containsKey(v) ? const Rate(FeeMode.notApplicable) : rateOf(spot, v);
  return Fee(
    scooter: rate(FeeVehicle.scooter),
    heavy: rate(FeeVehicle.heavy),
    car: rate(FeeVehicle.car),
  );
}

/// When [vehicle] cannot park under [c] over a plain week, read from
/// [openWindow] so it matches the map (C7). Weekends stand for 假日.
FeeClosedWeek closedWeek(
  ParkingCondition? c,
  VehicleType vehicle, {
  required bool street,
  List<CityRule> rules = const [],
  String district = '',
}) => [
  for (var day = 0; day < 7; day++)
    () {
      // A Monday in Taiwan, UTC+8 all year.
      final midnight = DateTime.utc(2026, 1, 5 + day, -8);
      final spans = <(int, int)>[];
      var at = 0;
      while (at < 1440) {
        final w = openWindow(
          EligibilityStatus.allowed,
          c,
          vehicle,
          midnight.add(Duration(minutes: at)),
          street: street,
          calendar: HolidayCalendar.none,
          rules: rules,
          district: district,
        );
        if (w.now) {
          final end = w.untilMinute;
          if (end == null || end <= at) break;
          at = end;
        } else {
          final open = w.opensAtMinute;
          final end = open == null || open > 1440 ? 1440 : open;
          if (end <= at) break;
          spans.add((at, end));
          at = end;
        }
      }
      return spans;
    }(),
];

/// The closed hours F1 greys for [drafts], by vehicle: those every entry
/// open to it shares; none when they differ or nothing is closed (C7).
Map<FeeVehicle, FeeClosedWeek> closedFor(
  List<EntryDraft> drafts, {
  required bool street,
  required AppStore store,
  String district = '',
}) {
  FeeClosedWeek? shared(
    VehicleType vehicle,
    Eligible? Function(EntryDraft) of,
  ) {
    final weeks = [
      for (final d in drafts)
        if (of(d) != Eligible.notAllowed)
          closedWeek(
            d.condition,
            vehicle,
            street: street,
            rules: store.rules,
            district: district,
          ),
    ];
    if (weeks.isEmpty) return null;
    final first = weeks.first;
    if (weeks.any((w) => '$w' != '$first')) return null;
    return feeClosedText(first) == null ? null : first;
  }

  return {
    FeeVehicle.scooter: ?shared(VehicleType.scooter, (d) => d.scooter),
    FeeVehicle.heavy: ?shared(VehicleType.heavy, (d) => d.heavy),
  };
}

/// Opens F1 for what a form points at; a new spot's page gives back the
/// rates, a suggestion's sends them and closes the sheet.
Future<Fee?> openFeePage(
  BuildContext context, {
  required AppStore store,
  required String spotName,
  required EntryType type,
  required List<EntryDraft> drafts,
  required Fee spotFee,
  EntryDraft? draft,
  ParkingSpot? spot,
  String district = '',
}) => Navigator.of(context).push<Fee>(
  formRoute(
    FeeEditPage(
      store: store,
      spotName: spotName,
      type: type,
      drafts: drafts,
      spotFee: spotFee,
      draft: draft,
      spot: spot,
      district: district,
    ),
  ),
);

/// F0: a lot's rates, zone by zone, and the whole lot's.
class FeeZonesPage extends StatefulWidget {
  const FeeZonesPage({
    super.key,
    required this.store,
    required this.spotName,
    required this.drafts,
    required this.spotFee,
    required this.wholeText,
    this.spot,
    this.district = '',
    this.onSpotFee,
  });
  final AppStore store;
  final String spotName, district;

  /// The zones; a new spot's as they stand.
  final List<EntryDraft> drafts;
  final Fee Function() spotFee;

  /// 全場費率 in words, as the map reads it.
  final String Function() wholeText;

  /// The spot a suggestion is about; null in a new spot.
  final ParkingSpot? spot;

  /// A new spot keeps the rates 全場費率 gives back.
  final ValueChanged<Fee>? onSpotFee;

  @override
  State<FeeZonesPage> createState() => _FeeZonesPageState();
}

class _FeeZonesPageState extends State<FeeZonesPage> {
  bool get adding => widget.spot == null;

  Future<void> open(EntryDraft? draft) async {
    final next = await openFeePage(
      context,
      store: widget.store,
      spotName: widget.spotName,
      type: EntryType.zone,
      drafts: widget.drafts,
      spotFee: widget.spotFee(),
      draft: draft,
      spot: widget.spot,
      district: widget.district,
    );
    if (next == null || !mounted) return;
    setState(() {
      if (draft == null) {
        widget.onSpotFee?.call(next);
      } else {
        draft.fee = next;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final fee = widget.spotFee();
    final whole = widget.wholeText();
    final own = widget.drafts.any((d) => d.fee != null);
    return FormPage(
      header: FormHeader(
        title: '費率',
        subtitle: '怎麼算錢・${widget.spotName}',
        leading: FormHeaderLeading.back,
      ),
      children: [
        Text(
          '${own || whole == '未提供' ? '全場費率：' : '目前全場同價：'}$whole。'
          '${widget.drafts.isEmpty ? '' : '點一區可另設它的費率；全場一起改就按「全場費率」。'}',
        ),
        const SizedBox(height: 12),
        for (final (i, d) in widget.drafts.indexed) ...[
          EntrySection(
            key: ValueKey('fee-zone-$i'),
            rows: [
              EntryRow(
                leading: entryMarking(d.kind),
                title: d.displayName,
                subtitle: d.kind?.label,
                tags: [
                  for (final v in FeeVehicle.values) feeTag(d.fee ?? fee, v),
                ],
                onTap: d.editable ? () => open(d) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 8),
        EntrySection(
          key: const ValueKey('fee-whole'),
          rows: [
            EntryRow(
              leading: const EntryIconTile(Icons.domain),
              title: '全場費率',
              subtitle: '$whole\n沒有另設費率的分區用全場費率',
              onTap: () => open(null),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const FormInfoNote(
          icon: Icons.info_outline,
          text: '標「不適用」或沒填費率的車種，不會出現在公告牌。沒有另設費率的分區用全場費率；改了全場費率，這些分區會一起變。',
        ),
      ],
    );
  }
}

/// F1 (and F2, its 更多收費規則): one target's rates.
class FeeEditPage extends StatefulWidget {
  const FeeEditPage({
    super.key,
    required this.store,
    required this.spotName,
    required this.type,
    required this.drafts,
    required this.spotFee,
    this.draft,
    this.spot,
    this.district = '',
    this.now,
  });
  final AppStore store;
  final String spotName, district;
  final EntryType type;

  /// Every entry of the spot, whose conditions say what is closed.
  final List<EntryDraft> drafts;
  final Fee spotFee;

  /// The zone or segment; null is the whole spot.
  final EntryDraft? draft;

  /// The spot a suggestion is about; null in a new spot.
  final ParkingSpot? spot;

  /// The preview's clock (tests).
  final DateTime? now;

  @override
  State<FeeEditPage> createState() => _FeeEditPageState();
}

class _FeeEditPageState extends State<FeeEditPage> {
  final form = GlobalKey<FormState>();
  late final EntryDraft? draft = widget.draft;
  late final Fee start = draft == null
      ? widget.spotFee
      : startFee(draft!, widget.spotFee);
  late Fee fee = start;
  bool sending = false;
  String? refusal;

  bool get adding => widget.spot == null;
  bool get street => widget.type == EntryType.segment;
  String get wholeWord => street ? '整條路' : '全場';

  /// The vehicles the rider changed, one line each (C6).
  List<ChangeLine> get lines {
    String text(Fee f, FeeVehicle v) {
      final rate = rateOf(f, v);
      if (rate == null) return '未提供';
      if (rate.mode == FeeMode.notApplicable) return '不適用';
      if (!validRate(rate.toJson(), v.wire)) return '還沒填完';
      return f.textOf(v.wire) ?? '未提供';
    }

    return [
      for (final v in FeeVehicle.values)
        if (rateOf(fee, v) != rateOf(start, v))
          ChangeLine(label: v.label, from: text(start, v), to: text(fee, v)),
    ];
  }

  String get intro {
    final whole = widget.spotFee.isEmpty ? '未提供' : feeNoteOf(widget.spotFee);
    final name = draft?.displayName;
    final tail = adding ? '完成後回到新增停車點。' : '送出前還沒生效。';
    return name == null
        ? '這裡改$wholeWord費率，沒有另設費率的${widget.type.unit}會一起變。$tail'
        : '目前$wholeWord費率：$whole。這裡另設 $name 的費率，$tail';
  }

  Map<String, Object?> body() {
    final spot = widget.spot!;
    final d = draft;
    final changes = lines;
    return {
      'action': 'flag',
      'source_id': spot.id,
      'reason': reportSummary(
        '費率：${[for (final l in changes) '${l.label} ${l.from} → ${l.to}'].join('；')}',
      ),
      'field': d == null ? 'fee_note' : widget.type.field,
      'proposed': d == null
          ? feeProposal(widget.spotFee, fee)
          : {
              widget.type.key: [
                {'id': d.id, 'fee': fee.toJson()},
              ],
            },
    };
  }

  /// What the server's precheck refuses in these rates.
  String? get problem {
    if (fee.isEmpty) return null;
    final d = draft;
    if (adding || d == null) {
      final c = d?.condition.toJson();
      return precheckBlocking(
        precheckFee(
          fee.toJson(),
          condition: c,
          allow: c?['allow'] as Map<Object?, Object?>? ?? const {},
        ),
      ).firstOrNull?.message;
    }
    final spot = widget.spot!;
    return precheckBlocking(
      precheck(
        body(),
        current: {
          'fee': ?spot.fee?.toJson(),
          widget.type.key: [for (final e in widget.drafts) ?e.original],
        },
      ),
    ).firstOrNull?.message;
  }

  Future<void> submit() async {
    final d = draft;
    if (!(form.currentState?.validate() ?? false)) return;
    if (!adding && d != null && !d.stated) {
      setState(() => refusal = unstatedEntryNote(d));
      return;
    }
    if (problem case final issue?) {
      setState(() => refusal = issue);
      return;
    }
    if (adding) {
      Navigator.of(context).pop(fee);
      return;
    }
    setState(() => sending = true);
    final sent = await sendSuggestion(context, widget.store, body());
    if (!mounted) return;
    setState(() => sending = false);
    if (!sent) return;
    closeFlow(context);
    showMessage(
      context,
      widget.store.demo ? '範例模式：建議沒有實際送出，只用來測試流程。' : '建議已送出。管理員審核通過後會更新地圖。',
    );
  }

  Widget _addButton(String label, VoidCallback? onPressed) => isCupertino
      ? AddEntryButton(label: label, onPressed: onPressed)
      : OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onPressed,
          icon: const Icon(Icons.add),
          label: Text(label),
        );

  @override
  Widget build(BuildContext context) {
    final d = draft;
    final changes = lines;
    final count = changes.length;
    final subject = d == null
        ? widget.spotName
        : '${widget.spotName} ${d.displayName}';
    return Form(
      key: form,
      child: FormPage(
        header: FormHeader(
          title: '費率',
          subtitle: '怎麼算錢・$subject',
          leading: FormHeaderLeading.back,
        ),
        footer: SubmitBar(
          label: adding ? '完成' : '送出 $count 項建議',
          note: adding ? null : '管理員審核後才會更新地圖',
          sending: sending,
          onPressed: adding || count > 0 ? submit : null,
        ),
        children: [
          Text(intro),
          const SizedBox(height: 12),
          FeeEditor(
            value: fee,
            initialVehicle: FeeVehicle.of(widget.store.vehicle),
            errorText: refusal,
            onChanged: (v) => setState(() {
              fee = v;
              refusal = null;
            }),
            form: FeeFormStyle(
              original: adding ? null : start,
              why: d == null ? const {} : whyNotApplicable(d),
              closed: closedFor(
                d == null ? widget.drafts : [d],
                street: street,
                store: widget.store,
                district: widget.district,
              ),
              addButton: _addButton,
              now: widget.now,
              summary: adding || changes.isEmpty
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const FormLabel('你要改的內容'),
                        const SizedBox(height: 6),
                        ChangeSummary(lines: changes),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

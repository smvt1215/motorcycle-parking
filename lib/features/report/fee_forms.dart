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
import '../../ui/fee_board.dart' show feePeriodTime;
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

/// F0's tag for a zone with no rates of its own: 沿用全場：20/時, what it
/// pays now; 未提供 with no rates to follow (F1b).
EntryTag followTag(EntryDraft d, Fee fee) {
  final why = whyNotApplicable(d);
  final shown = [
    for (final v in FeeVehicle.values)
      if (!why.containsKey(v))
        if (rateBrief(fee, v) case final brief
            when brief != '不適用' && brief != '未提供')
          (v, brief),
  ];
  if (shown.isEmpty) {
    return const EntryTag('未提供', tone: EntryTagTone.unknown);
  }
  final same = shown.every((e) => e.$2 == shown.first.$2);
  return EntryTag(
    same
        ? '沿用全場：${shown.first.$2}'
        : '沿用全場：${[for (final (v, b) in shown) '${_shortNames[v]} $b'].join('、')}',
  );
}

/// [fee] line by line for F1b: a time-of-day rate by period, a vehicle by
/// name when more than one applies.
List<String> ownFeeLines(Fee fee) {
  final vehicles = [
    for (final v in FeeVehicle.values)
      if (fee.textOf(v.wire) != null) v,
  ];
  return [
    for (final v in vehicles)
      for (final line in _rateLines(fee, v))
        vehicles.length > 1 ? '${v.label} $line' : line,
  ];
}

List<String> _rateLines(Fee fee, FeeVehicle v) {
  final rate = rateOf(fee, v);
  if (rate?.mode != FeeMode.byTime) return [fee.textOf(v.wire)!];
  return [
    for (final p in rate!.periods ?? const <FeePeriod>[])
      '${FeeWords.dayLabel(FeeWords.dayMask(p.days))} '
          '${feePeriodTime(p.from, p.to)} '
          '${Fee(car: p.rate).textOf('car') ?? '未提供'}',
  ];
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
  // What a heavy bike follows may not apply here: it starts from the amounts.
  Rate? rate(FeeVehicle v) {
    if (why.containsKey(v)) return const Rate(FeeMode.notApplicable);
    final own = rateOf(spot, v);
    return switch (own?.mode) {
      FeeMode.sameAsScooter => spot.scooter,
      FeeMode.sameAsCar => spot.car,
      _ => own,
    };
  }

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
        // F1b gives back nothing: the zone follows the lot again.
        draft.fee = next.isEmpty ? null : next;
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
                  if (d.fee case final own?)
                    for (final v in FeeVehicle.values) feeTag(own, v)
                  else
                    followTag(d, fee),
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

  /// F1b: the rider is confirming a return to the spot's rates. What the
  /// editor holds stays, for 取消，繼續編輯.
  bool reverting = false;

  bool get adding => widget.spot == null;
  bool get street => widget.type == EntryType.segment;
  String get wholeWord => street ? '整條路' : '全場';

  /// What the entry has of its own, which F1b can take away.
  Fee? get own => switch (draft?.fee) {
    final fee? when !fee.isEmpty => fee,
    _ => null,
  };

  String get wholeText => wholeFeeText(widget.spotFee, widget.spot?.feeNote);

  /// F1b's button: 路邊沒有「全場」的說法.
  String get revertLabel => street ? '改回沿用整條路費率' : '改回沿用全場';
  String get revertTitle => street ? '將改回沿用整條路費率' : '將改回沿用全場';
  String get followWords => street ? '沿用整條路' : '沿用全場';

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

  /// The rider's vehicle, unless it has no bays here.
  FeeVehicle get firstVehicle {
    final own = FeeVehicle.of(widget.store.vehicle);
    bool applies(FeeVehicle v) => rateOf(fee, v)?.mode != FeeMode.notApplicable;
    return applies(own)
        ? own
        : FeeVehicle.values.where(applies).firstOrNull ?? own;
  }

  String get intro {
    final whole = wholeFeeText(widget.spotFee, widget.spot?.feeNote);
    final name = draft?.displayName;
    if (own != null) return '$name 目前有自己的費率；$wholeWord$whole。';
    final tail = adding ? '完成後回到新增停車點。' : '送出前還沒生效。';
    return name == null
        ? '這裡改$wholeWord費率，沒有另設費率的${widget.type.unit}會一起變。$tail'
        : '目前$wholeWord費率：$whole。這裡另設 $name 的費率，$tail';
  }

  Map<String, Object?> body() {
    final spot = widget.spot!;
    final d = draft;
    final changes = lines;
    if (reverting) {
      return {
        'action': 'flag',
        'source_id': spot.id,
        'reason': reportSummary('費率：${d!.displayName} 自訂 → $followWords'),
        'field': widget.type.field,
        'proposed': {
          widget.type.key: [
            // null clears it, its fee plan too (`entries_patch()`).
            {'id': d.id, 'fee': null},
          ],
        },
      };
    }
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
    if (fee.isEmpty || (reverting && adding)) return null;
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
    // A look at F1 leaves the entry as it was, unfilled vehicles or not.
    if (adding && !reverting && lines.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    if (!reverting && !(form.currentState?.validate() ?? false)) return;
    if (!adding && d != null && !d.stated) {
      setState(() => refusal = unstatedEntryNote(d));
      return;
    }
    if (problem case final issue?) {
      setState(() => refusal = issue);
      return;
    }
    if (adding) {
      // An empty fee: 這一區不帶費率.
      Navigator.of(context).pop(reverting ? const Fee() : fee);
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

  /// F1b ② to ⑤: what the entry pays now, what it would follow.
  Widget _confirm(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    final whole = wholeText;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Read out first when the page turns to this.
        Semantics(
          key: const ValueKey('fee-revert-confirm'),
          container: true,
          liveRegion: true,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border: Border.all(color: brand, width: 1.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const ExcludeSemantics(
                      child: Icon(Icons.undo, size: 22, color: brand),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        revertTitle,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('目前自己的費率', style: muted),
                const SizedBox(height: 4),
                Text(
                  ownFeeLines(own!).join('；\n'),
                  style: TextStyle(
                    fontSize: 15,
                    height: 1.5,
                    color: colors.onSurfaceVariant,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(height: 12),
                Text('$wholeWord費率', style: muted),
                const SizedBox(height: 4),
                Text(
                  whole == '未提供' ? '$wholeWord未提供' : whole,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.45,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: _TextAction(
            key: const ValueKey('fee-revert-cancel'),
            label: '取消，繼續編輯',
            onPressed: () => setState(() {
              reverting = false;
              refusal = null;
            }),
          ),
        ),
        if (!adding) ...[
          const SizedBox(height: 8),
          Divider(color: colors.outlineVariant),
          const SizedBox(height: 8),
          const FormLabel('你要改的內容'),
          const SizedBox(height: 6),
          ChangeSummary(
            title: draft!.displayName,
            lines: [ChangeLine(label: '費率', from: '自訂', to: followWords)],
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

  @override
  Widget build(BuildContext context) {
    final changes = lines;
    final count = reverting ? 1 : changes.length;
    final d = draft;
    final subject = d == null
        ? widget.spotName
        : '${widget.spotName} ${d.displayName}';
    return PopScope(
      // Back from F1b's confirmation returns to the editor.
      canPop: !reverting,
      onPopInvokedWithResult: (popped, _) {
        if (!popped && reverting) setState(() => reverting = false);
      },
      child: Form(
        key: form,
        child: FormPage(
          header: FormHeader(
            title: '費率',
            subtitle: '怎麼算錢・$subject',
            leading: FormHeaderLeading.back,
          ),
          footer: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (own != null && !reverting)
                Center(
                  child: _TextAction(
                    key: const ValueKey('fee-revert'),
                    label: revertLabel,
                    icon: Icons.undo,
                    onPressed: () => setState(() {
                      reverting = true;
                      refusal = null;
                    }),
                  ),
                ),
              SubmitBar(
                label: adding ? '完成' : '送出 $count 項建議',
                note: !adding
                    ? '管理員審核後才會更新地圖'
                    : reverting
                    ? '回到清單，這一${widget.type.unit}不帶費率'
                    : null,
                sending: sending,
                onPressed: adding || count > 0 ? submit : null,
              ),
            ],
          ),
          children: [
            if (reverting) _confirm(context),
            Visibility(
              visible: !reverting,
              maintainState: true,
              child: _body(context, changes),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, List<ChangeLine> changes) {
    final d = draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(intro),
        const SizedBox(height: 12),
        FeeEditor(
          value: fee,
          initialVehicle: firstVehicle,
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
    );
  }
}

/// F1b's text buttons, 44 tall on iOS and 48 on Android.
class _TextAction extends StatelessWidget {
  const _TextAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    style: TextButton.styleFrom(
      foregroundColor: brand,
      minimumSize: Size(48, isCupertino ? 44 : 48),
      // From the theme: a bare style would drop its font family.
      textStyle: Theme.of(context).textTheme.labelLarge
          ?.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
    ),
    onPressed: onPressed,
    icon: icon == null ? null : Icon(icon, size: 20),
    label: Text(label),
  );
}

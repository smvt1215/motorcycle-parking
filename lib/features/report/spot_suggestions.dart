import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show setEquals, visibleForTesting;

import '../../core/geo.dart';
import '../../core/town_lookup.dart';
import '../../data/account_suspended.dart';
import '../../data/app_store.dart';
import '../../domain/location_check.dart';
import '../../domain/content_report_display.dart';
import '../../domain/precheck.dart';
import '../../models/closure.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';
import '../account/suspended_sheet.dart';
import '../auth/sign_in.dart';
import '../content_report/content_report.dart';
import '../map/space_type_sheet.dart';
import '../../ui/option_pill.dart';
import '../../ui/address_search_field.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/location_picker.dart';
import '../../models/condition_text.dart' show scheduleSlotText;
import 'condition_fields.dart';
import 'entry_drafts.dart';
import 'entry_pages.dart';
import 'fee_forms.dart';
import 'form_parts.dart';
import 'report_sheet.dart';
import 'time_rules_page.dart';

String _yesNo(bool? value) => switch (value) {
  true => '可停',
  false => '不可停',
  null => '未確認',
};

/// Eligibility as reported on the spot, shown so people know what they fix.
String eligibilitySummary(ParkingSpot spot) => _eligibility(
  Eligible.of(spot.scooterAllowed, notStated: spot.scooterNotStated),
  Eligible.of(spot.heavyAllowed, notStated: spot.heavyNotStated),
);

/// A vehicle's eligibility in words; null is old data's 未確認.
String _word(Eligible? value) => value?.label ?? '未確認';

String _eligibility(Eligible? scooter, Eligible? heavy) =>
    '普通機車${_word(scooter)} · 大型重機${_word(heavy)}';

/// Where the spot is as shown today: its address or road, else coordinates.
String locationSummary(ParkingSpot spot) => spot.address.isNotEmpty
    ? spot.address
    : spot.roadSegment.isNotEmpty
    ? spot.roadSegment
    : '${spot.lat.toStringAsFixed(5)}, ${spot.lng.toStringAsFixed(5)}';

/// [metres] as riders read a distance.
String _metres(double metres) =>
    '${metres.toStringAsFixed(metres < 10 ? 1 : 0)} m';

/// The entrance and parking guide as shown today, or 未提供.
String guideSummary(ParkingSpot spot) {
  final parts = [
    if (spot.entranceNote.isNotEmpty) '入口：${spot.entranceNote}',
    if (spot.parkingGuide.isNotEmpty) '指引：${spot.parkingGuide}',
  ];
  return parts.isEmpty ? '未提供' : parts.join('；');
}

/// Why a spot can no longer be parked at. Only lasting causes suggest
/// hiding it; temporary ones go to review without that suggestion.
enum GoneCause {
  removed('格線已撤除', lasting: true),
  repurposed('改為其他用途', lasting: true),
  works('施工中', lasting: false),
  closed('暫時封閉', lasting: false),
  other('其他', lasting: false);

  const GoneCause(this.label, {required this.lasting});
  final String label;
  final bool lasting;

  /// Works and closures end; riders may say when.
  bool get temporary => this == works || this == closed;
}

/// [reason] within the server's 500 UTF-16 units (its `length`), cut
/// between whole characters so an emoji never splits. The full explanation
/// still goes in `note`, so cutting the summary loses nothing.
String reportSummary(String reason) {
  if (reason.length <= 500) return reason;
  final kept = StringBuffer();
  for (final char in reason.characters) {
    if (kept.length + char.length > 499) break;
    kept.write(char);
  }
  return '$kept…';
}

/// The report that the spot can no longer be parked at.
const goneLabel = '這裡已經不能停車';

Future<void> showSpotSuggestions(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) => showAdaptiveSheet<void>(
  context,
  (ctx) => FormFlow(
    child: SuggestionListPage(store: store, spot: spot),
  ),
);

/// Whether suggestions can name [spot]'s zones and segments: TDX spots have
/// no row to patch.
bool _hasEntries(ParkingSpot spot) =>
    spot.source == 'official' || communitySpotSources.contains(spot.source);

/// The start of an entrance note, up to its first comma and short enough
/// to leave room for the zone count beside it (S1).
String entranceHead(String note) {
  final head = note.split(RegExp('[，,、。]')).first.trim();
  final letters = head.characters;
  return letters.length <= 10 ? head : '${letters.take(10)}…';
}

/// What the spot's limits say today (S1, S3), or 未填.
String limitSummary(ParkingSpot spot) {
  if (spot.segments.length > 1) return '各段不同';
  if (spot.zones.length > 1) {
    final read = {
      for (final z in spot.zones)
        [
          for (final l in z.condition?.limits ?? const <ParkingLimit>[])
            limitText(l),
        ].join(),
    };
    if (read.length > 1) return '各區不同';
  }
  final c =
      spot.segments.firstOrNull?.condition ??
      spot.condition ??
      spot.zones.firstOrNull?.condition;
  final parts = [
    for (final l in c?.limits ?? const <ParkingLimit>[])
      if (l.kind == LimitKind.timeLimit || l.kind == LimitKind.noParking)
        limitText(l),
    for (final slot in c?.schedule ?? const <ScheduleSlot>[])
      scheduleSlotText(slot),
  ];
  return parts.isEmpty ? '未填' : parts.join('、');
}

/// What the spot charges today (S1, S3): segments of one way of charging
/// read as a range (依路段 20–30/時), mixed ones as 依路段
/// (PM_ANS_20261101_56).
String feeSummary(ParkingSpot spot) {
  final whole = wholeFeeText(null, spot.feeNote);
  if (!spot.segments.any((s) => s.fee != null)) return whole;
  final rates = [
    for (final s in spot.segments) (s.fee ?? spot.fee)?.toJson()['scooter'],
  ];
  final amounts = [
    for (final r in rates)
      if (r case {'mode': 'hourly', 'amount': final num a, 'per_minutes': 60})
        a,
  ]..sort();
  if (amounts.length < rates.length || amounts.isEmpty) return '依路段';
  final low = amounts.first, high = amounts.last;
  return low == high ? '依路段 $low/時' : '依路段 $low–$high/時';
}

/// 提出修改建議 for [spot] (S1, S3): what the map says, grouped as the four
/// signs read. Each row opens its own page, which sends its own suggestion
/// (C6). Lots and streets differ only in the rows of 停哪裡.
class SuggestionListPage extends StatelessWidget {
  const SuggestionListPage({
    super.key,
    required this.store,
    required this.spot,
  });
  final AppStore store;
  final ParkingSpot spot;

  bool get street => !isOffStreet(spot.spaceType, spot.facilityType);

  void _form(
    BuildContext context,
    String key,
    String label, [
    String? current,
  ]) => _showSuggestionForm(
    context,
    store,
    spot,
    fieldKey: key,
    label: label,
    current: current,
    inFlow: true,
  );

  EntryListArgs _listArgs(EntryType type) => EntryListArgs(
    store: store,
    type: type,
    subtitle: spot.name,
    city: spot.city.isEmpty ? null : spot.city,
    district: spot.district,
    spot: spot,
    fee: () => spot.fee ?? const Fee(),
    onSpotFee: (context) async => _fee(context, type),
    onEntryFee: (context, draft) async =>
        _fee(context, type, draft.wholeSpot ? null : draft),
  );

  /// F1 for the whole spot or for [draft].
  Future<void> _fee(
    BuildContext context,
    EntryType type, [
    EntryDraft? draft,
  ]) => openFeePage(
    context,
    store: store,
    spotName: spot.name,
    type: type,
    drafts: draftsOf(spot, type),
    spotFee: spot.fee ?? const Fee(),
    draft: draft,
    spot: spot,
    district: spot.district,
  );

  void _openEntries(BuildContext context) {
    final type = street ? EntryType.segment : EntryType.zone;
    if (!_hasEntries(spot)) {
      _form(context, 'guide', '入口與停車指引', guideSummary(spot));
      return;
    }
    Navigator.of(context).push<void>(
      formRoute(
        EntryListPage(
          args: _listArgs(type),
          onEntrance: street
              ? null
              : () => _form(context, 'guide', '入口與停車指引', guideSummary(spot)),
        ),
      ),
    );
  }

  /// F0 for a lot; a street's rates are by segment, on S3b.
  void _openFee(BuildContext context) {
    if (!street) {
      Navigator.of(context).push<void>(
        formRoute(
          FeeZonesPage(
            store: store,
            spotName: spot.name,
            drafts: _hasEntries(spot) ? draftsOf(spot, EntryType.zone) : [],
            spotFee: () => spot.fee ?? const Fee(),
            wholeText: () => wholeFeeText(spot.fee, spot.feeNote),
            spot: spot,
            district: spot.district,
          ),
        ),
      );
    } else if (_hasEntries(spot)) {
      Navigator.of(context).push<void>(
        formRoute(EntryListPage(args: _listArgs(EntryType.segment))),
      );
    } else {
      _fee(context, EntryType.segment);
    }
  }

  /// A lot's rules live in its zones; without one nothing can hold them.
  bool get _rulesOpen => street || (_hasEntries(spot) && spot.zones.isNotEmpty);

  /// S5 or S5b.
  void _openRules(BuildContext context) {
    final type = street ? EntryType.segment : EntryType.zone;
    Navigator.of(context).push<void>(
      formRoute(
        TimeRulesPage(
          store: store,
          type: type,
          subtitle: spot.name,
          drafts: draftsOf(spot, type),
          rules: null,
          spot: spot,
        ),
      ),
    );
  }

  /// The present form of a bay's kind and conditions, a lot's facility types
  /// among them.
  void _kindForm(BuildContext context, [String label = '格位類型']) =>
      _form(context, 'space_type', label, spot.spaceType.label);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final zones = spot.zones.length;
    final entrance = entranceHead(spot.entranceNote);
    final hasSegments = spot.segments.length > 1;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => FormPage(
        header: FormHeader(
          title: '提出修改建議',
          subtitle: spot.name,
          leading: FormHeaderLeading.cancel,
          onLeading: () => closeFlow(context),
        ),
        children: [
          Text(street ? '哪一項跟現場不一樣？右邊是地圖上目前寫的。' : '哪一項跟現場不一樣？點進去改，右邊是地圖上目前寫的。'),
          const SizedBox(height: 14),
          EntrySection(
            header: '基本資料',
            rows: [
              EntryRow(
                leading: const Icon(Icons.label_outline),
                title: '名稱',
                value: spot.name,
                onTap: () => _form(context, 'name', '停車點名稱', spot.name),
              ),
              EntryRow(
                leading: const Icon(Icons.pin_drop_outlined),
                title: '位置',
                value: '拖曳標記',
                onTap: () =>
                    _form(context, 'location', '停車點位置', locationSummary(spot)),
              ),
              if (!street)
                EntryRow(
                  key: const ValueKey('suggest-facility'),
                  leading: const Icon(Icons.apartment_outlined),
                  title: '場站型式',
                  value: spot.facilities.isEmpty
                      ? '未填'
                      : facilityTypesLabel(spot.facilities),
                  onTap: () => _kindForm(context, '場站型式'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          EntrySection(
            header: '能不能停',
            rows: [
              // TDX spots have no entries to patch, so theirs is the
              // spot-level form.
              if (!_hasEntries(spot))
                EntryRow(
                  key: const ValueKey('suggest-eligibility'),
                  leading: const Icon(Icons.fact_check_outlined),
                  title: '可停車種',
                  value: eligibilitySummary(spot),
                  onTap: () => _form(
                    context,
                    'eligibility',
                    '可停車種',
                    eligibilitySummary(spot),
                  ),
                )
              else if (street)
                EntryRow(
                  key: const ValueKey('suggest-vehicles'),
                  leading: const Icon(Icons.fact_check_outlined),
                  title: '可停車種',
                  subtitle:
                      '依${spot.city.isEmpty ? '縣市' : spot.city}規則帶入建議，可在各路段裡改',
                  value: hasSegments ? '各段不同' : eligibilitySummary(spot),
                  onTap: () => _openEntries(context),
                ),
              EntryRow(
                key: const ValueKey('suggest-limits'),
                leading: const Icon(Icons.schedule),
                title: '限時／禁停／共用時段',
                subtitle: street ? '現場標誌寫的' : null,
                value: _rulesOpen ? limitSummary(spot) : '先新增分區',
                onTap: _rulesOpen ? () => _openRules(context) : null,
              ),
            ],
          ),
          const SizedBox(height: 14),
          EntrySection(
            header: '怎麼算錢',
            rows: [
              EntryRow(
                key: const ValueKey('suggest-fee'),
                leading: const Icon(Icons.payments_outlined),
                title: '費率',
                subtitle: street ? '每一段各自一組' : null,
                value: feeSummary(spot),
                onTap: () => _openFee(context),
              ),
            ],
          ),
          const SizedBox(height: 14),
          EntrySection(
            header: '停哪裡',
            rows: [
              EntryRow(
                key: const ValueKey('suggest-where'),
                leading: const Icon(Icons.grid_view),
                title: street ? '路段與格位' : '入口、分區與格位、可停車種',
                subtitle: street ? '東西南北側各自分段，一段可有不同格位' : null,
                value: street
                    ? (spot.segments.isEmpty
                          ? '未填'
                          : '${spot.segments.length} 段')
                    : [
                        if (entrance.isNotEmpty) entrance,
                        if (zones > 0) '$zones 區',
                      ].join('・').ifEmpty('未填'),
                onTap: () => _openEntries(context),
              ),
            ],
          ),
          const SizedBox(height: 14),
          EntrySection(
            header: '這裡不能停車了',
            rows: [
              EntryRow(
                key: const ValueKey('suggest-gone'),
                leading: Icon(Icons.block, color: colors.error),
                title: goneLabel,
                subtitle: '格線撤除、改為其他用途、施工或封閉',
                onTap: () => _form(context, 'gone', goneLabel),
              ),
            ],
          ),
          // #280 P17b ①: same rule as the details' ⋯ menu.
          if (store.canReportContent(spot)) ...[
            const SizedBox(height: 14),
            EntrySection(
              header: contentProblemGroup,
              rows: [
                EntryRow(
                  key: const ValueKey('suggest-content-report'),
                  leading: const Icon(Icons.flag_outlined),
                  title: contentProblemRow,
                  subtitle: contentProblemDetail,
                  // Hidden from the result: this list closes, and the
                  // details behind it close as they see the rider hidden.
                  onTap: () async {
                    if (await showContentReport(context, store, spot) &&
                        context.mounted) {
                      closeFlow(context);
                    }
                  },
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          EntrySection(
            header: '其他',
            rows: [
              EntryRow(
                key: const ValueKey('suggest-note'),
                leading: const Icon(Icons.notes_outlined),
                title: '其他備註',
                value: spot.note.isEmpty ? '未提供' : spot.note,
                onTap: () => _form(
                  context,
                  'note',
                  '其他備註',
                  spot.note.isEmpty ? '未提供' : spot.note,
                ),
              ),
            ],
          ),
          if (!store.canReport) ...[
            const SizedBox(height: 14),
            SignInPrompt(store: store, message: '送出前需要登入，建議會由管理員審核。'),
          ],
        ],
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// The form of a bay's kind and conditions, which S1's 場站型式 opens; a
/// street spot's limits and bays have their own pages now (S4, S5b).
@visibleForTesting
Future<void> showKindSuggestion(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) => _showSuggestionForm(
  context,
  store,
  spot,
  fieldKey: 'space_type',
  label: '格位類型',
  current: spot.spaceType.label,
);

/// The 這裡已經不能停車 report, from a lapsed closure's 還是不能停.
Future<void> showGoneReport(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) => _showSuggestionForm(
  context,
  store,
  spot,
  fieldKey: 'gone',
  label: goneLabel,
);

/// A rider at a lapsed closure says the spot can be parked at again: a
/// report clearing the closure (`field: reopened`, proposed `closure: null`)
/// for an admin to apply. Returns the message to show.
Future<String> reportReopened(AppStore store, ParkingSpot spot) async {
  try {
    await store.submit({
      'action': 'flag',
      'source_id': spot.id,
      'reason': '暫時封閉已恢復：現場已經可以停',
      'field': 'reopened',
      'proposed': {'closure': null},
    });
    return '謝謝回報，審核後會更新地圖。';
  } on AccountSuspended {
    // Not a message for the snack bar: runAction opens the suspended panel.
    rethrow;
  } on StateError catch (e) {
    return e.message.toString();
  } catch (_) {
    return '回報沒有送出，請確認網路後再試一次。';
  }
}

Future<void> _showSuggestionForm(
  BuildContext context,
  AppStore store,
  ParkingSpot spot, {
  required String fieldKey,
  required String label,
  String? current,
  bool inFlow = false,
}) async {
  var submitted = false;
  await showAdaptiveSheet<void>(
    context,
    (_) => _SuggestionForm(
      store: store,
      spot: spot,
      fieldKey: fieldKey,
      label: label,
      current: current,
      onSubmitted: () => submitted = true,
    ),
  );
  // Any dismissal after success (Done, close, back or drag) closes the picker
  // too. Cancelling or a failed request keeps it available for another edit.
  if (submitted && context.mounted) {
    inFlow ? closeFlow(context) : Navigator.pop(context);
  }
}

class _SuggestionForm extends StatefulWidget {
  const _SuggestionForm({
    required this.store,
    required this.spot,
    required this.fieldKey,
    required this.label,
    required this.onSubmitted,
    this.current,
  });
  final AppStore store;
  final ParkingSpot spot;

  /// The stable key sent as `field`; [label] is only for display.
  final String fieldKey;
  final String label;
  final VoidCallback onSubmitted;

  /// The value shown today; null for the "can no longer park here" report.
  final String? current;
  @override
  State<_SuggestionForm> createState() => _SuggestionFormState();
}

class _SuggestionFormState extends State<_SuggestionForm> {
  final form = GlobalKey<FormState>();
  final note = TextEditingController();
  bool sending = false, sent = false;
  String? error;

  /// The kind the spot is today, and the one the rider suggests.
  late final SpaceKind currentKind = SpaceKind.of(
    widget.spot.spaceType,
    widget.spot.condition,
  );
  late SpaceKind kind = currentKind;

  /// The space type sent: the one the suggested condition converts to.
  SpaceType get type => condition.typeFor(kind);

  /// The spot's eligibility today; null is old data's 未確認, which a
  /// suggestion never sends back (#201).
  late final Eligible? currentScooter = Eligible.of(
    widget.spot.scooterAllowed,
    notStated: widget.spot.scooterNotStated,
  );
  late final Eligible? currentHeavy = Eligible.of(
    widget.spot.heavyAllowed,
    notStated: widget.spot.heavyNotStated,
  );
  late Eligible? scooter = currentScooter;
  late Eligible? heavy = currentHeavy;

  /// Whether 官方未標示 is offered: a lot's official data or its operator's
  /// notice may leave a vehicle out; a street bay is 可停 or 不可停.
  bool get lotSpot =>
      isOffStreet(widget.spot.spaceType, widget.spot.facilityType);

  /// The bay's condition as the rider corrects it with the kind.
  late final condition = ConditionDraft.of(
    widget.spot.condition,
    widget.spot.spaceType,
  );

  /// The notice link the rider attaches (design §1.4).
  final evidence = TextEditingController();

  /// The condition stored today, or the one its space type reads as.
  ParkingCondition? get currentCondition =>
      widget.spot.condition ?? conditionOf(widget.spot.spaceType);

  /// The condition suggested with the kind; null for a lot.
  ParkingCondition? get suggestedCondition => condition.conditionFor(kind);

  /// Whether the suggested kind turns the bay into 普大共用 (decision 60):
  /// the suggestion then also says whether heavy bikes may park, 可停 unless
  /// the rider changes it.
  bool get suggestsShare =>
      typeField &&
      suggestedCondition?.share == ShareKind.scooterHeavy &&
      currentCondition?.share != ShareKind.scooterHeavy;

  /// The heavy bikes' access suggested with 普大共用.
  bool? shareHeavy = true;

  /// [shareHeavy] when it changes the spot's.
  bool get shareHeavyChanged =>
      suggestsShare && shareHeavy != widget.spot.heavyAllowed;

  /// A lot's details when the suggested kind is a lot.
  late Set<FacilityType> facilities = widget.spot.facilities.toSet();

  /// Whether the suggested facility types differ from the spot's.
  bool get facilitiesChanged =>
      !setEquals(facilities, widget.spot.facilities.toSet());
  late ParkingAccess? access = widget.spot.access;
  late final entrance = TextEditingController(text: widget.spot.entranceNote);
  late final guide = TextEditingController(text: widget.spot.parkingGuide);
  GoneCause? cause;

  /// Whether the notice gives a reopening date (有寫日期), and which; a
  /// closure without one ends 7 days after it is applied (#116).
  bool dated = false;
  DateTime? until;

  /// The suggested position, starting where the map shows the spot.
  late double lat = widget.spot.lat, lng = widget.spot.lng;

  /// The county or city and district at [lat], [lng] once looked up; null
  /// until then or when the lookup failed.
  Town? newTown;

  String? get newCity => newTown?.city;
  Timer? lookupTimer;
  int lookupRound = 0;

  String get fieldKey => widget.fieldKey;
  bool get unavailable => fieldKey == 'gone';
  bool get typeField => fieldKey == 'space_type';
  bool get eligibilityField => fieldKey == 'eligibility';
  bool get guideField => fieldKey == 'guide';
  bool get locationField => fieldKey == 'location';

  /// Metres between the map's position and the suggested one.
  double get moved =>
      distanceMeters(widget.spot.lat, widget.spot.lng, lat, lng);

  /// The marker moved enough to be a suggestion, not a slip of the finger.
  bool get relocated => moved >= 1;

  /// The new position lies in another county or city, with other rules.
  bool get cityChanged =>
      newCity != null &&
      widget.spot.city.isNotEmpty &&
      newCity != widget.spot.city;

  void move(double a, double b) {
    setState(() {
      lat = a;
      lng = b;
      newTown = null;
    });
    lookupTimer?.cancel();
    // Counted now, not when the timer fires: an answer still in flight for
    // the previous position must not land on this one.
    final round = ++lookupRound;
    lookupTimer = Timer(const Duration(milliseconds: 600), () async {
      Town? town;
      try {
        town = await widget.store.townAt(a, b);
      } catch (_) {
        // The admin checks the county when applying; nothing to warn about.
      }
      if (mounted && round == lookupRound) {
        // Only a county the app knows; the sea or abroad sends coordinates
        // alone and the admin checks.
        setState(
          () => newTown = town != null && taiwanCities.contains(town.city)
              ? town
              : null,
        );
      }
    });
  }

  /// Lots also say how they are built and who parks there.
  bool get lotType => typeField && kind == SpaceKind.offStreet;

  /// Entrances belong to lots; a street bay only has a guide.
  bool get showsEntrance =>
      widget.spot.spaceType == SpaceType.offStreet ||
      widget.spot.entranceNote.isNotEmpty;

  /// Structured fields submit the chosen value; the note becomes optional.
  bool get structured =>
      typeField || eligibilityField || guideField || locationField;

  /// The longest text the spot column takes, so an applied value fits.
  int get maxLength => fieldKey == 'name' ? 100 : 450;

  String reason() {
    final text = note.text.trim();
    if (unavailable) {
      // A field hidden after switching to a lasting cause says nothing.
      final day = cause?.temporary ?? false ? closureUntil : null;
      final when = day == null ? '' : closureDayLabel(day);
      return '${widget.label}：${cause?.label ?? ''}'
          '${when.isEmpty ? '' : '；預計恢復：$when'}'
          '${text.isEmpty ? '' : '；說明：$text'}';
    }
    if (locationField) {
      return '${widget.label}：建議移到 ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'
          '（距原位置 ${_metres(moved)}${cityChanged ? '，位於$newCity' : ''}）'
          '${text.isEmpty ? '' : '；說明：$text'}';
    }
    if (guideField) {
      return '${widget.label}：'
          '${[if (entrance.text.trim().isNotEmpty) '入口「${entrance.text.trim()}」', if (guide.text.trim().isNotEmpty) '指引「${guide.text.trim()}」'].join('；')}'
          '${text.isEmpty ? '' : '；說明：$text'}';
    }
    if (!structured) return '${widget.label}：$text';
    final value = typeField
        ? '${kind.label}${shareHeavyChanged ? '，大型重機${_yesNo(shareHeavy)}' : ''}'
        : _eligibility(scooter, heavy);
    return '${widget.label}：建議「$value」${text.isEmpty ? '' : '；說明：$text'}';
  }

  /// The reopening date chosen, when the rider says the notice gives one.
  DateTime? get closureUntil => dated ? until : null;

  /// The value the admin applies, keyed by spot column (docs/ADMIN_WEB.md);
  /// null when the suggestion is only free text. Columns follow the table
  /// limits so an applied value never fails them.
  Map<String, Object?>? proposed() {
    final text = note.text.trim();
    final spot = widget.spot;
    if (typeField) {
      return {
        'space_type': type.name,
        // A street bay's condition goes with its kind, so the two never
        // disagree once applied (§1.3); a lot drops a stored one.
        if (suggestedCondition case final c?)
          'condition': c.toJson()
        else if (spot.condition != null)
          'condition': null,
        // A lot becoming a street bay drops what made it a lot, or the
        // table would still read it as off-street (§1.1 placement).
        if (!lotType && type != SpaceType.offStreet) ...{
          // A street bay is built roadside; the table sets facility_type
          // from the set.
          if (spot.facilities.any((t) => t != FacilityType.roadside))
            'facility_types': [FacilityType.roadside.name],
          if (spot.access != null) 'parking_access': null,
        },
        if (lotType) ...{
          // Segments are a street spot's only (#188 layer 2): a lot keeps
          // its bays in zones, so the segments go with the change.
          if (spot.segments.any((s) => s.id != null))
            'parking_segments': [
              for (final s in spot.segments)
                if (s.id case final id?) {'id': id, 'removed': true},
            ],
          // The set alone (decision 58); the table keeps facility_type
          // as its first.
          if (facilitiesChanged)
            'facility_types': facilityPayload(facilities)['facility_types'],
          if (access != spot.access) 'parking_access': access?.name,
        },
        if (shareHeavyChanged) 'heavy_allowed': shareHeavy,
      };
    }
    if (guideField) {
      return {
        if (entrance.text.trim() != spot.entranceNote)
          'entrance_note': entrance.text.trim(),
        if (guide.text.trim() != spot.parkingGuide)
          'parking_guide': guide.text.trim(),
      };
    }
    // The coordinates, with the county and district once looked up so a
    // move across a border changes the rules too (docs/ADMIN_WEB.md); the
    // admin can still correct them. TDX spots have no row to patch.
    if (locationField) {
      if (spot.source != 'official' &&
          !communitySpotSources.contains(spot.source)) {
        return null;
      }
      return {
        'lat': _round(lat),
        'lng': _round(lng),
        if (newTown case final town?) ...{
          'city': town.city,
          'district': town.district,
        },
      };
    }
    if (eligibilityField) {
      return {
        if (scooter case final v? when v != currentScooter)
          ...v.payload('scooter'),
        if (heavy case final v? when v != currentHeavy) ...v.payload('heavy'),
      };
    }
    if (unavailable) {
      // Works and closures end: the admin applies a closure with the date
      // the notice gives (#116), never hiding the spot.
      if (cause?.temporary ?? false) {
        return {
          'closure': {
            'reason': cause == GoneCause.works ? 'works' : 'closed',
            if (closureUntil case final d?) 'until': closureDate(d),
          },
        };
      }
      // Only a lasting cause suggests hiding.
      if (cause?.lasting != true) return null;
      // Official spots hide through their own flag; TDX spots cannot be hidden.
      if (spot.source == 'official') return {'hidden': true};
      if (communitySpotSources.contains(spot.source)) {
        return {'status': 'hidden'};
      }
      return null;
    }
    return switch (fieldKey) {
      'name' when text.length <= 100 => {'name': text},
      _ => null,
    };
  }

  /// What changes, one line per changed value from today's to the
  /// suggested one; empty until the suggestion differs from the map.
  List<String> changes() {
    final spot = widget.spot;
    final text = note.text.trim();
    String line(String label, String from, String to) =>
        '$label從「$from」改成「$to」';
    if (typeField) {
      return [
        if (kind != currentKind)
          line(widget.label, currentKind.label, kind.label),
        if (suggestedCondition case final c?
            when kind == currentKind && c != currentCondition)
          line('停放條件', conditionSummary(currentCondition), conditionSummary(c)),
        if (lotType && facilitiesChanged)
          line(
            '場站型式',
            spot.facilities.isEmpty
                ? '未提供'
                : facilityTypesLabel(spot.facilities),
            facilities.isEmpty
                ? '未確認'
                : facilityTypesLabel([
                    for (final t in FacilityType.values)
                      if (facilities.contains(t)) t,
                  ]),
          ),
        if (lotType && access != spot.access)
          line(
            '停放分類',
            spot.access?.description ?? '未提供',
            access?.description ?? '未確認',
          ),
        if (shareHeavyChanged)
          line('大型重機', _yesNo(spot.heavyAllowed), _yesNo(shareHeavy)),
      ];
    }
    if (locationField) {
      if (!relocated) return const [];
      return [
        '位置往${_bearing()}移動約 ${_metres(moved)}',
        if (cityChanged) '縣市從「${spot.city}」改成「$newCity」',
        if (newTown case final town?
            when town.district.isNotEmpty && town.district != spot.district)
          '行政區從「${spot.district.isEmpty ? '未提供' : spot.district}」改成「${town.district}」',
      ];
    }
    if (guideField) {
      String shown(String value) => value.isEmpty ? '未提供' : value;
      return [
        if (entrance.text.trim() != spot.entranceNote)
          line('入口', shown(spot.entranceNote), shown(entrance.text.trim())),
        if (guide.text.trim() != spot.parkingGuide)
          line('停車指引', shown(spot.parkingGuide), shown(guide.text.trim())),
      ];
    }
    // Only the vehicles that change, so riders need not compare two lists.
    if (eligibilityField) {
      return [
        if (scooter != currentScooter)
          line('普通機車', _word(currentScooter), _word(scooter)),
        if (heavy != currentHeavy)
          line('大型重機', _word(currentHeavy), _word(heavy)),
      ];
    }
    if (unavailable || text.isEmpty) return const [];
    return [line(widget.label, widget.current ?? '', text)];
  }

  /// The compass direction of the move, in the eight words riders use.
  String _bearing() {
    final north = lat - widget.spot.lat;
    final east = (lng - widget.spot.lng) * cos(widget.spot.lat * pi / 180);
    final degrees = (atan2(east, north) * 180 / pi + 360) % 360;
    const names = ['北', '東北', '東', '東南', '南', '西南', '西', '西北'];
    return names[((degrees + 22.5) ~/ 45) % 8];
  }

  /// Asks before sending a move far enough to be another spot.
  Future<bool> confirmFarMove() async {
    if (!locationField || moved <= farMoveMeters) return true;
    final same = await showAdaptiveDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog.adaptive(
        key: const ValueKey('suggestion-far'),
        title: const Text('還是同一個停車點嗎？'),
        content: Text(
          '新位置距原位置約 ${moved.round()} m。'
          '如果是另一處停車格，請回地圖新增停車點，不要移動這一個。',
        ),
        actions: [
          adaptiveDialogAction(
            ctx,
            label: '返回調整',
            onPressed: () => Navigator.pop(ctx, false),
          ),
          adaptiveDialogAction(
            ctx,
            label: '是同一個，送出',
            primary: true,
            onPressed: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return same ?? false;
  }

  @override
  void dispose() {
    lookupTimer?.cancel();
    note.dispose();
    evidence.dispose();
    condition.dispose();
    entrance.dispose();
    guide.dispose();
    super.dispose();
  }

  /// The report as it will be sent.
  Map<String, Object?> body() {
    final value = proposed();
    return {
      'action': 'flag',
      'source_id': widget.spot.id,
      // Older servers and Dashboard reviews read only the summary.
      'reason': reportSummary(reason()),
      'field': fieldKey,
      'proposed': ?value,
      // The text is the value itself for name and fee suggestions.
      if (value == null || structured || unavailable) 'note': note.text.trim(),
      if (typeField && evidence.text.trim().isNotEmpty)
        'evidence_url': evidence.text.trim(),
    };
  }

  /// What the server's precheck finds in the suggestion, judged with the
  /// spot's stored fee and condition as the server reads them (§4.3).
  List<PrecheckIssue> get issues => precheck(
    body(),
    current: {
      'fee': ?widget.spot.fee?.toJson(),
      'condition': ?widget.spot.condition?.toJson(),
      'scooter_allowed': ?widget.spot.scooterAllowed,
      'heavy_allowed': ?widget.spot.heavyAllowed,
    },
  );

  /// Bumped when the check fails, so the bay kind's group opens again and
  /// its follow-up's errors show.
  int reveal = 0;

  Future<void> submit() async {
    if (!form.currentState!.validate()) {
      setState(() => reveal++);
      return;
    }
    // Each hint already sits under its field; this covers one out of view.
    if (precheckBlocking(issues).firstOrNull case final issue?) {
      setState(() => error = issue.message);
      return;
    }
    if (!await confirmFarMove() || !mounted) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.store.submit(body());
      if (mounted) {
        widget.onSubmitted();
        setState(() => sent = true);
      }
    } catch (e) {
      if (accountSuspendedFrom(e) case final s?) {
        if (mounted) {
          await showSuspendedSheet(context, s.until, untilKnown: s.untilKnown);
        }
        return;
      }
      if (mounted) {
        setState(
          () => error = e is StateError
              ? e.message.toString()
              : '建議沒有送出，內容還在，請確認網路後再送一次。',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  /// Same-type spots within 15 m of the suggested position.
  List<NearbySpot> _duplicates() => checkLocation(
    lat: lat,
    lng: lng,
    spaceType: widget.spot.spaceType.name,
    selfId: widget.spot.id,
    nearby: nearbySpots(widget.store.spots),
  ).duplicates;

  Widget fieldError(BuildContext context, String? text) => text == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            text,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildForm(context),
  );

  Widget _buildForm(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final changed = changes();
    final found = issues;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: form,
        child: ContentPage(
          children: [
            SheetTitle(widget.label),
            const SizedBox(height: 8),
            Text(
              widget.spot.name,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (widget.current != null && !sent) ...[
              Material(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('地圖上目前寫的是'),
                  subtitle: Text(widget.current!),
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (sent) ...[
              const Icon(Icons.check_circle_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                widget.store.demo
                    ? '範例模式：建議沒有實際送出，只用來測試流程。'
                    : unavailable
                    ? '回報已送出。確認後，這個停車點會從地圖移除。'
                    : '建議已送出。管理員審核通過後會更新地圖。',
              ),
              const SizedBox(height: 20),
              AdaptiveButton(
                label: '完成',
                onPressed: () => Navigator.pop(context),
              ),
            ] else ...[
              if (!widget.store.canReport) ...[
                SignInPrompt(
                  store: widget.store,
                  message: '登入 Google 或 Apple 帳號後，才能送出建議。',
                ),
                const SizedBox(height: 20),
              ],
              if (typeField) ...[
                FormField<SpaceType>(
                  initialValue: type,
                  // A new pick clears the error at once.
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => changes().isNotEmpty
                      ? null
                      : lotType
                      ? '請至少修改格位類型、場站型式或停放分類其中一項'
                      : '這和目前的格位類型相同，請選擇另一種',
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('地面畫的是哪一種格位？', style: text.bodyLarge),
                      const SizedBox(height: 10),
                      SpaceKindList(
                        value: kind,
                        keyPrefix: 'report-space',
                        reveal: reveal,
                        onChanged: (v) {
                          setState(() {
                            kind = v;
                            state.didChange(type);
                          });
                        },
                        followUp: ConditionFields(
                          kind: kind,
                          draft: condition,
                          onChanged: () =>
                              setState(() => state.didChange(type)),
                          holdHint: evidence.text.trim().isEmpty
                              ? precheckHint(
                                  found,
                                  'proposed.condition',
                                  holds: true,
                                )
                              : null,
                        ),
                      ),
                      PrecheckHintText(
                        precheckHint(found, 'proposed.condition') ??
                            precheckHint(found, 'proposed.fee'),
                        key: const ValueKey('precheck-proposed-condition'),
                      ),
                      // Decision 60: 普大共用 brings heavy bikes in, 可停 by
                      // default; the rider may change it.
                      if (suggestsShare) ...[
                        const SizedBox(height: 12),
                        EligibilityChoice(
                          label: '大型重機',
                          value: Eligible.of(shareHeavy),
                          notStated: false,
                          keyPrefix: 'suggestion-share-heavy',
                          onChanged: (v) => setState(() {
                            shareHeavy = v.flag;
                            state.didChange(type);
                          }),
                        ),
                      ],
                      // These controls form one proposal with the space type.
                      // Mark the field changed so its error updates immediately.
                      if (lotType) ...[
                        const SizedBox(height: 20),
                        FacilityField(
                          value: facilities,
                          onChanged: (v) => setState(() {
                            facilities = v;
                            state.didChange(type);
                          }),
                        ),
                        AccessField(
                          value: access,
                          onChanged: (v) => setState(() {
                            access = v;
                            state.didChange(type);
                          }),
                        ),
                      ],
                      fieldError(context, state.errorText),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (eligibilityField) ...[
                FormField<(Eligible?, Eligible?)>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) =>
                      scooter == currentScooter && heavy == currentHeavy
                      ? '請至少改一個車種，和目前不同才能送出'
                      : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(
                          '現場有告示牌或地面標字時，才選「可停」。',
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                      ),
                      EligibilityChoice(
                        label: '普通機車',
                        value: scooter,
                        notStated: lotSpot,
                        keyPrefix: 'suggestion-scooter',
                        onChanged: (v) {
                          setState(() => scooter = v);
                          state.didChange((scooter, heavy));
                        },
                      ),
                      EligibilityChoice(
                        label: '大型重機',
                        value: heavy,
                        notStated: lotSpot,
                        keyPrefix: 'suggestion-heavy',
                        onChanged: (v) {
                          setState(() => heavy = v);
                          state.didChange((scooter, heavy));
                        },
                      ),
                      fieldError(context, state.errorText),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (guideField) ...[
                FormField<(String, String)>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) =>
                      entrance.text.trim() == widget.spot.entranceNote &&
                          guide.text.trim() == widget.spot.parkingGuide
                      ? '請至少修改一項，和目前不同才能送出'
                      : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (showsEntrance) ...[
                        TextFormField(
                          key: const ValueKey('suggestion-entrance'),
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          controller: entrance,
                          maxLength: 500,
                          maxLines: 2,
                          onChanged: (v) =>
                              setState(() => state.didChange(null)),
                          decoration: const InputDecoration(
                            labelText: '入口在哪裡',
                            errorMaxLines: 4,
                            hintText: '例：入口在松仁路側，機車走右側坡道',
                            alignLabelWithHint: true,
                          ),
                          validator: (v) => textHint(v, 500),
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        key: const ValueKey('suggestion-guide'),
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        controller: guide,
                        maxLength: 500,
                        maxLines: 2,
                        onChanged: (v) => setState(() => state.didChange(null)),
                        decoration: InputDecoration(
                          labelText: '停車指引',
                          errorMaxLines: 4,
                          hintText: showsEntrance
                              ? '例：B2 機車區靠電梯，重機停最後一排'
                              : '例：格位在便利商店前，靠路口一側',
                          alignLabelWithHint: true,
                        ),
                        validator: (v) => textHint(v, 500),
                      ),
                      fieldError(context, state.errorText),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (locationField) ...[
                FormField<(double, double)>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => !relocated
                      ? '請把標記拖到停車格的實際位置，和目前不同才能送出'
                      : !inTaiwanBounds(lat, lng)
                      ? '標記不在臺灣範圍內，請移回停車點的位置。'
                      : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '拖曳標記到停車格的實際位置，或點地圖選位置。空心小圈是地圖目前標示的位置。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      LocationPicker(
                        lat: lat,
                        lng: lng,
                        originLat: widget.spot.lat,
                        originLng: widget.spot.lng,
                        touchMarker: true,
                        onLocate: widget.store.currentFix,
                        height: pickerHeight(context),
                        mapBuilder: appLocationMap,
                        // Without a backend (demo) there is nothing to search.
                        onSearch: widget.store.client == null
                            ? null
                            : (context) => showAddressSearch(
                                context,
                                search: widget.store.parking.searchAddress,
                                lat: lat,
                                lng: lng,
                              ),
                        onChanged: (a, b) {
                          move(a, b);
                          state.didChange((a, b));
                        },
                      ),
                      if (state.errorText != null)
                        LocationNote(
                          icon: Icons.error_outline,
                          text: state.errorText!,
                          tone: NoteTone.error,
                        ),
                      if (cityChanged)
                        LocationNote(
                          key: const ValueKey('suggestion-city-changed'),
                          icon: Icons.rule,
                          text:
                              '新位置在$newCity，和原本的${widget.spot.city}不同，適用的停車規則會改變。',
                          tone: NoteTone.caution,
                        ),
                      for (final d in _duplicates())
                        LocationNote(
                          icon: Icons.content_copy,
                          text: '15 m 內已有同類型的停車點「${d.name}」，可能是同一處。',
                          tone: NoteTone.caution,
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (typeField) ...[
                EvidenceUrlField(
                  controller: evidence,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 20),
              ],
              if (unavailable) ...[
                FormField<GoneCause>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => cause == null ? '請選擇原因' : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('這裡為什麼不能停車？', style: text.bodyLarge),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          // Selecting changes only the fill and outline, so
                          // the row never jumps (closure canvas).
                          for (final option in GoneCause.values)
                            OptionPill(
                              key: ValueKey('gone-${option.name}'),
                              label: option.label,
                              selected: cause == option,
                              onTap: () {
                                setState(() => cause = option);
                                state.didChange(option);
                              },
                            ),
                        ],
                      ),
                      fieldError(context, state.errorText),
                    ],
                  ),
                ),
                if (cause?.temporary ?? false) ...[
                  const SizedBox(height: 16),
                  _ReopenDate(
                    dated: dated,
                    until: until,
                    onDated: (v) => setState(() => dated = v),
                    onPick: (d) => setState(() {
                      dated = true;
                      until = d;
                    }),
                  ),
                ],
                const SizedBox(height: 16),
              ],
              TextFormField(
                key: const ValueKey('suggestion-input'),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                controller: note,
                maxLength: maxLength,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  // At the top of the four lines, not floating mid-field.
                  alignLabelWithHint: true,
                  // Precheck hints are whole sentences; let them wrap.
                  errorMaxLines: 4,
                  labelText: unavailable
                      ? (cause == GoneCause.other ? '現場狀況' : '補充說明（選填）')
                      : structured
                      ? '你在現場看到什麼？（選填）'
                      : '正確的${widget.label}',
                  hintText: switch (fieldKey) {
                    'gone' => '例：格線已塗銷，改成人行道',
                    'space_type' || 'guide' => '例：入口告示寫「大型重機可停」',
                    'location' => '例：格位在對面的便利商店前',
                    'name' => '例：信義路五段收費機車格',
                    'fee_note' => '例：入口收費牌寫「機車每次 20 元」',
                    _ => '例：夜間有管理員，假日常客滿',
                  },
                ),
                validator: (v) {
                  final empty = v == null || v.trim().isEmpty;
                  if (unavailable && cause == GoneCause.other && empty) {
                    return '請填寫現場狀況';
                  }
                  if (!structured && !unavailable && empty) {
                    return '請填寫正確的${widget.label}';
                  }
                  if ((v?.length ?? 0) > maxLength) {
                    return '最多 $maxLength 字，請刪減後再送出';
                  }
                  // The text is the suggestion itself when nothing else is
                  // proposed (a note, or a TDX spot's position), so a
                  // stand-in like 測試 says nothing there; the server reads
                  // it the same way.
                  return precheckTextHint(
                    v,
                    name: fieldKey == 'name',
                    solo: !unavailable && proposed() == null,
                  );
                },
              ),
              if (changed.isNotEmpty) ...[
                const SizedBox(height: 12),
                Material(
                  key: const ValueKey('suggestion-change'),
                  color: colors.secondaryContainer,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '你要改的內容',
                          style: text.titleSmall?.copyWith(
                            color: colors.onSecondaryContainer,
                          ),
                        ),
                        const SizedBox(height: 4),
                        for (final change in changed)
                          Text(
                            change,
                            style: TextStyle(
                              color: colors.onSecondaryContainer,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(error!, style: TextStyle(color: colors.error)),
                ),
              const SizedBox(height: 20),
              AdaptiveButton(
                label: sending
                    ? '送出中…'
                    : unavailable
                    ? '送出回報'
                    : '送出修改建議',
                onPressed: sending
                    ? null
                    : widget.store.canReport
                    ? submit
                    // C2: back here with everything still filled in.
                    : () => showSignIn(context, widget.store),
              ),
              TextButton(
                onPressed: sending ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Seven decimals is about 1 cm, finer than any phone places a pin.
double _round(double degrees) => (degrees * 1e7).roundToDouble() / 1e7;

/// 預計什麼時候恢復？ (closure canvas Main): 不知道 or 有寫日期 with the date
/// from a picker, never free text, so the server can end the closure.
class _ReopenDate extends StatelessWidget {
  const _ReopenDate({
    required this.dated,
    required this.until,
    required this.onDated,
    required this.onPick,
  });
  final bool dated;
  final DateTime? until;
  final ValueChanged<bool> onDated;
  final ValueChanged<DateTime> onPick;

  Future<void> _pick(BuildContext context) async {
    final today = taiwanToday(DateTime.now());
    final d = await showDatePicker(
      context: context,
      initialDate: until ?? today,
      firstDate: today,
      lastDate: today.add(const Duration(days: 730)),
      helpText: '預計恢復日期',
    );
    if (d != null) onPick(d);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      key: const ValueKey('gone-until'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '預計什麼時候恢復？',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          OptionPills<bool>(
            values: const [(false, '不知道'), (true, '有寫日期')],
            selected: dated,
            keyOf: (v) => 'gone-dated-$v',
            onSelect: (v) {
              onDated(v);
              if (v && until == null) _pick(context);
            },
          ),
          if (dated) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('gone-until-date'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 48),
                alignment: Alignment.centerLeft,
              ),
              onPressed: () => _pick(context),
              icon: const Icon(Icons.calendar_today_outlined),
              label: Text(until == null ? '選擇預計恢復日期' : closureDayLabel(until!)),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            dated
                ? '照現場公告填。過了這天，點位會自動恢復顯示，並請下一位車友確認現場。'
                : '沒有日期時，審核通過 $closureDefaultDays 天後自動恢復顯示，並請車友確認現場。',
            style: text.bodySmall?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

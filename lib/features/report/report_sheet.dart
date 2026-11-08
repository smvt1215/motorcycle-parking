import 'dart:async';

import '../../core/config.dart';
import '../auth/sign_in.dart';
import '../auth/report_name_notice.dart';
import '../../domain/consent_display.dart';
import '../../core/geo.dart';
import '../../core/town_lookup.dart';
import '../../data/app_store.dart';
import '../../domain/location_check.dart';
import '../../domain/precheck.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart'
    show sourceUrlMaxLength, sourceUrlPattern;
import '../../models/space_kind.dart';
import '../../models/taiwan_districts.dart';
import '../../ui/option_pill.dart';
import '../../ui/address_search_field.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_editor.dart' show FeeVehicle;
import '../../ui/location_picker.dart';
import '../map/vehicle_sheet.dart';
import 'entry_drafts.dart';
import 'entry_pages.dart';
import 'form_parts.dart';

export 'report_rules.dart';

/// All 22 municipalities, so a report is never forced into a nearby city.
const taiwanCities = [
  '臺北市',
  '新北市',
  '基隆市',
  '桃園市',
  '新竹市',
  '新竹縣',
  '苗栗縣',
  '臺中市',
  '彰化縣',
  '南投縣',
  '雲林縣',
  '嘉義市',
  '嘉義縣',
  '臺南市',
  '高雄市',
  '屏東縣',
  '宜蘭縣',
  '花蓮縣',
  '臺東縣',
  '澎湖縣',
  '金門縣',
  '連江縣',
];

/// The city of a known spot within 1 km of the report, or null when the
/// reporter has to choose; a wrong city would apply the wrong parking rules.
String? nearbyCity(Iterable<ParkingSpot> spots, double lat, double lng) {
  String? city;
  var best = 1000.0;
  for (final spot in spots) {
    final meters = distanceMeters(lat, lng, spot.lat, spot.lng);
    if (meters <= best && taiwanCities.contains(spot.city)) {
      best = meters;
      city = spot.city;
    }
  }
  return city;
}

/// The bounds `submit-report` and the spot tables accept.
bool inTaiwanBounds(double lat, double lng) =>
    lat >= 20 && lat <= 27 && lng >= 118 && lng <= 123;

/// The spots near a position as the location checks see them.
List<NearbySpot> nearbySpots(Iterable<ParkingSpot> spots) => [
  for (final s in spots)
    NearbySpot(
      sourceId: s.id,
      name: s.name,
      spaceType: s.spaceType.name,
      lat: s.lat,
      lng: s.lng,
    ),
];

/// A map tall enough to aim at a bay, short enough to leave the form in
/// view on a small phone.
double pickerHeight(BuildContext context) =>
    (MediaQuery.sizeOf(context).height * .34).clamp(200.0, 300.0);

/// The picker's map: Google Maps when the build has keys, otherwise the
/// OpenStreetMap preview the main map also uses.
LocationMapBuilder? get appLocationMap =>
    AppConfig.useGoogleMaps ? null : osmLocationMap;

Future<void> showReport(
  BuildContext context,
  AppStore store,
  double lat,
  double lng, {
  bool mapCenter = false,
}) => showAdaptiveSheet<void>(
  context,
  (ctx) => FormFlow(
    child: ReportForm(store: store, lat: lat, lng: lng, mapCenter: mapCenter),
  ),
);

/// A titled group of form fields.
class FormSection extends StatelessWidget {
  const FormSection({super.key, required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        ...children,
      ],
    ),
  );
}

/// Labeled single choice of 2–6 options as pills; easier to scan than a
/// dropdown.
class ChoiceField<T> extends StatelessWidget {
  const ChoiceField({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.vehicle,
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  /// Shows the class's plate colours beside the label, as on the map's
  /// vehicle choice, so riders find their class by plate.
  final VehicleType? vehicle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (vehicle case final vehicle?) ...[
              ExcludeSemantics(
                child: SizedBox(
                  width: 38,
                  height: 30,
                  child: FittedBox(
                    child: PlateStack(plates: platesOf(vehicle)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(label, style: Theme.of(context).textTheme.bodyLarge),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 2–6 single choices are pills (C6 canvas AppPatterns, pattern 2).
        OptionPills<T>(values: options, selected: value, onSelect: onChanged),
      ],
    ),
  );
}

/// Lot types a rider can tell from outside; roadside bays are not lots.
const lotFacilities = [
  FacilityType.multiStorey,
  FacilityType.underground,
  FacilityType.surface,
];

/// A lot's facility types (decision 58): a lot may be built several ways
/// (地下＋平面), so each is a check row (C6 canvas AppPatterns, pattern 3);
/// none ticked is unconfirmed.
class FacilityField extends StatelessWidget {
  const FacilityField({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final Set<FacilityType> value;
  final ValueChanged<Set<FacilityType>> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('場站型式（可複選）', style: Theme.of(context).textTheme.bodyLarge),
        for (final type in lotFacilities)
          OptionCheck(
            key: ValueKey('facility-${type.name}'),
            label: type.label,
            value: value.contains(type),
            // A stored type not offered here (路邊) stays as it is.
            onChanged: (on) => onChanged({
              ...value.where((t) => !lotFacilities.contains(t)),
              for (final t in lotFacilities)
                if (t == type ? on : value.contains(t)) t,
            }),
          ),
      ],
    ),
  );
}

/// N1's 場站型式: the same choice as pills, 地下 first as riders name them.
class FacilityChips extends StatelessWidget {
  const FacilityChips({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final Set<FacilityType> value;
  final ValueChanged<Set<FacilityType>> onChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('場站型式（可複選）'),
      Wrap(
        spacing: 8,
        children: [
          for (final (type, label) in const [
            (FacilityType.underground, '地下'),
            (FacilityType.multiStorey, '立體'),
            (FacilityType.surface, '平面'),
          ])
            OptionPill(
              key: ValueKey('facility-${type.name}'),
              label: label,
              selected: value.contains(type),
              onTap: () => onChanged(
                value.contains(type)
                    ? ({...value}..remove(type))
                    : {...value, type},
              ),
            ),
        ],
      ),
    ],
  );
}

/// [types] as sent: `facility_types` in [FacilityType] order and, for
/// builds and viewports that read one, `facility_type` as its first.
Map<String, Object?> facilityPayload(Set<FacilityType> types) {
  final ordered = [
    for (final t in FacilityType.values)
      if (types.contains(t)) t.name,
  ];
  return {
    'facility_type': ordered.firstOrNull,
    'facility_types': ordered.isEmpty ? null : ordered,
  };
}

/// Who may park in a lot or zone, by the posted vehicle classes.
class AccessField extends StatelessWidget {
  const AccessField({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = '停放分類',
  });
  final ParkingAccess? value;
  final ValueChanged<ParkingAccess?> onChanged;
  final String label;
  @override
  Widget build(BuildContext context) => ChoiceField<ParkingAccess?>(
    label: label,
    value: value,
    options: [
      (null, '未確認'),
      for (final access in ParkingAccess.values) (access, access.description),
    ],
    onChanged: onChanged,
  );
}

/// The notice link a rider may attach (design §1.4, §4.2): https only,
/// kept with the report for the reviewer, never shown on the map.
String? evidenceUrlHint(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  if (!RegExp(sourceUrlPattern).hasMatch(text)) {
    return '請貼上以 https:// 開頭的公告網址';
  }
  return text.length > sourceUrlMaxLength ? '網址太長，請貼上公告頁的網址' : null;
}

/// The optional notice link field, the same in every report form.
class EvidenceUrlField extends StatelessWidget {
  const EvidenceUrlField({super.key, required this.controller, this.onChanged});
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
    key: const ValueKey('evidence-url'),
    controller: controller,
    keyboardType: TextInputType.url,
    decoration: const InputDecoration(
      hintText: '公告連結 https://（選填）',
      errorMaxLines: 3,
    ),
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: evidenceUrlHint,
    onChanged: onChanged,
  );
}

/// [maxLength] counts characters, but the server counts UTF-16 units, where
/// an emoji takes two; this catches what the server would reject.
String? fitsServer(String? value, int max) =>
    (value?.trim().length ?? 0) > max ? '最多 $max 個字元（表情符號算 2 個）' : null;

/// [fitsServer], then what the server's precheck would refuse in this text
/// (personal data, or a placeholder for a [name]), so the rider fixes it here.
String? textHint(String? value, int max, {bool name = false}) =>
    fitsServer(value, max) ?? precheckTextHint(value, name: name);

/// A precheck hint under the field it is about: an icon and the sentence,
/// wrapping on narrow screens; nothing when [text] is null.
class PrecheckHintText extends StatelessWidget {
  const PrecheckHintText(this.text, {super.key});
  final String? text;
  @override
  Widget build(BuildContext context) {
    final message = text;
    if (message == null) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: TextStyle(color: color)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown in a form when the reporter still has to sign in: the person icon,
/// why, and 登入 opening P11; the form stays as filled in (C2).
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.store, required this.message});
  final AppStore store;
  final String message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Row(
          children: [
            Icon(Icons.person_outline, color: colors.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
            const SizedBox(width: 8),
            AdaptiveButton(
              key: const ValueKey('sign-in-prompt'),
              label: '登入',
              onPressed: () => showSignIn(context, store),
            ),
          ],
        ),
      ),
    );
  }
}

class ReportForm extends StatefulWidget {
  const ReportForm({
    super.key,
    required this.store,
    required this.lat,
    required this.lng,
    this.mapCenter = false,
    this.mapBuilder,
  });
  final AppStore store;

  /// Where the picker starts: the long-pressed point or the map center.
  final double lat, lng;

  /// Whether the point is the map center rather than a long-pressed spot.
  final bool mapCenter;

  /// Tests swap the picker's map for a placeholder.
  final LocationMapBuilder? mapBuilder;
  @override
  State<ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<ReportForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      entrance = TextEditingController(),
      evidence = TextEditingController();

  /// 路外 or 路邊; none until the rider picks.
  bool? offStreet;
  bool get lot => offStreet == true;
  Set<FacilityType> facilities = {};

  /// The whole spot's rates: 全場費率 or 整條路費率.
  Fee fee = const Fee();

  /// Each entry of 停哪裡 (C1), kept apart so a change of mind loses neither.
  final zones = <EntryDraft>[], segments = <EntryDraft>[];
  List<EntryDraft> get entries => lot ? zones : segments;

  /// Problems the last 送出 found in the kind cards and 停哪裡.
  String? kindProblem, whereProblem;

  final anchors = {
    for (final part in const ['location', 'name', 'kind', 'where'])
      part: GlobalKey(),
  };

  late String? city = nearbyCity(widget.store.spots, widget.lat, widget.lng);
  late double lat = widget.lat, lng = widget.lng;

  /// From the reverse lookup or the rider's pick; empty until either.
  String district = '';
  bool lookingUp = false;
  String? lookupProblem;

  /// Set when the lookup moved the spot into another county or city.
  String? movedFromCity;
  Timer? lookupTimer;
  int lookupRound = 0;
  bool sending = false;

  /// The spot's legacy space type (C9): a lot's, or the street bay of its
  /// first entry open to scooters, else its first; a motorcycle bay is toll
  /// unless the rates say free. No spot-level condition goes with it, so
  /// the bay forms need not ask the charge: each segment's condition rules.
  SpaceType? get type {
    if (lot) return SpaceType.offStreet;
    if (offStreet == null || segments.isEmpty) return null;
    final first = segments.firstWhere(
      (d) => d.scooter == Eligible.allowed,
      orElse: () => segments.first,
    );
    final kind = first.kind ?? SpaceKind.motorcycle;
    if (!kind.asksCharge) return kind.baseType;
    final rates = (first.fee ?? fee).toJson()['scooter'];
    return rates is Map && rates['mode'] == 'free'
        ? SpaceType.freeMotorcycle
        : SpaceType.paidMotorcycle;
  }

  /// What the spot says for a vehicle: the triggers' roll-up of its entries
  /// (`eligibility`), sent because a new spot's request must state both.
  Eligible? rollUp(Eligible? Function(EntryDraft) of) {
    final all = entries.map(of).toList();
    if (all.isEmpty) return null;
    if (all.contains(Eligible.allowed)) return Eligible.allowed;
    if (all.contains(Eligible.notStated)) return Eligible.notStated;
    return Eligible.notAllowed;
  }

  /// Asks which county and district the marker is in, 0.6 s after it
  /// stops moving; only the latest answer counts.
  void scheduleLookup({Duration delay = const Duration(milliseconds: 600)}) {
    lookupTimer?.cancel();
    // Counted now, not when the timer fires: an answer still in flight for
    // the previous position must not land on this one.
    final round = ++lookupRound;
    lookupTimer = Timer(delay, () async {
      final at = (lat, lng);
      setState(() {
        lookingUp = true;
        lookupProblem = null;
      });
      Object? failure;
      Town? town;
      try {
        town = await widget.store.townAt(at.$1, at.$2);
      } catch (e) {
        failure = e;
      }
      if (!mounted || round != lookupRound) return;
      setState(() {
        lookingUp = false;
        if (failure != null) {
          lookupProblem = '查不到縣市與行政區，請在下方確認縣市。';
          district = '';
        } else if (town == null || !taiwanCities.contains(town.city)) {
          lookupProblem = '標記所在位置查不到縣市，請確認標記在停車點上，並在下方選擇縣市。';
          district = '';
        } else {
          final before = city;
          movedFromCity = before != null && before != town.city ? before : null;
          city = town.city;
          district = town.district;
          applyDefaults();
        }
      });
    });
  }

  /// The city's rule may open or close bays for a vehicle.
  void applyDefaults() {
    for (final d in segments) {
      d.applyDefaults(widget.store.rules, city, district: district);
    }
  }

  void move(double a, double b) => setState(() {
    lat = a;
    lng = b;
    // The district belonged to the old position; never send it stale.
    district = '';
    scheduleLookup();
  });

  @override
  void initState() {
    super.initState();
    scheduleLookup(delay: Duration.zero);
  }

  @override
  void dispose() {
    lookupTimer?.cancel();
    name.dispose();
    entrance.dispose();
    evidence.dispose();
    super.dispose();
  }

  /// The spot as it will be sent.
  Map<String, Object?> spotPayload() => {
    'name': name.text.trim(),
    'lat': lat,
    'lng': lng,
    'city': city,
    if (district.isNotEmpty) 'district': district,
    'space_type': type?.name,
    'fee_note': feeNoteOf(fee),
    if (!fee.isEmpty) 'fee': fee.toJson(),
    // 入口 for a lot, 怎麼找到格位 for a street.
    if (entrance.text.trim().isNotEmpty)
      lot ? 'entrance_note' : 'parking_guide': entrance.text.trim(),
    if (lot) ...{
      if (facilities.isNotEmpty) ...facilityPayload(facilities),
      if (zones.isNotEmpty) 'parking_zones': entriesOf(zones),
    } else if (segments.isNotEmpty)
      'parking_segments': entriesOf(segments, spotFee: fee),
    ...?rollUp((d) => d.scooter)?.payload('scooter'),
    ...?rollUp((d) => d.heavy)?.payload('heavy'),
  };

  /// The report as it will be sent, with the notice link when given.
  Map<String, Object?> body() => {
    'action': 'create',
    'spot': spotPayload(),
    if (evidence.text.trim().isNotEmpty) 'evidence_url': evidence.text.trim(),
  };

  /// What the server's precheck would refuse, or hold, in the report as it
  /// stands.
  List<PrecheckIssue> get issues => precheck(body());

  void scrollTo(String part) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final at = anchors[part]!.currentContext;
        if (at != null && at.mounted) {
          Scrollable.ensureVisible(
            at,
            alignment: .1,
            duration: const Duration(milliseconds: 250),
          );
        }
      });

  /// The first entry that cannot go, as a new city may have emptied what a
  /// vehicle was given by default: which one, and what it needs.
  String? get entryProblem {
    for (final d in entries) {
      if (entryProblems(d).values.firstOrNull case final problem?) {
        return '「${d.displayName}」：$problem';
      }
    }
    return null;
  }

  /// Checks every field; scrolls to the first that fails.
  bool validateAll() {
    final fields = form.currentState?.validate() ?? false;
    setState(() {
      kindProblem = offStreet == null ? '請選這是哪一種停車點' : null;
      whereProblem = offStreet == null
          ? null
          : entries.isEmpty
          ? '請填停哪裡：至少一${lot ? '區' : '段'}，兩種車都要選'
          : entryProblem;
    });
    final locationOk = city != null && inTaiwanBounds(lat, lng);
    if (!locationOk) {
      scrollTo('location');
    } else if (name.text.trim().isEmpty ||
        precheckTextHint(name.text, name: true) != null) {
      scrollTo('name');
    } else if (kindProblem != null) {
      scrollTo('kind');
    } else if (whereProblem != null || !fields) {
      // Past 停哪裡 only the optional fields are left to fix.
      scrollTo('where');
    }
    return fields && kindProblem == null && whereProblem == null;
  }

  Future<void> submit() async {
    if (!widget.store.canReport) {
      // C2: back here with everything still filled in.
      return showSignIn(context, widget.store);
    }
    if (!validateAll()) return;
    // A hold goes through, flagged for review.
    if (precheckBlocking(issues).firstOrNull case final issue?) {
      final where = issue.field.startsWith('parking_');
      if (where) {
        setState(() => whereProblem = issue.message);
        scrollTo('where');
      }
      return showMessage(context, issue.message);
    }
    setState(() => sending = true);
    await runAction(context, () async {
      final result = await widget.store.submit(body());
      if (mounted) {
        closeFlow(context);
        showMessage(context, result);
      }
    });
    if (mounted) setState(() => sending = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildForm(context),
  );

  /// The position: the map, the county and district it falls in, same-type
  /// spots within 15 m and a city change.
  List<Widget> _location(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Same-type spots nearby, once there is a type to compare.
    final duplicates = switch (type) {
      final t? => checkLocation(
        lat: lat,
        lng: lng,
        spaceType: t.name,
        nearby: nearbySpots(widget.store.spots),
      ).duplicates,
      null => const <NearbySpot>[],
    };
    final districts = [
      ...?taiwanDistricts[city],
      if (district.isNotEmpty &&
          !(taiwanDistricts[city]?.contains(district) ?? false))
        district,
    ];
    final cityField = DropdownButtonFormField<String>(
      // The lookup replaces the value; a new key shows it.
      key: ValueKey('report-city-$city'),
      initialValue: city,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '縣市'),
      items: [
        for (final c in taiwanCities)
          DropdownMenuItem(value: c, child: Text(c)),
      ],
      validator: (v) => v == null ? '請選擇停車點所在縣市' : null,
      onChanged: (v) => setState(() {
        if (v != city) {
          // The district belonged to the old city.
          district = '';
          movedFromCity = null;
        }
        city = v;
        applyDefaults();
      }),
    );
    final districtField = DropdownButtonFormField<String>(
      key: ValueKey('report-district-$city-$district'),
      initialValue: district.isEmpty ? null : district,
      isExpanded: true,
      decoration: const InputDecoration(labelText: '區'),
      hint: Text(city == null ? '先選縣市' : '未選'),
      items: [
        for (final d in districts) DropdownMenuItem(value: d, child: Text(d)),
      ],
      onChanged: city == null
          ? null
          : (v) => setState(() => district = v ?? ''),
    );
    return [
      FormLabel('位置', key: anchors['location']),
      const SizedBox(height: 4),
      Text(
        '拖曳標記對準停車格，或點地圖選位置。'
        '${widget.mapCenter ? '從目前地圖中心開始。' : '從你長按的位置開始。'}',
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      FormField<void>(
        validator: (_) =>
            inTaiwanBounds(lat, lng) ? null : '標記不在臺灣範圍內，請移回停車點的位置。',
        builder: (state) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LocationPicker(
              lat: lat,
              lng: lng,
              touchMarker: true,
              onLocate: widget.store.currentFix,
              height: 180,
              mapBuilder: widget.mapBuilder ?? appLocationMap,
              expandButton: true,
              overlayControls: true,
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
                state.didChange(null);
              },
            ),
            if (state.errorText != null)
              LocationNote(
                icon: Icons.error_outline,
                text: state.errorText!,
                tone: NoteTone.error,
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, box) => box.maxWidth < 280
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  cityField,
                  const SizedBox(height: 12),
                  districtField,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: cityField),
                  const SizedBox(width: 10),
                  Expanded(child: districtField),
                ],
              ),
      ),
      const SizedBox(height: 6),
      Text(
        '依地圖位置自動帶入，可以改。',
        style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
      ),
      if (lookingUp)
        const LocationNote(icon: Icons.travel_explore, text: '正在查詢所在縣市與行政區…')
      else if (lookupProblem != null)
        LocationNote(
          icon: Icons.help_outline,
          text: lookupProblem!,
          tone: NoteTone.caution,
        ),
      if (movedFromCity != null)
        LocationNote(
          key: const ValueKey('report-city-changed'),
          icon: Icons.rule,
          text: '標記在$city，不是原本帶入的$movedFromCity；適用$city的停車規則，請確認可停車種。',
          tone: NoteTone.caution,
        ),
      if (duplicates.isNotEmpty) ...[
        const SizedBox(height: 8),
        FormInfoNote(
          key: const ValueKey('report-duplicate'),
          icon: Icons.content_copy,
          text:
              '15 m 內已有停車點：${duplicates.map((d) => d.name).join('、')}。'
              '如果是同一處，請關閉這個表單，改到該點提出修改建議。',
          tone: FormNoteTone.warning,
        ),
      ],
    ];
  }

  String get subtitle => name.text.trim().isEmpty ? '新增停車點' : name.text.trim();

  EntryListArgs get listArgs => EntryListArgs(
    store: widget.store,
    type: lot ? EntryType.zone : EntryType.segment,
    subtitle: subtitle,
    city: city,
    district: district,
    drafts: entries,
    fee: () => fee,
    onChanged: () => setState(() => whereProblem = null),
    onSpotFee: lot ? null : editFee,
    onEntryFee: lot
        ? null
        : (context, draft) async {
            final next = await showFeeDraftPage(
              context,
              subtitle: draft.displayName,
              value: draft.fee ?? const Fee(),
              vehicle: FeeVehicle.of(widget.store.vehicle),
            );
            if (next != null) {
              setState(() => draft.fee = next.isEmpty ? null : next);
            }
          },
  );

  /// 全場費率 or 整條路費率, on the page PR10's F1 replaces.
  Future<void> editFee(BuildContext context) async {
    final next = await showFeeDraftPage(
      context,
      subtitle: subtitle,
      value: fee,
      vehicle: FeeVehicle.of(widget.store.vehicle),
    );
    if (next != null) setState(() => fee = next);
  }

  void openWhere() =>
      Navigator.of(context)
          .push<void>(formRoute(EntryListPage(args: listArgs)));

  String get feeSummary {
    if (!fee.isEmpty) return feeNoteOf(fee);
    return !lot && segments.any((d) => d.fee != null) ? '依路段' : '未填';
  }

  Widget _buildForm(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final signedIn = widget.store.canReport;
    final picked = offStreet != null;
    return Form(
      key: form,
      child: FormPage(
        header: FormHeader(
          title: '新增停車點',
          subtitle: '貢獻',
          leading: FormHeaderLeading.cancel,
          onLeading: () => closeFlow(context),
        ),
        footer: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Only a new spot shows its reporter's name (P16b).
            if (widget.store.riderId != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: ReportNameNotice(store: widget.store),
              ),
            SubmitBar(
              label: '送出',
              note: '停放資格請依現場標示',
              sending: sending,
              onPressed: submit,
            ),
          ],
        ),
        children: [
          ..._location(context),
          const SizedBox(height: 16),
          TextFormField(
            key: anchors['name'],
            controller: name,
            maxLength: 100,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '名稱',
              errorMaxLines: 4,
              hintText: '例：松壽地下停車場',
              counterText: '',
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (v) => (v?.trim().isEmpty ?? true)
                ? '請填寫名稱'
                : textHint(v, 100, name: true),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          FormLabel('這是哪一種停車點？', key: anchors['kind']),
          const SizedBox(height: 8),
          SpotKindCards(
            offStreet: offStreet,
            error: kindProblem,
            onChanged: (v) => setState(() {
              offStreet = v;
              kindProblem = null;
              whereProblem = null;
            }),
          ),
          if (lot) ...[
            const SizedBox(height: 10),
            FacilityChips(
              value: facilities,
              onChanged: (v) => setState(() => facilities = v),
            ),
          ],
          const SizedBox(height: 16),
          FormLabel('接著照四面路牌填', key: anchors['where'], aside: '知道的填就好，其他可以之後補'),
          const SizedBox(height: 8),
          EntrySection(
            footer: '「有沒有位」不用填，由官方即時資料和車友回報提供。',
            rows: [
              // S5 and S5b come with PR10.
              const EntryRow(
                key: ValueKey('n1-rules'),
                leading: Icon(Icons.fact_check_outlined),
                title: '能不能停',
                subtitle: '限時／禁停／共用時段',
                value: '即將開放',
              ),
              EntryRow(
                key: const ValueKey('n1-fee'),
                leading: const Icon(Icons.payments_outlined),
                title: '怎麼算錢',
                subtitle: !picked
                    ? '先選這是哪一種停車點'
                    : lot
                    ? '依分區或全場費率'
                    : '每一段各自一組',
                value: feeSummary,
                onTap: !picked
                    ? null
                    : lot
                    ? () => editFee(context)
                    : openWhere,
              ),
              EntryRow(
                key: const ValueKey('n1-where'),
                leading: const Icon(Icons.grid_view),
                title: '停哪裡',
                subtitle: !picked
                    ? '先選這是哪一種停車點'
                    : lot
                    ? '分區、格位、可停車種'
                    : '路段、格位、可停車種',
                value: entries.isEmpty || !picked
                    ? '未填'
                    : '${entries.length} ${lot ? '區' : '段'}',
                problem: whereProblem,
                onTap: picked ? openWhere : null,
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const ValueKey('report-entrance'),
            controller: entrance,
            maxLength: 500,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: offStreet == false ? '怎麼找到格位（選填）' : '入口在哪裡（選填）',
              errorMaxLines: 4,
              hintText: offStreet == false
                  ? '例：格位在便利商店前，靠路口一側'
                  : '例：松壽路側車道下坡，機車走右側',
              counterText: '',
              alignLabelWithHint: true,
            ),
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (v) => textHint(v, 500),
          ),
          const SizedBox(height: 16),
          EvidenceUrlField(
            controller: evidence,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          // Signed out, the sign-in card carries the same sentence (P16b).
          if (signedIn)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '新增的停車點會顯示於地圖，資訊待管理者確認。',
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            )
          else
            SignInPrompt(store: widget.store, message: newSpotSignInMessage),
        ],
      ),
    );
  }
}

Future<void> showParkingForm(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(context, (ctx) => ParkingForm(store: store));

class ParkingForm extends StatefulWidget {
  const ParkingForm({super.key, required this.store});
  final AppStore store;
  @override
  State<ParkingForm> createState() => _ParkingFormState();
}

class _ParkingFormState extends State<ParkingForm> {
  final note = TextEditingController(), floor = TextEditingController();
  int minutes = 0;
  bool saving = false;
  @override
  void dispose() {
    note.dispose();
    floor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: ContentPage(
      children: [
        SheetTitle('記錄停車'),
        const SizedBox(height: 12),
        const Text('以目前裝置定位記錄位置。位置與備註只存在這台裝置。'),
        const SizedBox(height: 12),
        TextField(
          controller: floor,
          maxLength: 30,
          decoration: const InputDecoration(
            labelText: '樓層或區域（選填）',
            hintText: '例：B2 重機區',
          ),
        ),
        TextField(
          controller: note,
          maxLength: 300,
          decoration: const InputDecoration(labelText: '備註（選填）'),
        ),
        const SizedBox(height: 8),
        Text('多久後提醒我', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        AdaptiveSegmented<int>(
          key: const ValueKey('parking-reminder'),
          options: const {0: '不提醒', 30: '30 分', 60: '1 小時', 120: '2 小時'},
          value: minutes,
          onChanged: (v) => setState(() => minutes = v),
        ),
        const SizedBox(height: 24),
        AdaptiveButton(
          label: saving ? '定位中…' : '記錄停車位置',
          onPressed: saving
              ? null
              : () async {
                  setState(() => saving = true);
                  await runAction(context, () async {
                    final scheduled = await widget.store.recordParking(
                      note.text.trim(),
                      floor.text.trim(),
                      minutes == 0 ? null : minutes,
                    );
                    if (context.mounted) {
                      Navigator.pop(context);
                      showMessage(
                        context,
                        minutes > 0 && !scheduled
                            ? '位置已儲存；通知未授權或此平台不支援提醒'
                            : '停車位置已儲存',
                      );
                    }
                  });
                  if (mounted) setState(() => saving = false);
                },
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

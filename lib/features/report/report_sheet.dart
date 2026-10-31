import 'dart:async';

import '../../core/app_version.dart';
import '../../core/config.dart';
import '../auth/sign_in.dart';
import '../../core/geo.dart';
import '../../core/town_lookup.dart';
import '../../data/app_store.dart';
import '../../data/profile_repository.dart';
import '../../domain/eligibility.dart';
import '../../domain/location_check.dart';
import '../../domain/precheck.dart';
import 'condition_fields.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart'
    show
        ShareKind,
        ZoneArea,
        allowKeys,
        eligibilityNotStated,
        sourceUrlMaxLength,
        sourceUrlPattern;
import '../../models/space_kind.dart';
import '../../models/taiwan_districts.dart';
import '../../ui/fold_section.dart';
import '../../ui/option_pill.dart';
import '../../ui/address_search_field.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_editor.dart';
import '../../ui/location_picker.dart';
import '../../ui/version_text.dart';
import '../map/space_type_sheet.dart';
import '../map/vehicle_sheet.dart';
import '../auth/profile_avatar.dart';
import '../auth/profile_editor.dart';

Future<void> showSettings(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          // The vehicle is switched beside what it changes: the map's
          // vehicle pill (and the rules page filter), not here.
          SheetTitle('帳號與設定'),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: store,
            builder: (ctx, _) => _AccountCard(store: store),
          ),
          const SizedBox(height: 28),
          Text(
            '關於',
            style: Theme.of(ctx).textTheme.titleSmall
                ?.copyWith(color: Theme.of(ctx).colorScheme.primary),
          ),
          const SizedBox(height: 4),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.description_outlined),
            title: const Text('授權資訊'),
            subtitle: const Text('App 使用的開放原始碼套件'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => runAction(ctx, () async {
              final version = await AppVersion.current;
              if (!ctx.mounted) return;
              showLicensePage(
                context: ctx,
                applicationName: '機車停車指南',
                applicationVersion: version.label,
              );
            }),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('版本'),
            // Selectable, so testers can paste the exact build into feedback.
            subtitle: VersionText(
              selectable: true,
              textAlign: TextAlign.start,
              style: Theme.of(ctx).textTheme.bodyMedium
                  ?.copyWith(color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );

/// Who is signed in and what that unlocks: sample data, signed out, or the
/// signed-in account with sign-out.
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.store});
  final AppStore store;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final user = store.client?.auth.currentUser;
    final signedIn = user != null && !user.isAnonymous;
    final name = profileDisplayName(user);
    final email = user?.email;
    final (title, detail) = store.demo
        ? ('範例模式', '目前使用範例資料。回報只用於功能測試，請勿依範例資料停車。')
        : !signedIn
        ? ('尚未登入', '登入後可回報停車點與同步收藏。瀏覽與記錄停車位置不需登入。')
        // A name heads the card with the email under it; else the email.
        : (
            name ?? email ?? '已登入',
            (name != null ? email : null) ?? '回報與收藏已同步到帳號',
          );
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (signedIn)
                  Semantics(
                    button: true,
                    label: '編輯頭像',
                    child: InkWell(
                      onTap: () => showProfileEditor(context, store),
                      customBorder: const CircleBorder(),
                      child: ProfileAvatar(user: user),
                    ),
                  )
                else
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: colors.surfaceContainerHighest,
                    foregroundColor: colors.onSurfaceVariant,
                    child: Icon(
                      store.demo
                          ? Icons.science_outlined
                          : Icons.person_outline,
                    ),
                  ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    key: const ValueKey('account-title'),
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (signedIn)
                  IconButton(
                    tooltip: '編輯個人資料',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => showProfileEditor(context, store),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              detail,
              style: text.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
            if (!store.demo && !signedIn) ...[
              const SizedBox(height: 16),
              SignInButtons(store: store),
            ],
            if (signedIn) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => runAction(context, () async {
                    await store.signOut();
                    if (context.mounted) Navigator.pop(context);
                  }),
                  child: const Text('登出'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

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
  (ctx) => ReportForm(store: store, lat: lat, lng: lng, mapCenter: mapCenter),
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

/// What a bay's markings say about each vehicle before the reporter looks
/// further: motorcycle bays take scooters, heavy-only bays take heavy bikes
/// only, and car bays are not for scooters (道路交通安全規則 §112). Anything
/// the markings cannot settle stays unconfirmed.
({bool? scooter, bool? heavy}) markedEligibility(SpaceType type) =>
    switch (type) {
      SpaceType.paidMotorcycle ||
      SpaceType.freeMotorcycle ||
      SpaceType.timedMotorcycle => (scooter: true, heavy: null),
      SpaceType.heavyOnly => (scooter: false, heavy: true),
      SpaceType.car => (scooter: false, heavy: null),
      _ => (scooter: null, heavy: null),
    };

/// What the city's rule decides for a bay of [type] before anything on the
/// ground: open is 可停, closed is 不可停, and anything conditional or
/// unknown stays unconfirmed.
({bool? scooter, bool? heavy}) ruledEligibility(
  List<CityRule> rules,
  SpaceType type,
  String? city,
) {
  bool? decide(VehicleType vehicle) {
    if (city == null) return null;
    final rule =
        rules
            .where((r) => r.vehicle == vehicle && r.city == city)
            .firstOrNull ??
        rules.where((r) => r.vehicle == vehicle && r.city == '全國').firstOrNull;
    // Judged as data with no claims of its own, so only the law speaks.
    final draft = ParkingSpot(
      id: 'draft',
      name: '',
      lat: 0,
      lng: 0,
      city: city,
      spaceType: type,
      source: 'official',
    );
    return switch (eligibility(draft, vehicle, rule).status) {
      EligibilityStatus.allowed => true,
      EligibilityStatus.notAllowed => false,
      _ => null,
    };
  }

  return (
    scooter: decide(VehicleType.scooter),
    heavy: decide(VehicleType.heavy),
  );
}

/// The vehicles a new report starts with: what the markings say, and the
/// city's rule where the markings cannot tell.
({bool? scooter, bool? heavy}) defaultEligibility(
  List<CityRule> rules,
  SpaceType type,
  String? city,
) {
  final marked = markedEligibility(type);
  final ruled = ruledEligibility(rules, type, city);
  return (
    scooter: marked.scooter ?? ruled.scooter,
    heavy: marked.heavy ?? ruled.heavy,
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

/// Who may park in a zone (#201): one of the posted vehicle classes, or
/// 官方未標示 when the lot's notice (its operator's too) does not say.
/// Required: every zone a rider adds states both vehicles.
class ZoneAccessField extends StatelessWidget {
  const ZoneAccessField({
    super.key,
    required this.zone,
    required this.onChanged,
  });
  final ZoneDraft zone;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => FormField<Object>(
    validator: (_) =>
        zone.access == null && !zone.notStated ? '請選擇這區的停放分類' : null,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChoiceField<Object?>(
          label: '停放分類',
          value: zone.notStated ? eligibilityNotStated : zone.access,
          options: [
            for (final access in ParkingAccess.values)
              (access, access.description),
            (eligibilityNotStated, Eligible.notStated.label),
          ],
          onChanged: (v) {
            zone.notStated = v == eligibilityNotStated;
            zone.access = v is ParkingAccess ? v : null;
            field.didChange(v);
            onChanged();
          },
        ),
        if (field.errorText case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

/// A vehicle's eligibility in a rider's new spot (#201): required. A street
/// bay is 可停 or 不可停, with what the city's rule suggests; a lot may also
/// say 官方未標示.
class EligibilityField extends StatelessWidget {
  const EligibilityField({
    super.key,
    required this.label,
    required this.value,
    required this.notStated,
    required this.onChanged,
    this.keyPrefix,
  });
  final String label;
  final Eligible? value;
  final bool notStated;
  final ValueChanged<Eligible> onChanged;
  final String? keyPrefix;

  @override
  Widget build(BuildContext context) => FormField<Eligible>(
    validator: (_) =>
        value == null || (!notStated && value == Eligible.notStated)
        ? '請選擇$label能不能停'
        : null,
    builder: (field) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        EligibilityChoice(
          label: label,
          value: value,
          notStated: notStated,
          keyPrefix: keyPrefix,
          onChanged: (v) {
            field.didChange(v);
            onChanged(v);
          },
        ),
        if (field.errorText case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
  );
}

/// Which area of a lot a zone is (機車區、汽車區…), as its signs say.
class ZoneAreaField extends StatelessWidget {
  const ZoneAreaField({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final ZoneArea? value;
  final ValueChanged<ZoneArea?> onChanged;

  @override
  Widget build(BuildContext context) => ChoiceField<ZoneArea?>(
    key: const ValueKey('zone-area'),
    label: '區域',
    value: value,
    options: zoneAreaLabels,
    onChanged: onChanged,
  );
}

/// Zone areas as lots post them; null is unconfirmed.
const zoneAreaLabels = <(ZoneArea?, String)>[
  (null, '未確認'),
  (ZoneArea.motorcycle, '機車區'),
  (ZoneArea.car, '汽車區'),
  (ZoneArea.heavy, '重機專區'),
  (ZoneArea.mixed, '汽機車混合區'),
];

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
      labelText: '公告連結（選填）',
      hintText: 'https://',
      helperText: '停管處或現場公告的網頁，審核會比較快',
      helperMaxLines: 2,
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

/// One zone of a lot while it is being reported.
class ZoneDraft {
  final name = TextEditingController();
  final guide = TextEditingController();
  ParkingAccess? access;

  /// 官方未標示 (#201): the lot's notice does not say who may park here.
  bool notStated = false;

  /// 機車區、汽車區… as the lot's signs name it; null is unconfirmed.
  ZoneArea? area;
  Fee fee = const Fee();

  void dispose() {
    name.dispose();
    guide.dispose();
  }

  Map<String, Object> toJson() => {
    'name': name.text.trim(),
    if (access case final access? when !notStated) 'access': access.name,
    if (notStated)
      'condition': {
        'allow': {for (final v in allowKeys) v: eligibilityNotStated},
      },
    if (area case final area?) 'area': area.name,
    if (guide.text.trim().isNotEmpty) 'guide': guide.text.trim(),
    if (!fee.isEmpty) 'fee': fee.toJson(),
  };
}

/// Up to ten named zones of a lot, each with its access and a guide.
class ZoneEditor extends StatelessWidget {
  const ZoneEditor({
    super.key,
    required this.zones,
    required this.onAdd,
    required this.onRemove,
    required this.onChanged,
    this.feeHint,
    this.feeHold,
    this.vehicle,
  });
  final List<ZoneDraft> zones;

  /// The precheck hold note for the fee of the zone at an index, if any.
  final String? Function(int index)? feeHold;

  /// The rider's vehicle, whose rate each zone's fee editor opens on.
  final VehicleType? vehicle;

  /// The precheck hint for the fee of the zone at an index, if any.
  final String? Function(int index)? feeHint;
  final VoidCallback onAdd;
  final ValueChanged<ZoneDraft> onRemove;

  /// Called after a zone's access changes so the form can rebuild.
  final VoidCallback onChanged;

  static const max = 10;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('分區（如適用）', style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: 4),
        Text(
          '例如 B2 機車區、1F 汽車區；各區可停車種或收費不同時分開填。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        for (final (i, zone) in zones.indexed) ...[
          const SizedBox(height: 12),
          Material(
            key: ObjectKey(zone),
            // Outlined: the sheet shares this surface, so a fill alone would
            // not show where one zone ends.
            color: colors.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '分區 ${i + 1}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: '刪除分區 ${i + 1}',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => onRemove(zone),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          controller: zone.name,
                          maxLength: 40,
                          decoration: const InputDecoration(
                            labelText: '分區名稱',
                            errorMaxLines: 4,
                            hintText: '例：B2 機車區',
                            counterText: '',
                          ),
                          validator: (v) => (v?.trim().isEmpty ?? true)
                              ? '請填寫分區名稱，或刪除此分區'
                              : textHint(v, 40, name: true),
                        ),
                        const SizedBox(height: 12),
                        ZoneAreaField(
                          value: zone.area,
                          onChanged: (v) {
                            zone.area = v;
                            onChanged();
                          },
                        ),
                        const SizedBox(height: 12),
                        ZoneAccessField(zone: zone, onChanged: onChanged),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: zone.guide,
                          maxLength: 200,
                          decoration: const InputDecoration(
                            labelText: '這區怎麼停（選填）',
                            errorMaxLines: 4,
                            hintText: '例：靠電梯，重機停最後一排',
                            counterText: '',
                          ),
                          validator: (v) => textHint(v, 200),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '這區的費率（選填）',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        FeeEditor(
                          key: ObjectKey(zone),
                          initialVehicle: switch (vehicle) {
                            final v? => FeeVehicle.of(v),
                            null => null,
                          },
                          value: zone.fee,
                          errorText: feeHint?.call(i),
                          onChanged: (value) {
                            zone.fee = value;
                            onChanged();
                          },
                        ),
                        const SizedBox(height: 8),
                        PrecheckHoldText(feeHold?.call(i)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: zones.length >= max ? null : onAdd,
            icon: const Icon(Icons.add),
            label: Text(zones.length >= max ? '最多 $max 個分區' : '新增分區'),
          ),
        ),
      ],
    );
  }
}

/// Shown above a form when the reporter still has to sign in.
class SignInPrompt extends StatelessWidget {
  const SignInPrompt({super.key, required this.store, required this.message});
  final AppStore store;
  final String message;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.lock_outline, color: colors.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: TextStyle(color: colors.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SignInButtons(store: store),
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
  final name = TextEditingController(),
      note = TextEditingController(),
      entrance = TextEditingController(),
      guide = TextEditingController();
  Fee fee = const Fee();

  /// The bay kind picked; none until the rider picks (C6 canvas AppForm).
  SpaceKind? kind;

  /// The space type sent: the one the kind's condition converts to.
  SpaceType? get type => switch (kind) {
    final k? => condition.typeFor(k),
    null => null,
  };

  /// Both required (#201); prefilled from the markings and the city's rule.
  late Eligible? scooter = Eligible.of(defaults.scooter);
  late Eligible? heavy = Eligible.of(defaults.heavy);
  Set<FacilityType> facilities = {};
  ParkingAccess? access;
  final zones = <ZoneDraft>[];

  /// What the rider adds to the bay kind: charge, 普大共用, limits, periods.
  final condition = ConditionDraft();
  final evidence = TextEditingController();

  bool get lot => kind == SpaceKind.offStreet;

  ({bool? scooter, bool? heavy}) get defaults => switch (type) {
    // Decision 60: a 普大共用 bay is marked for heavy bikes too.
    final t? when sharesHeavy => (
      scooter: defaultEligibility(widget.store.rules, t, city).scooter,
      heavy: true,
    ),
    final t? => defaultEligibility(widget.store.rules, t, city),
    null => (scooter: null, heavy: null),
  };

  /// Whether the bay as picked is 普大共用 (the kind, or a 限時 bay marked
  /// for both).
  bool get sharesHeavy => switch (kind) {
    final k? => condition.conditionFor(k)?.share == ShareKind.scooterHeavy,
    null => false,
  };

  /// Whether the city's rule, not only the markings, set a vehicle.
  bool get ruled => ruledOnly.scooter || ruledOnly.heavy;

  /// The vehicles sent unconfirmed because only the city's rule set them.
  List<String> get ruledVehicles => [
    if (scooterRuled) '普通機車',
    if (heavyRuled) '大型重機',
  ];

  /// Once the reporter sets the vehicles, a new bay kind no longer resets them.
  bool vehiclesEdited = false;

  /// Vehicles whose shown value only the city's rule set: a suggestion the
  /// rider confirms (#201). Every vehicle is sent as picked.
  bool scooterRuled = false, heavyRuled = false;

  ({bool scooter, bool heavy}) get ruledOnly {
    final type = this.type;
    if (type == null) return (scooter: false, heavy: false);
    final marked = markedEligibility(type);
    final rule = ruledEligibility(widget.store.rules, type, city);
    return (
      scooter: marked.scooter == null && rule.scooter != null,
      heavy: marked.heavy == null && rule.heavy != null && !sharesHeavy,
    );
  }

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
          // The new city's rule may open or close bays for a vehicle.
          applyDefaults();
        }
      });
    });
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
    // Values and flags from the same bay kind and city, not computed lazily
    // at submit time after either changed.
    applyDefaults();
    scheduleLookup(delay: Duration.zero);
  }

  @override
  void dispose() {
    lookupTimer?.cancel();
    name.dispose();
    note.dispose();
    entrance.dispose();
    guide.dispose();
    evidence.dispose();
    condition.dispose();
    for (final zone in zones) {
      zone.dispose();
    }
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
    'note': note.text.trim(),
    if (guide.text.trim().isNotEmpty) 'parking_guide': guide.text.trim(),
    // Lot details only for lots, whatever was typed before the bay kind
    // changed.
    if (lot) ...{
      if (facilities.isNotEmpty) ...facilityPayload(facilities),
      'parking_access': ?access?.name,
      if (entrance.text.trim().isNotEmpty)
        'entrance_note': entrance.text.trim(),
      if (zones.isNotEmpty)
        'parking_zones': [for (final zone in zones) zone.toJson()],
    },
    // Both vehicles as picked (#201); 官方未標示 only for a lot.
    if (scooter case final v? when lot || v != Eligible.notStated)
      ...v.payload('scooter'),
    if (heavy case final v? when lot || v != Eligible.notStated)
      ...v.payload('heavy'),
    // A street bay's condition (design §1.2): the kind's, plus what the
    // rider adds. Its space type is always the kind picked (§1.3).
    'condition': ?switch (kind) {
      final k? => condition.conditionFor(k)?.toJson(),
      null => null,
    },
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

  void setKind(SpaceKind value) => setState(() {
    kind = value;
    applyDefaults();
  });

  /// The section open now (C6 canvas AppForm: one at a time); null when all
  /// are folded. The position comes first.
  _Part? open = _Part.location;

  /// Sections whose fields failed the last check, flagged while folded.
  final problems = <_Part>{};
  final forms = {for (final part in _Part.values) part: GlobalKey<FormState>()};
  final anchors = {for (final part in _Part.values) part: GlobalKey()};

  void toggle(_Part part) => setState(() => open = open == part ? null : part);

  /// Checks every section; opens and scrolls to the first that fails.
  bool validateAll() {
    problems.clear();
    for (final part in parts) {
      // Every section is built (ContentPage(lazy: false)); one that is not
      // yet counts as failing rather than passing unchecked.
      if (!(forms[part]!.currentState?.validate() ?? false)) problems.add(part);
    }
    if (problems.isEmpty) return true;
    showProblems();
    return false;
  }

  /// Bumped when a check fails, so the bay kind's group opens again and
  /// its follow-up's errors show.
  int reveal = 0;

  /// Opens the first section in [problems] and scrolls to it.
  void showProblems() {
    final first = parts.firstWhere(problems.contains);
    setState(() {
      open = first;
      reveal++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final at = anchors[first]!.currentContext;
      if (at != null && at.mounted) {
        Scrollable.ensureVisible(
          at,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  /// The section holding the field a precheck issue is about, if the
  /// form shows it.
  _Part? partOf(String field) => switch (field.split('.').first) {
    'name' => _Part.name,
    'lat' || 'lng' || 'city' || 'district' => _Part.location,
    'space_type' || 'condition' => _Part.kind,
    'scooter_allowed' ||
    'heavy_allowed' ||
    'scooter_not_stated' ||
    'heavy_not_stated' => _Part.vehicles,
    'fee' => _Part.fee,
    'facility_type' ||
    'facility_types' ||
    'parking_access' ||
    'parking_zones' => lot ? _Part.lot : _Part.kind,
    'note' ||
    'parking_guide' ||
    'entrance_note' ||
    'evidence_url' => _Part.extra,
    _ => null,
  };

  /// The sections this report shows, in order.
  List<_Part> get parts => [
    _Part.location,
    _Part.name,
    _Part.kind,
    if (lot) _Part.lot,
    _Part.vehicles,
    _Part.fee,
    _Part.extra,
  ];

  /// Refills the vehicles from the markings and city rule until the
  /// reporter sets them.
  void applyDefaults() {
    // A street bay is 可停 or 不可停: 官方未標示 goes with the lot.
    if (!lot && scooter == Eligible.notStated) scooter = null;
    if (!lot && heavy == Eligible.notStated) heavy = null;
    if (vehiclesEdited) return;
    scooter = Eligible.of(defaults.scooter);
    heavy = Eligible.of(defaults.heavy);
    final ruled = ruledOnly;
    scooterRuled = ruled.scooter;
    heavyRuled = ruled.heavy;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildForm(context),
  );

  /// A section of the form: folded to its summary, or open with [children]
  /// in a form of its own, so a folded one is still checked on send.
  Widget _part(
    _Part part, {
    required String title,
    required String? summary,
    String? hint,
    required List<Widget> children,
  }) => FoldSection(
    key: anchors[part],
    title: title,
    summary: summary,
    hint: hint,
    open: open == part,
    problem: open != part && problems.contains(part),
    onToggle: () => toggle(part),
    child: Form(
      key: forms[part],
      // A flagged section is cleared once its fields pass again.
      onChanged: () {
        if (!problems.contains(part)) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !problems.contains(part)) return;
          if (forms[part]!.currentState?.validate() ?? false) {
            setState(() => problems.remove(part));
          }
        });
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );

  String get locationSummary => [
    city ?? '縣市未選',
    if (district.isNotEmpty) district,
    '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
  ].join('・');

  String get vehicleSummary {
    String word(Eligible? v) => v?.label ?? '未選';
    final from = kind == null || vehiclesEdited
        ? ''
        : ruled
        ? '（已依格位與$city規則帶入）'
        : '（已依格位帶入）';
    return '普通機車${word(scooter)}・大型重機${word(heavy)}$from';
  }

  String? get extraSummary {
    final filled = [
      if (lot && entrance.text.trim().isNotEmpty) '入口',
      if (guide.text.trim().isNotEmpty) '停車指引',
      if (evidence.text.trim().isNotEmpty) '公告連結',
      if (note.text.trim().isNotEmpty) '備註',
    ];
    return filled.isEmpty ? null : '已填：${filled.join('、')}';
  }

  /// The position: the map with 放大地圖調整 and the search under it, the
  /// county and district it falls in, same-type spots within 15 m and a
  /// city change (C6 canvas AppFormLocation).
  Widget _locationPart(BuildContext context) {
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
        // The city's rule may open or close bays for a vehicle.
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
    return _part(
      _Part.location,
      title: '位置',
      summary: locationSummary,
      hint: '拖曳標記對準停車格，或點地圖選位置',
      children: [
        Text(
          widget.mapCenter ? '從目前地圖中心開始。' : '從你長按的位置開始。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        FormField<void>(
          validator: (_) =>
              inTaiwanBounds(lat, lng) ? null : '標記不在臺灣範圍內，請移回停車點的位置。',
          builder: (state) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Only while open: a folded section keeps no map running.
              if (open == _Part.location)
                LocationPicker(
                  lat: lat,
                  lng: lng,
                  touchMarker: true,
                  onLocate: widget.store.currentFix,
                  height: pickerHeight(context),
                  mapBuilder: widget.mapBuilder ?? appLocationMap,
                  expandButton: true,
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
          '依地圖位置自動帶入，可以改。選了縣市後，「區」只列這個縣市的行政區。',
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
            text:
                '標記在$city，不是原本帶入的$movedFromCity；適用$city的停車規則'
                '${vehiclesEdited ? '，請確認可停車種。' : '，可停車種已依新規則帶入。'}',
            tone: NoteTone.caution,
          ),
        if (duplicates.isNotEmpty)
          LocationNote(
            key: const ValueKey('report-duplicate'),
            icon: Icons.content_copy,
            text:
                '15 m 內已有同類型的停車點：${duplicates.map((d) => d.name).join('、')}。'
                '如果是同一處，請關閉這個表單，改到該點提出修改建議。',
            tone: NoteTone.caution,
          ),
      ],
    );
  }

  Widget _buildForm(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final found = issues;
    final kind = this.kind;
    final picked = kind == null ? null : condition.conditionFor(kind);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ContentPage(
        lazy: false,
        children: [
          // The same close as every sheet, at the top of a long form.
          SheetTitle('新增停車點'),
          const SizedBox(height: 8),
          Text(
            '新增的停車點會顯示於地圖，回報資訊待管理者確認；停放資格請依現場標示。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
          if (!widget.store.canReport) ...[
            const SizedBox(height: 16),
            SignInPrompt(
              store: widget.store,
              message: '使用 Google 或 Apple 登入後才能送出回報。',
            ),
          ],
          const SizedBox(height: 6),
          _locationPart(context),
          _part(
            _Part.name,
            title: '名稱',
            summary: name.text.trim().isEmpty ? null : name.text.trim(),
            children: [
              TextFormField(
                controller: name,
                maxLength: 100,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: '停車點名稱',
                  errorMaxLines: 4,
                  hintText: '例：信義路五段收費機車格',
                  counterText: '',
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (v) => (v?.trim().isEmpty ?? true)
                    ? '請填寫名稱'
                    : precheckTextHint(v, name: true),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          _part(
            _Part.kind,
            title: '格位',
            summary: kind == null ? null : condition.summary(kind),
            hint: '地面畫的是哪一種？',
            children: [
              FormField<SpaceKind>(
                validator: (_) => this.kind == null ? '請選地面畫的格位' : null,
                builder: (state) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SpaceKindList(
                      value: kind,
                      keyPrefix: 'report-space',
                      reveal: reveal,
                      onChanged: (v) {
                        setKind(v);
                        state.didChange(v);
                      },
                      followUp: kind == null
                          ? null
                          : ConditionFields(
                              kind: kind,
                              draft: condition,
                              onChanged: () => setState(applyDefaults),
                              // Waits for a notice; once one is attached,
                              // nothing to add.
                              holdHint: evidence.text.trim().isEmpty
                                  ? precheckHint(
                                      found,
                                      'condition',
                                      holds: true,
                                    )
                                  : null,
                            ),
                    ),
                    if (state.errorText case final error?)
                      Text(error, style: TextStyle(color: colors.error)),
                  ],
                ),
              ),
              if (kind != null && kind != SpaceKind.offStreet)
                Container(
                  key: const ValueKey('report-preview'),
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(
                          text: 'App 會顯示：',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: conditionHeadline(type!, picked)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (lot)
            _part(
              _Part.lot,
              title: '停車場（選填）',
              summary: switch ([
                if (facilities.isNotEmpty)
                  facilityTypesLabel([
                    for (final t in FacilityType.values)
                      if (facilities.contains(t)) t,
                  ]),
                ?access?.description,
                if (zones.isNotEmpty) '${zones.length} 個分區',
              ]) {
                final List<String> parts when parts.isNotEmpty => parts.join(
                  '・',
                ),
                _ => null,
              },
              hint: '場站型式、停放分類與分區',
              children: [
                FacilityField(
                  value: facilities,
                  onChanged: (v) => setState(() => facilities = v),
                ),
                AccessField(
                  value: access,
                  onChanged: (v) => setState(() => access = v),
                ),
                ZoneEditor(
                  zones: zones,
                  vehicle: widget.store.vehicle,
                  feeHint: (i) => precheckHint(found, 'parking_zones.$i.fee'),
                  feeHold: (i) =>
                      precheckHint(found, 'parking_zones.$i.fee', holds: true),
                  onAdd: () => setState(() => zones.add(ZoneDraft())),
                  onRemove: (zone) => setState(() {
                    zones.remove(zone);
                    zone.dispose();
                  }),
                  onChanged: () => setState(() {}),
                ),
              ],
            ),
          _part(
            _Part.vehicles,
            title: '可停車種',
            summary: vehicleSummary,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${vehiclesEdited || kind == null ? '' : '已依「${kind.label}」${ruled ? '與$city的停車規則' : ''}帶入，可以修改。'}'
                  // What is sent, not what the city rule says now: a
                  // vehicle stays rule-filled after the other is edited.
                  '${ruledVehicles.isEmpty ? '' : '${ruledVehicles.join('、')}是依$city規則算出的建議值，請依現場確認。'}'
                  '兩種車都要選才能送出；現場有告示牌或地面標字時，才選「可停」。'
                  '${lot ? '停車場的官方資料與營運業者公告都沒寫時，選「官方未標示」。' : ''}',
                  style: TextStyle(color: colors.onSurfaceVariant),
                ),
              ),
              EligibilityField(
                label: '普通機車',
                value: scooter,
                notStated: lot,
                keyPrefix: 'report-scooter',
                onChanged: (v) => setState(() {
                  scooter = v;
                  scooterRuled = false;
                  vehiclesEdited = true;
                  problems.remove(_Part.vehicles);
                }),
              ),
              PrecheckHintText(
                precheckHint(found, 'scooter_allowed'),
                key: const ValueKey('precheck-scooter_allowed'),
              ),
              const SizedBox(height: 8),
              EligibilityField(
                label: '大型重機',
                value: heavy,
                notStated: lot,
                keyPrefix: 'report-heavy',
                onChanged: (v) => setState(() {
                  heavy = v;
                  heavyRuled = false;
                  vehiclesEdited = true;
                  problems.remove(_Part.vehicles);
                }),
              ),
              PrecheckHintText(
                precheckHint(found, 'heavy_allowed'),
                key: const ValueKey('precheck-heavy_allowed'),
              ),
            ],
          ),
          _part(
            _Part.fee,
            title: '收費（選填）',
            summary: fee.isEmpty ? null : feeNoteOf(fee),
            children: [
              FeeEditor(
                value: fee,
                initialVehicle: FeeVehicle.of(widget.store.vehicle),
                errorText: precheckHint(found, 'fee'),
                onChanged: (v) => setState(() {
                  fee = v;
                  problems.remove(_Part.fee);
                }),
              ),
            ],
          ),
          _part(
            _Part.extra,
            title: '補充（選填）',
            summary: extraSummary ?? (lot ? '入口、停車指引、公告連結、備註' : '停車指引、公告連結、備註'),
            children: [
              if (lot) ...[
                TextFormField(
                  controller: entrance,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '入口在哪裡',
                    errorMaxLines: 4,
                    hintText: '例：入口在松仁路側，機車走右側坡道',
                    alignLabelWithHint: true,
                  ),
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => textHint(v, 500),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: guide,
                maxLength: 500,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: '停車指引',
                  errorMaxLines: 4,
                  hintText: lot ? '例：B2 機車區靠電梯，重機停最後一排' : '例：格位在便利商店前，靠路口一側',
                  alignLabelWithHint: true,
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (v) => textHint(v, 500),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              EvidenceUrlField(
                controller: evidence,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: note,
                maxLength: 500,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '其他備註',
                  errorMaxLines: 4,
                  hintText: '例：夜間有管理員，假日常客滿',
                  alignLabelWithHint: true,
                ),
                autovalidateMode: AutovalidateMode.onUserInteraction,
                validator: (v) => textHint(v, 500),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
          const SizedBox(height: 20),
          AdaptiveButton(
            label: sending ? '送出中…' : '送出',
            onPressed: sending || !widget.store.canReport
                ? null
                : () async {
                    if (!validateAll()) return;
                    // Each hint already sits under its field; the message
                    // also covers one scrolled out of view.
                    // A hold goes through, flagged for review.
                    final blocking = precheckBlocking(issues);
                    if (blocking.firstOrNull case final issue?) {
                      // Each section a refusal is about opens and is flagged.
                      problems
                        ..clear()
                        ..addAll(blocking.map((i) => partOf(i.field)).nonNulls);
                      if (problems.isNotEmpty) showProblems();
                      return showMessage(context, issue.message);
                    }
                    setState(() => sending = true);
                    await runAction(context, () async {
                      final result = await widget.store.submit(body());
                      if (context.mounted) {
                        Navigator.pop(context);
                        showMessage(context, result);
                      }
                    });
                    if (mounted) setState(() => sending = false);
                  },
          ),
        ],
      ),
    );
  }
}

/// The sections of the new spot form, in order.
enum _Part { location, name, kind, lot, vehicles, fee, extra }

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

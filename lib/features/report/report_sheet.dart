import '../../core/app_version.dart';
import '../auth/sign_in.dart';
import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../domain/eligibility.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_editor.dart';
import '../../ui/version_text.dart';
import '../map/space_type_sheet.dart';
import '../map/vehicle_sheet.dart';

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
    final name =
        user?.userMetadata?['full_name'] as String? ??
        user?.userMetadata?['name'] as String?;
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
    final initial = (name ?? email ?? '').characters.firstOrNull;
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
                CircleAvatar(
                  radius: 24,
                  backgroundColor: signedIn
                      ? colors.primary
                      : colors.surfaceContainerHighest,
                  foregroundColor: signedIn
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                  child: signedIn && initial != null
                      ? Text(
                          initial.toUpperCase(),
                          style: text.titleLarge?.copyWith(
                            color: colors.onPrimary,
                          ),
                        )
                      : Icon(
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

/// Labeled single choice; segments are easier to scan than a dropdown.
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
        const SizedBox(height: 8),
        SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final (value, text) in options)
              ButtonSegment(value: value, label: Text(text)),
          ],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.single),
        ),
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

String _shortFacility(FacilityType type) => switch (type) {
  FacilityType.multiStorey => '立體',
  FacilityType.underground => '地下',
  FacilityType.surface => '平面',
  FacilityType.roadside => '路邊',
};

/// A lot's facility type, as a short single choice.
class FacilityField extends StatelessWidget {
  const FacilityField({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final FacilityType? value;
  final ValueChanged<FacilityType?> onChanged;
  @override
  Widget build(BuildContext context) => ChoiceField<FacilityType?>(
    label: '場站型式',
    value: value,
    options: [
      (null, '未確認'),
      for (final type in lotFacilities) (type, _shortFacility(type)),
    ],
    onChanged: onChanged,
  );
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
  Widget build(BuildContext context) => DropdownButtonFormField<ParkingAccess?>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: [
      const DropdownMenuItem(child: Text('未確認')),
      for (final access in ParkingAccess.values)
        DropdownMenuItem(value: access, child: Text(access.description)),
    ],
    onChanged: onChanged,
  );
}

/// One zone of a lot while it is being reported.
class ZoneDraft {
  final name = TextEditingController();
  final guide = TextEditingController();
  ParkingAccess? access;

  void dispose() {
    name.dispose();
    guide.dispose();
  }

  Map<String, Object> toJson() => {
    'name': name.text.trim(),
    if (access case final access?) 'access': access.name,
    if (guide.text.trim().isNotEmpty) 'guide': guide.text.trim(),
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
  });
  final List<ZoneDraft> zones;
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
          '例如 B2 機車區、1F 汽車區；各區可停車種不同時再分開填。',
          style: TextStyle(color: colors.onSurfaceVariant),
        ),
        for (final (i, zone) in zones.indexed) ...[
          const SizedBox(height: 12),
          Material(
            key: ObjectKey(zone),
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
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
                            hintText: '例：B2 機車區',
                            counterText: '',
                          ),
                          validator: (v) => (v?.trim().isEmpty ?? true)
                              ? '請填寫分區名稱，或刪除此分區'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        AccessField(
                          value: zone.access,
                          onChanged: (v) {
                            zone.access = v;
                            onChanged();
                          },
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: zone.guide,
                          maxLength: 200,
                          decoration: const InputDecoration(
                            labelText: '這區怎麼停（選填）',
                            hintText: '例：靠電梯，重機停最後一排',
                            counterText: '',
                          ),
                        ),
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

/// Bay kinds as their painted markings, so reporters match what is on the
/// ground instead of a list of names.
class SpaceTypePicker extends StatelessWidget {
  const SpaceTypePicker({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final SpaceType value;
  final ValueChanged<SpaceType> onChanged;
  @override
  Widget build(BuildContext context) {
    // Three across on phones; two when large text needs the width.
    final columns = MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 2 : 3;
    const types = SpaceType.values;
    return Column(
      children: [
        for (var row = 0; row < types.length; row += columns)
          Padding(
            padding: EdgeInsets.only(top: row == 0 ? 0 : 8),
            // Tiles in a row share one height, however their labels wrap.
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = row; i < row + columns; i++) ...[
                    if (i > row) const SizedBox(width: 8),
                    Expanded(
                      child: i < types.length
                          ? _tile(context, types[i])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _tile(BuildContext context, SpaceType type) {
    final colors = Theme.of(context).colorScheme;
    final selected = type == value;
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: type.label,
      // The child's tap is excluded with its semantics; screen readers need
      // it here.
      onTap: () => onChanged(type),
      excludeSemantics: true,
      child: Material(
        color: selected ? colors.primaryContainer : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('report-space-${type.name}'),
          onTap: () => onChanged(type),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 10),
            child: Column(
              children: [
                GroundMarking(type: type),
                const SizedBox(height: 8),
                Text(
                  type.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: selected ? FontWeight.w600 : null,
                    color: selected
                        ? colors.onPrimaryContainer
                        : colors.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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
  });
  final AppStore store;
  final double lat, lng;

  /// Whether the point is the map center rather than a long-pressed spot.
  final bool mapCenter;
  @override
  State<ReportForm> createState() => _ReportFormState();
}

class _ReportFormState extends State<ReportForm> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(),
      note = TextEditingController(),
      entrance = TextEditingController(),
      guide = TextEditingController();
  Fee fee = const Fee();
  SpaceType type = SpaceType.paidMotorcycle;
  late bool? scooter = defaults.scooter;
  late bool? heavy = defaults.heavy;
  FacilityType? facility;
  ParkingAccess? access;
  final zones = <ZoneDraft>[];

  bool get lot => type == SpaceType.offStreet;

  ({bool? scooter, bool? heavy}) get defaults =>
      defaultEligibility(widget.store.rules, type, city);

  /// Whether the city's rule, not only the markings, set a vehicle.
  bool get ruled {
    final marked = markedEligibility(type);
    final rule = ruledEligibility(widget.store.rules, type, city);
    return (marked.scooter == null && rule.scooter != null) ||
        (marked.heavy == null && rule.heavy != null);
  }

  /// Once the reporter sets the vehicles, a new bay kind no longer resets them.
  bool vehiclesEdited = false;
  late String? city = nearbyCity(widget.store.spots, widget.lat, widget.lng);
  bool sending = false;
  @override
  void dispose() {
    name.dispose();
    note.dispose();
    entrance.dispose();
    guide.dispose();
    for (final zone in zones) {
      zone.dispose();
    }
    super.dispose();
  }

  void setType(SpaceType value) => setState(() {
    type = value;
    applyDefaults();
  });

  /// Refills the vehicles from the markings and city rule until the
  /// reporter sets them.
  void applyDefaults() {
    if (vehiclesEdited) return;
    scooter = defaults.scooter;
    heavy = defaults.heavy;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) => _buildForm(context),
  );

  Widget _buildForm(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: form,
        child: ContentPage(
          children: [
            // The same close as every sheet, at the top of a long form.
            SheetTitle('新增停車點'),
            const SizedBox(height: 8),
            Text(
              '新增的停車點會顯示於地圖，回報資訊待管理者確認；停放資格請依現場標示。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            Material(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                leading: Icon(Icons.place_outlined, color: colors.primary),
                title: Text(widget.mapCenter ? '位置：目前地圖中心' : '位置：長按的地圖位置'),
                subtitle: Text(
                  '${widget.lat.toStringAsFixed(5)}, '
                  '${widget.lng.toStringAsFixed(5)}'
                  '${widget.mapCenter ? '\n位置不對時，關閉後移動地圖再回報。' : ''}',
                ),
              ),
            ),
            if (!widget.store.canReport) ...[
              const SizedBox(height: 16),
              SignInPrompt(
                store: widget.store,
                message: '使用 Google 或 Apple 登入後才能送出回報。',
              ),
            ],
            FormSection(
              title: '基本資訊',
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 100,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '停車點名稱',
                    hintText: '例：信義路五段收費機車格',
                    counterText: '',
                  ),
                  validator: (v) =>
                      (v?.trim().isEmpty ?? true) ? '請填寫名稱' : null,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: city,
                  decoration: InputDecoration(
                    labelText: '縣市',
                    helperText: city == null ? null : '依附近停車點自動帶入，請確認',
                  ),
                  items: taiwanCities
                      .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                      .toList(),
                  validator: (v) => v == null ? '請選擇停車點所在縣市' : null,
                  onChanged: (v) => setState(() {
                    city = v;
                    // The city's rule may open or close bays for a vehicle.
                    applyDefaults();
                  }),
                ),
                const SizedBox(height: 20),
                Text(
                  '地面畫的是哪一種格位？',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 10),
                SpaceTypePicker(value: type, onChanged: setType),
              ],
            ),
            FormSection(
              title: '可停車種',
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    vehiclesEdited
                        ? '現場有告示牌或地面標字時，才選「可停」。'
                        : '已依「${type.label}」'
                              '${ruled ? '與$city的停車規則' : ''}帶入，可以修改。'
                              '現場有告示牌或地面標字時，才選「可停」。',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                ),
                ChoiceField<bool?>(
                  label: '普通機車',
                  vehicle: VehicleType.scooter,
                  value: scooter,
                  options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
                  onChanged: (v) => setState(() {
                    scooter = v;
                    vehiclesEdited = true;
                  }),
                ),
                ChoiceField<bool?>(
                  label: '大型重機',
                  vehicle: VehicleType.heavy,
                  value: heavy,
                  options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
                  onChanged: (v) => setState(() {
                    heavy = v;
                    vehiclesEdited = true;
                  }),
                ),
              ],
            ),
            if (lot)
              FormSection(
                title: '停車場（選填）',
                children: [
                  FacilityField(
                    value: facility,
                    onChanged: (v) => setState(() => facility = v),
                  ),
                  AccessField(
                    value: access,
                    onChanged: (v) => setState(() => access = v),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: entrance,
                    maxLength: 500,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: '入口在哪裡',
                      hintText: '例：入口在松仁路側，機車走右側坡道',
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ZoneEditor(
                    zones: zones,
                    onAdd: () => setState(() => zones.add(ZoneDraft())),
                    onRemove: (zone) => setState(() {
                      zones.remove(zone);
                      zone.dispose();
                    }),
                    onChanged: () => setState(() {}),
                  ),
                ],
              ),
            FormSection(
              title: '補充資訊（選填）',
              children: [
                Text('收費', style: Theme.of(context).textTheme.bodyLarge),
                const SizedBox(height: 8),
                FeeEditor(
                  value: fee,
                  onChanged: (v) => setState(() => fee = v),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: guide,
                  maxLength: 500,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: '停車指引',
                    hintText: lot ? '例：B2 機車區靠電梯，重機停最後一排' : '例：格位在便利商店前，靠路口一側',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: note,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '其他備註',
                    hintText: '例：夜間有管理員，假日常客滿',
                    alignLabelWithHint: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AdaptiveButton(
              label: sending ? '送出中…' : '送出回報',
              onPressed: sending || !widget.store.canReport
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setState(() => sending = true);
                      await runAction(context, () async {
                        final result = await widget.store.submit({
                          'action': 'create',
                          'spot': {
                            'name': name.text.trim(),
                            'lat': widget.lat,
                            'lng': widget.lng,
                            'city': city,
                            'space_type': type.name,
                            'fee_note': feeNoteOf(fee),
                            if (!fee.isEmpty) 'fee': fee.toJson(),
                            'note': note.text.trim(),
                            if (guide.text.trim().isNotEmpty)
                              'parking_guide': guide.text.trim(),
                            // Lot details only for lots, whatever was typed
                            // before the bay kind changed.
                            if (lot) ...{
                              'facility_type': ?facility?.name,
                              'parking_access': ?access?.name,
                              if (entrance.text.trim().isNotEmpty)
                                'entrance_note': entrance.text.trim(),
                              if (zones.isNotEmpty)
                                'parking_zones': [
                                  for (final zone in zones) zone.toJson(),
                                ],
                            },
                            'scooter_allowed': scooter,
                            'heavy_allowed': heavy,
                          },
                        });
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
        const Text('以目前裝置定位記錄位置。'),
        TextField(
          controller: floor,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '樓層／格位（例如 B2／A18）'),
        ),
        TextField(
          controller: note,
          maxLength: 300,
          decoration: const InputDecoration(labelText: '備註'),
        ),
        DropdownButtonFormField<int>(
          initialValue: minutes,
          decoration: const InputDecoration(labelText: '計時提醒'),
          items: const [
            DropdownMenuItem(value: 0, child: Text('不提醒')),
            DropdownMenuItem(value: 30, child: Text('30 分鐘後')),
            DropdownMenuItem(value: 60, child: Text('1 小時後')),
            DropdownMenuItem(value: 120, child: Text('2 小時後')),
          ],
          onChanged: (v) => setState(() => minutes = v!),
        ),
        const SizedBox(height: 24),
        AdaptiveButton(
          label: saving ? '定位中…' : '儲存停車位置',
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

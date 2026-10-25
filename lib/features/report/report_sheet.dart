import '../../core/app_version.dart';
import '../auth/sign_in.dart';
import '../../core/geo.dart';
import '../../data/app_store.dart';
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
  final name = TextEditingController(), note = TextEditingController();
  Fee fee = const Fee();
  SpaceType type = SpaceType.paidMotorcycle;
  late bool? scooter = markedEligibility(type).scooter;
  late bool? heavy = markedEligibility(type).heavy;

  /// Once the reporter sets the vehicles, a new bay kind no longer resets them.
  bool vehiclesEdited = false;
  late String? city = nearbyCity(widget.store.spots, widget.lat, widget.lng);
  bool sending = false;
  @override
  void dispose() {
    name.dispose();
    note.dispose();
    super.dispose();
  }

  void setType(SpaceType value) => setState(() {
    type = value;
    if (!vehiclesEdited) {
      final marked = markedEligibility(value);
      scooter = marked.scooter;
      heavy = marked.heavy;
    }
  });

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
                  onChanged: (v) => setState(() => city = v),
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
                        : '已依「${type.label}」帶入，可以修改。'
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
                  controller: note,
                  maxLength: 500,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '入口、樓層或其他備註',
                    hintText: '例：B2 入口在松仁路側',
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

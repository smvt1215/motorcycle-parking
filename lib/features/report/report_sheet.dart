import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/geo.dart';
import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';

Future<void> showSettings(BuildContext context, AppStore store) =>
    showAdaptiveSheet<void>(
      context,
      (ctx) => ContentPage(
        children: [
          Text('車種與帳號', style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 16),
          VehicleSelector(
            value: store.vehicle,
            onChanged: (v) {
              store.setVehicle(v);
              Navigator.pop(ctx);
            },
          ),
          const SizedBox(height: 24),
          if (store.demo)
            const Text('目前使用範例資料。回報只用於功能測試，請勿依範例點位停車。')
          else if (store.client!.auth.currentUser == null ||
              store.client!.auth.currentUser!.isAnonymous) ...[
            const Text('登入後可回報停車點與同步收藏。瀏覽與記錄停車位置不需登入。'),
            const SizedBox(height: 16),
            AdaptiveButton(
              label: '使用 Google 登入',
              onPressed: () =>
                  runAction(ctx, () => store.signIn(OAuthProvider.google)),
            ),
            const SizedBox(height: 12),
            if (isCupertino)
              AdaptiveButton(
                label: '使用 Apple 登入',
                onPressed: () =>
                    runAction(ctx, () => store.signIn(OAuthProvider.apple)),
              ),
          ] else ...[
            Text(store.client!.auth.currentUser!.email ?? '已登入'),
            TextButton(
              onPressed: () => runAction(ctx, () async {
                await store.signOut();
                if (ctx.mounted) Navigator.pop(ctx);
              }),
              child: const Text('登出'),
            ),
          ],
          const SizedBox(height: 24),
          TextButton(
            onPressed: () =>
                showLicensePage(context: ctx, applicationName: '機車停車指南'),
            child: const Text('授權資訊'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('關閉'),
          ),
        ],
      ),
    );

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
  });
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyLarge),
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
            AdaptiveButton(
              label: '登入帳號',
              secondary: true,
              onPressed: () => showSettings(context, store),
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
      fee = TextEditingController(),
      note = TextEditingController();
  SpaceType type = SpaceType.paidMotorcycle;
  bool scooter = true;
  bool? heavy;
  late String? city = nearbyCity(widget.store.spots, widget.lat, widget.lng);
  bool sending = false;
  @override
  void dispose() {
    name.dispose();
    fee.dispose();
    note.dispose();
    super.dispose();
  }

  void setType(SpaceType value) => setState(() {
    type = value;
    // Dedicated heavy bays imply the vehicle answers; reporters can still edit.
    if (value == SpaceType.heavyOnly) {
      scooter = false;
      heavy = true;
    }
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Form(
        key: form,
        child: ContentPage(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '新增停車點',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                ),
                // Long form: keep cancel reachable without scrolling.
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '新增點位會顯示於地圖，回報資訊待管理者確認；停放資格請依現場標示。',
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
                const SizedBox(height: 16),
                DropdownButtonFormField<SpaceType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: '格位類型'),
                  items: SpaceType.values
                      .map(
                        (s) => DropdownMenuItem(value: s, child: Text(s.label)),
                      )
                      .toList(),
                  onChanged: (v) => setType(v!),
                ),
              ],
            ),
            FormSection(
              title: '可停車種',
              children: [
                ChoiceField<bool>(
                  label: '普通機車',
                  value: scooter,
                  options: const [(true, '可停'), (false, '不可停')],
                  onChanged: (v) => setState(() => scooter = v),
                ),
                ChoiceField<bool?>(
                  label: '大型重機（依現場標示）',
                  value: heavy,
                  options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
                  onChanged: (v) => setState(() => heavy = v),
                ),
              ],
            ),
            FormSection(
              title: '補充資訊（選填）',
              children: [
                TextFormField(
                  controller: fee,
                  maxLength: 200,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '收費資訊',
                    hintText: '例：每小時 20 元，或免費',
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 16),
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
                            'fee_note': fee.text.trim().isEmpty
                                ? '請依現場公告'
                                : fee.text.trim(),
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
        Text('記錄停車', style: Theme.of(context).textTheme.headlineSmall),
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

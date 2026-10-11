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
  double lng,
) => showAdaptiveSheet<void>(
  context,
  (ctx) => ReportForm(store: store, lat: lat, lng: lng),
);

class ReportForm extends StatefulWidget {
  const ReportForm({
    super.key,
    required this.store,
    required this.lat,
    required this.lng,
  });
  final AppStore store;
  final double lat, lng;
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

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Form(
      key: form,
      child: ContentPage(
        children: [
          Text('新增停車點', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '位置 ${widget.lat.toStringAsFixed(5)}, ${widget.lng.toStringAsFixed(5)}',
          ),
          const SizedBox(height: 16),
          if (!widget.store.canReport) ...[
            const Text('請先使用 Google 或 Apple 登入，才能新增或確認社群資訊。'),
            TextButton(
              onPressed: () => showSettings(context, widget.store),
              child: const Text('登入帳號'),
            ),
          ],
          TextFormField(
            controller: name,
            maxLength: 100,
            decoration: const InputDecoration(labelText: '停車點名稱'),
            validator: (v) => (v?.trim().isEmpty ?? true) ? '請填寫名稱' : null,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: city,
            decoration: const InputDecoration(labelText: '縣市'),
            items: taiwanCities
                .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                .toList(),
            validator: (v) => v == null ? '請選擇停車點所在縣市' : null,
            onChanged: (v) => setState(() => city = v),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<SpaceType>(
            initialValue: type,
            decoration: const InputDecoration(labelText: '格位類型'),
            items: SpaceType.values
                .map((s) => DropdownMenuItem(value: s, child: Text(s.label)))
                .toList(),
            onChanged: (v) => setState(() => type = v!),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('普通機車可停'),
            value: scooter,
            onChanged: (v) => setState(() => scooter = v),
          ),
          DropdownButtonFormField<String>(
            initialValue: heavy == null
                ? 'unknown'
                : heavy!
                ? 'yes'
                : 'no',
            decoration: const InputDecoration(labelText: '大型重機'),
            items: const [
              DropdownMenuItem(value: 'unknown', child: Text('尚未確認')),
              DropdownMenuItem(value: 'yes', child: Text('現場標示可停')),
              DropdownMenuItem(value: 'no', child: Text('現場標示不可停')),
            ],
            onChanged: (v) =>
                setState(() => heavy = v == 'unknown' ? null : v == 'yes'),
          ),
          TextFormField(
            controller: fee,
            maxLength: 200,
            decoration: const InputDecoration(labelText: '收費資訊（選填）'),
          ),
          TextFormField(
            controller: note,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(labelText: '入口、樓層或其他備註（選填）'),
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    ),
  );
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

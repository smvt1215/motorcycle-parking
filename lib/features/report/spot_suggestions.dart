import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'report_sheet.dart';

Future<void> showSpotSuggestions(
  BuildContext context,
  AppStore store,
  ParkingSpot spot,
) => showAdaptiveSheet<void>(
  context,
  (ctx) => SizedBox(
    height: MediaQuery.sizeOf(ctx).height * .74,
    child: Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            children: [
              Text('提出修改建議', style: Theme.of(ctx).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(
                spot.name,
                style: TextStyle(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              Material(
                color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final item in [
                      ('停車點名稱', Icons.storefront_outlined),
                      ('格位類型', Icons.category_outlined),
                      ('收費資訊', Icons.payments_outlined),
                      ('機車停放資格', Icons.two_wheeler),
                      ('位置或其他備註', Icons.location_on_outlined),
                    ]) ...[
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        leading: Icon(
                          item.$2,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                        title: Text(item.$1),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showAdaptiveSheet<void>(
                          ctx,
                          (formContext) => _SuggestionForm(
                            store: store,
                            spot: spot,
                            field: item.$1,
                          ),
                        ),
                      ),
                      if (item.$1 != '位置或其他備註')
                        const Divider(height: 1, indent: 20, endIndent: 20),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Material(
                color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  leading: Icon(
                    Icons.location_off_outlined,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
                  title: const Text('點位已不存在'),
                  subtitle: const Text('格位已撤除，或此處已無法停車'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showAdaptiveSheet<void>(
                    ctx,
                    (formContext) => _SuggestionForm(
                      store: store,
                      spot: spot,
                      field: '點位已不存在',
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text('建議會送交審核，通過後再更新停車資訊。'),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: SizedBox(
              width: double.infinity,
              child: AdaptiveButton(
                label: '取消',
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

class _SuggestionForm extends StatefulWidget {
  const _SuggestionForm({
    required this.store,
    required this.spot,
    required this.field,
  });
  final AppStore store;
  final ParkingSpot spot;
  final String field;
  @override
  State<_SuggestionForm> createState() => _SuggestionFormState();
}

class _SuggestionFormState extends State<_SuggestionForm> {
  final form = GlobalKey<FormState>();
  final note = TextEditingController();
  bool sending = false, sent = false;
  String? error;
  bool get unavailable => widget.field == '點位已不存在';
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.store.submit({
        'action': 'flag',
        'source_id': widget.spot.id,
        'reason': '${widget.field}：${note.text.trim()}',
      });
      if (mounted) setState(() => sent = true);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is StateError ? e.message.toString() : '建議尚未送出，請稍後重試',
        );
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: Form(
      key: form,
      child: ContentPage(
        children: [
          Text(widget.field, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          Text(widget.spot.name),
          const SizedBox(height: 20),
          if (sent) ...[
            const Icon(Icons.check_circle_outline, size: 48),
            const SizedBox(height: 12),
            Text(
              widget.store.demo
                  ? '範例建議已送出，僅供本次功能測試。'
                  : unavailable
                  ? '不存在回報已送出，等待審核。'
                  : '建議已送出，等待審核。',
            ),
            const SizedBox(height: 20),
            AdaptiveButton(
              label: '完成',
              onPressed: () => Navigator.pop(context),
            ),
          ] else ...[
            if (!widget.store.canReport)
              TextButton(
                onPressed: () => showSettings(context, widget.store),
                child: const Text('登入後提出建議'),
              ),
            if (unavailable) ...[
              const Text('請描述格位撤除、施工或封閉等現場狀況，審核後更新點位。'),
              const SizedBox(height: 16),
            ],
            TextFormField(
              key: const ValueKey('suggestion-input'),
              controller: note,
              maxLength: 450,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: unavailable ? '請說明現場狀況' : '建議的正確資訊',
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '請填寫建議內容';
                if (v.length > 450) return '建議內容請縮短至 450 個字元以內';
                return null;
              },
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            AdaptiveButton(
              label: sending
                  ? '送出中…'
                  : unavailable
                  ? '送出回報'
                  : '送出建議',
              onPressed: sending || !widget.store.canReport ? null : submit,
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

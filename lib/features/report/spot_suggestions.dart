import '../../data/app_store.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import 'report_sheet.dart';

String _yesNo(bool? value) => switch (value) {
  true => '可停',
  false => '不可停',
  null => '未確認',
};

/// Eligibility as reported on the spot, shown so people know what they fix.
String eligibilitySummary(ParkingSpot spot) =>
    '普通機車${_yesNo(spot.scooterAllowed)} · 大型重機${_yesNo(spot.heavyAllowed)}';

/// The fields a suggestion can correct, with the value currently shown.
List<(String, IconData, String)> suggestionFields(ParkingSpot spot) => [
  ('停車點名稱', Icons.storefront_outlined, spot.name),
  ('格位類型', Icons.category_outlined, spot.spaceType.label),
  ('收費資訊', Icons.payments_outlined, spot.feeNote),
  ('機車停放資格', Icons.two_wheeler, eligibilitySummary(spot)),
  (
    '位置或其他備註',
    Icons.location_on_outlined,
    spot.note.isEmpty ? '未提供' : spot.note,
  ),
];

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
              SheetTitle('提出修改建議'),
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
                    for (final item in suggestionFields(spot)) ...[
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
                        subtitle: Text(
                          '目前：${item.$3}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showSuggestionForm(
                          ctx,
                          store,
                          spot,
                          field: item.$1,
                          current: item.$3,
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
                  onTap: () =>
                      _showSuggestionForm(ctx, store, spot, field: '點位已不存在'),
                ),
              ),
              const SizedBox(height: 20),
              const Text('建議會送交審核，通過後再更新停車資訊。'),
            ],
          ),
        ),
      ],
    ),
  ),
);

Future<void> _showSuggestionForm(
  BuildContext context,
  AppStore store,
  ParkingSpot spot, {
  required String field,
  String? current,
}) async {
  var submitted = false;
  await showAdaptiveSheet<void>(
    context,
    (_) => _SuggestionForm(
      store: store,
      spot: spot,
      field: field,
      current: current,
      onSubmitted: () => submitted = true,
    ),
  );
  // Any dismissal after success (Done, close, back or drag) closes the picker
  // too. Cancelling or a failed request keeps it available for another edit.
  if (submitted && context.mounted) Navigator.pop(context);
}

class _SuggestionForm extends StatefulWidget {
  const _SuggestionForm({
    required this.store,
    required this.spot,
    required this.field,
    required this.onSubmitted,
    this.current,
  });
  final AppStore store;
  final ParkingSpot spot;
  final String field;
  final VoidCallback onSubmitted;

  /// The value shown today; null for the "no longer exists" report.
  final String? current;
  @override
  State<_SuggestionForm> createState() => _SuggestionFormState();
}

class _SuggestionFormState extends State<_SuggestionForm> {
  final form = GlobalKey<FormState>();
  final note = TextEditingController();
  bool sending = false, sent = false;
  String? error;
  late SpaceType type = widget.spot.spaceType;
  late bool? scooter = widget.spot.scooterAllowed;
  late bool? heavy = widget.spot.heavyAllowed;
  bool get unavailable => widget.field == '點位已不存在';
  bool get typeField => widget.field == '格位類型';
  bool get eligibilityField => widget.field == '機車停放資格';

  /// Structured fields submit the chosen value; the note becomes optional.
  bool get structured => typeField || eligibilityField;

  String reason() {
    final text = note.text.trim();
    if (!structured) return '${widget.field}：$text';
    final value = typeField
        ? type.label
        : '普通機車${_yesNo(scooter)} · 大型重機${_yesNo(heavy)}';
    return '${widget.field}：建議「$value」${text.isEmpty ? '' : '；說明：$text'}';
  }

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
        'reason': reason(),
      });
      if (mounted) {
        widget.onSubmitted();
        setState(() => sent = true);
      }
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
          SheetTitle(widget.field),
          const SizedBox(height: 8),
          Text(
            widget.spot.name,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          if (widget.current != null && !sent) ...[
            Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(16),
              child: ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('目前顯示'),
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
            if (!widget.store.canReport) ...[
              SignInPrompt(
                store: widget.store,
                message: '使用 Google 或 Apple 登入後才能送出建議。',
              ),
              const SizedBox(height: 20),
            ],
            if (typeField) ...[
              DropdownButtonFormField<SpaceType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: '正確的格位類型'),
                items: SpaceType.values
                    .map(
                      (s) => DropdownMenuItem(value: s, child: Text(s.label)),
                    )
                    .toList(),
                validator: (v) =>
                    v == widget.spot.spaceType ? '請選擇與目前不同的格位類型' : null,
                onChanged: (v) => setState(() => type = v!),
              ),
              const SizedBox(height: 20),
            ],
            if (eligibilityField) ...[
              ChoiceField<bool?>(
                label: '普通機車',
                value: scooter,
                options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
                onChanged: (v) => setState(() => scooter = v),
              ),
              ChoiceField<bool?>(
                label: '大型重機（依現場標示）',
                value: heavy,
                options: const [(null, '未確認'), (true, '可停'), (false, '不可停')],
                onChanged: (v) => setState(() => heavy = v),
              ),
              const SizedBox(height: 4),
            ],
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
                labelText: unavailable
                    ? '請說明現場狀況'
                    : structured
                    ? '補充說明（選填）'
                    : '建議的正確資訊',
                hintText: unavailable
                    ? '例：格線已撤除，改為人行道'
                    : structured
                    ? '例：入口處有重機可停的告示'
                    : '請填寫現場看到的正確內容',
              ),
              validator: (v) {
                if (eligibilityField &&
                    scooter == widget.spot.scooterAllowed &&
                    heavy == widget.spot.heavyAllowed) {
                  return '請至少修改一項停放資格';
                }
                if (!structured && (v == null || v.trim().isEmpty)) {
                  return '請填寫建議內容';
                }
                if ((v?.length ?? 0) > 450) return '建議內容請縮短至 450 個字元以內';
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

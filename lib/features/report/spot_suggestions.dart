import '../../data/app_store.dart';
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../ui/adaptive/adaptive.dart';
import '../../ui/fee_editor.dart';
import 'report_sheet.dart';

String _yesNo(bool? value) => switch (value) {
  true => '可停',
  false => '不可停',
  null => '未確認',
};

/// Eligibility as reported on the spot, shown so people know what they fix.
String eligibilitySummary(ParkingSpot spot) =>
    _eligibility(spot.scooterAllowed, spot.heavyAllowed);

String _eligibility(bool? scooter, bool? heavy) =>
    '普通機車${_yesNo(scooter)} · 大型重機${_yesNo(heavy)}';

/// A correctable field: the stable key sent as `field` (docs/ADMIN_WEB.md),
/// the label people read, and the value shown today.
typedef SuggestionField = ({
  String key,
  String label,
  IconData icon,
  String current,
});

/// The fields a suggestion can correct, with the value currently shown.
List<SuggestionField> suggestionFields(ParkingSpot spot) => [
  (
    key: 'name',
    label: '停車點名稱',
    icon: Icons.storefront_outlined,
    current: spot.name,
  ),
  (
    key: 'space_type',
    label: '格位類型',
    icon: Icons.category_outlined,
    current: spot.spaceType.label,
  ),
  (
    key: 'fee_note',
    label: '收費資訊',
    icon: Icons.payments_outlined,
    current: spot.feeNote,
  ),
  (
    key: 'eligibility',
    label: '機車停放資格',
    icon: Icons.two_wheeler,
    current: eligibilitySummary(spot),
  ),
  (
    key: 'note',
    label: '位置或其他備註',
    icon: Icons.location_on_outlined,
    current: spot.note.isEmpty ? '未提供' : spot.note,
  ),
];

/// The report that the spot can no longer be parked at.
const goneLabel = '這裡已經不能停車';

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
              const SizedBox(height: 12),
              const Text('選一項你在現場看到不一樣的資訊。審核通過後才會更新地圖。'),
              const SizedBox(height: 20),
              Material(
                color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (final (i, item) in suggestionFields(spot).indexed) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 20, endIndent: 20),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        leading: Icon(
                          item.icon,
                          color: Theme.of(ctx).colorScheme.primary,
                        ),
                        title: Text(item.label),
                        subtitle: Text(
                          '目前：${item.current}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showSuggestionForm(
                          ctx,
                          store,
                          spot,
                          fieldKey: item.key,
                          label: item.label,
                          current: item.current,
                        ),
                      ),
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
                  title: const Text(goneLabel),
                  subtitle: const Text('格線撤除、施工或封閉'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showSuggestionForm(
                    ctx,
                    store,
                    spot,
                    fieldKey: 'gone',
                    label: goneLabel,
                  ),
                ),
              ),
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
  required String fieldKey,
  required String label,
  String? current,
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
  if (submitted && context.mounted) Navigator.pop(context);
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
  late SpaceType type = widget.spot.spaceType;
  late bool? scooter = widget.spot.scooterAllowed;
  late bool? heavy = widget.spot.heavyAllowed;

  /// The suggested fee; starts unconfirmed because the map only has text.
  Fee fee = const Fee();

  String get fieldKey => widget.fieldKey;
  bool get unavailable => fieldKey == 'gone';
  bool get typeField => fieldKey == 'space_type';
  bool get eligibilityField => fieldKey == 'eligibility';
  bool get feeField => fieldKey == 'fee_note';

  /// Structured fields submit the chosen value; the note becomes optional.
  bool get structured => typeField || eligibilityField || feeField;

  /// The longest text the spot column takes, so an applied value fits.
  int get maxLength => fieldKey == 'name' ? 100 : 450;

  String reason() {
    final text = note.text.trim();
    if (!structured) return '${widget.label}：$text';
    final value = typeField
        ? type.label
        : feeField
        ? feeNoteOf(fee)
        : _eligibility(scooter, heavy);
    return '${widget.label}：建議「$value」${text.isEmpty ? '' : '；說明：$text'}';
  }

  /// The value the admin applies, keyed by spot column (docs/ADMIN_WEB.md);
  /// null when the suggestion is only free text. Columns follow the table
  /// limits so an applied value never fails them.
  Map<String, Object?>? proposed() {
    final text = note.text.trim();
    final spot = widget.spot;
    if (typeField) return {'space_type': type.name};
    // The text beside the fee is built from it, so the two never disagree.
    if (feeField) return {'fee': fee.toJson(), 'fee_note': feeNoteOf(fee)};
    if (eligibilityField) {
      return {
        if (scooter != spot.scooterAllowed) 'scooter_allowed': scooter,
        if (heavy != spot.heavyAllowed) 'heavy_allowed': heavy,
      };
    }
    if (unavailable) {
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
        if (type != spot.spaceType)
          line(widget.label, spot.spaceType.label, type.label),
      ];
    }
    // Only the vehicles that change, so riders need not compare two lists.
    if (eligibilityField) {
      return [
        if (scooter != spot.scooterAllowed)
          line('普通機車', _yesNo(spot.scooterAllowed), _yesNo(scooter)),
        if (heavy != spot.heavyAllowed)
          line('大型重機', _yesNo(spot.heavyAllowed), _yesNo(heavy)),
      ];
    }
    if (feeField) {
      final complete = [
        fee.scooter,
        fee.heavy,
      ].every((rate) => rate == null || rate.complete);
      return fee.isEmpty || !complete
          ? const []
          : [line(widget.label, widget.current ?? '', feeNoteOf(fee))];
    }
    if (unavailable || text.isEmpty) return const [];
    return [line(widget.label, widget.current ?? '', text)];
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
      final value = proposed();
      await widget.store.submit({
        'action': 'flag',
        'source_id': widget.spot.id,
        // Older servers and Dashboard reviews read only the summary.
        'reason': reason(),
        'field': fieldKey,
        'proposed': ?value,
        // The text is the value itself for name and fee suggestions.
        if (value == null || structured || unavailable)
          'note': note.text.trim(),
      });
      if (mounted) {
        widget.onSubmitted();
        setState(() => sent = true);
      }
    } catch (e) {
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
                  validator: (v) =>
                      v == widget.spot.spaceType ? '這和目前的格位類型相同，請選擇另一種' : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('地面畫的是哪一種格位？', style: text.bodyLarge),
                      const SizedBox(height: 10),
                      SpaceTypePicker(
                        value: type,
                        onChanged: (v) {
                          state.didChange(v);
                          setState(() => type = v);
                        },
                      ),
                      fieldError(context, state.errorText),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (eligibilityField) ...[
                FormField<(bool?, bool?)>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) =>
                      scooter == widget.spot.scooterAllowed &&
                          heavy == widget.spot.heavyAllowed
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
                      ChoiceField<bool?>(
                        label: '普通機車',
                        vehicle: VehicleType.scooter,
                        value: scooter,
                        options: const [
                          (null, '未確認'),
                          (true, '可停'),
                          (false, '不可停'),
                        ],
                        onChanged: (v) {
                          setState(() => scooter = v);
                          state.didChange((scooter, heavy));
                        },
                      ),
                      ChoiceField<bool?>(
                        label: '大型重機',
                        vehicle: VehicleType.heavy,
                        value: heavy,
                        options: const [
                          (null, '未確認'),
                          (true, '可停'),
                          (false, '不可停'),
                        ],
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
              if (feeField) ...[
                FormField<Fee>(
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (_) => fee.isEmpty ? '請至少選一個車種的收費方式' : null,
                  builder: (state) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '現場收費牌怎麼寫？不確定的車種維持「未確認」。',
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      FeeEditor(
                        value: fee,
                        errorText: state.errorText,
                        onChanged: (v) {
                          setState(() => fee = v);
                          state.didChange(v);
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (unavailable) ...[
                const Text('說明你看到的狀況。如果只是暫時封閉，請寫出原因或預計恢復時間。'),
                const SizedBox(height: 16),
              ],
              TextFormField(
                key: const ValueKey('suggestion-input'),
                controller: note,
                maxLength: maxLength,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  // At the top of the four lines, not floating mid-field.
                  alignLabelWithHint: true,
                  labelText: unavailable
                      ? '現場狀況'
                      : structured
                      ? '你在現場看到什麼？（選填）'
                      : '正確的${widget.label}',
                  hintText: switch (fieldKey) {
                    'gone' => '例：格線已塗銷，改成人行道',
                    'space_type' || 'eligibility' => '例：入口告示寫「大型重機可停」',
                    'name' => '例：信義路五段收費機車格',
                    'fee_note' => '例：入口收費牌寫「機車每次 20 元」',
                    _ => '例：入口在松仁路側，B2',
                  },
                ),
                validator: (v) {
                  final empty = v == null || v.trim().isEmpty;
                  if (unavailable && empty) return '請填寫現場狀況';
                  if (!structured && !unavailable && empty) {
                    return '請填寫正確的${widget.label}';
                  }
                  if ((v?.length ?? 0) > maxLength) {
                    return '最多 $maxLength 字，請刪減後再送出';
                  }
                  return null;
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
}

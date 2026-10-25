import 'package:material_ui/material_ui.dart';

import '../models/fee.dart';

/// Edits a [Fee] as choices, one block per vehicle; shared by the app's
/// report forms and the admin site. The amount fields join the enclosing
/// [Form], so a missing or out-of-range amount blocks submitting.
class FeeEditor extends StatelessWidget {
  const FeeEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.errorText,
    this.showPreview = true,
  });
  final Fee value;
  final ValueChanged<Fee> onChanged;

  /// A whole-fee error from the caller's own check, shown under the preview.
  final String? errorText;

  /// Off when the caller shows the resulting text itself.
  final bool showPreview;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final complete = [
      value.scooter,
      value.heavy,
    ].every((rate) => rate == null || rate.complete);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RateEditor(
          key: const ValueKey('fee-scooter'),
          label: '普通機車',
          heavy: false,
          value: value.scooter,
          onChanged: (rate) =>
              onChanged(Fee(scooter: rate, heavy: value.heavy)),
        ),
        const SizedBox(height: 16),
        RateEditor(
          key: const ValueKey('fee-heavy'),
          label: '大型重機',
          heavy: true,
          value: value.heavy,
          onChanged: (rate) =>
              onChanged(Fee(scooter: value.scooter, heavy: rate)),
        ),
        if (showPreview) ...[
          const SizedBox(height: 12),
          // What the map will show, so the choices read back as a sentence.
          Text(
            complete ? '顯示為：${feeNoteOf(value)}' : '請填完金額，才會顯示費率',
            key: const ValueKey('fee-preview'),
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
        if (errorText case final error?) ...[
          const SizedBox(height: 8),
          Text(error, style: TextStyle(color: colors.error)),
        ],
      ],
    );
  }
}

String _modeLabel(FeeMode mode) => switch (mode) {
  FeeMode.free => '免費',
  FeeMode.posted => '依現場公告',
  FeeMode.hourly => '計時',
  FeeMode.perVisit => '計次',
  FeeMode.daily => '每日',
  FeeMode.sameAsScooter => '比照機車費率',
  FeeMode.sameAsCar => '比照汽車費率',
};

/// Billing periods offered for hourly rates, in minutes.
const _periods = [15, 30, 60, 120, 180, 240, 360, 480, 720, 1440];

/// Limits offered for one per-visit charge, in minutes.
const _limits = [60, 120, 180, 240, 360, 480, 720, 1440];

String _minutes(int minutes) => minutes % 60 == 0
    ? (minutes == 60 ? '1 小時' : '${minutes ~/ 60} 小時')
    : '$minutes 分鐘';

/// One vehicle's rate: how it pays, then only the amounts that mode needs.
class RateEditor extends StatefulWidget {
  const RateEditor({
    super.key,
    required this.label,
    required this.heavy,
    required this.value,
    required this.onChanged,
  });
  final String label;

  /// Heavy bikes may also follow the scooter or car rate.
  final bool heavy;
  final Rate? value;
  final ValueChanged<Rate?> onChanged;
  @override
  State<RateEditor> createState() => _RateEditorState();
}

class _RateEditorState extends State<RateEditor> {
  late final amount = TextEditingController(
    text: widget.value?.amount?.toString() ?? '',
  );
  late final cap = TextEditingController(
    text: widget.value?.dailyCap?.toString() ?? '',
  );

  @override
  void dispose() {
    amount.dispose();
    cap.dispose();
    super.dispose();
  }

  Rate? get rate => widget.value;

  void emit({
    FeeMode? mode,
    bool clear = false,
    int? perMinutes,
    int? maxMinutes,
    bool clearLimit = false,
  }) {
    if (clear) return widget.onChanged(null);
    final m = mode ?? rate!.mode;
    widget.onChanged(
      Rate(
        m,
        amount: int.tryParse(amount.text.trim()),
        perMinutes: m == FeeMode.hourly
            ? perMinutes ?? rate?.perMinutes ?? 60
            : null,
        dailyCap: m == FeeMode.hourly ? int.tryParse(cap.text.trim()) : null,
        maxMinutes: m == FeeMode.perVisit && !clearLimit
            ? maxMinutes ?? rate?.maxMinutes
            : null,
      ),
    );
  }

  String? yuan(String? v, {required bool required}) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) return required ? '請填寫金額' : null;
    final n = int.tryParse(text);
    if (n == null || n < 0 || n > 10000) return '請填 0 到 10000 的整數';
    return null;
  }

  Widget amountField(String label, TextEditingController c, String? hint) =>
      TextFormField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          suffixText: '元',
          hintText: hint,
        ),
        validator: (v) => yuan(v, required: c == amount),
        onChanged: (_) => emit(),
      );

  @override
  Widget build(BuildContext context) {
    final modes = [
      FeeMode.free,
      FeeMode.posted,
      FeeMode.hourly,
      FeeMode.perVisit,
      FeeMode.daily,
      if (widget.heavy) ...[FeeMode.sameAsScooter, FeeMode.sameAsCar],
    ];
    final mode = rate?.mode;
    final details = <Widget>[
      if (mode == FeeMode.hourly) ...[
        amountField('金額', amount, '20'),
        DropdownButtonFormField<int>(
          initialValue: rate?.perMinutes ?? 60,
          decoration: const InputDecoration(labelText: '計費時間'),
          items: [
            for (final m in _periods)
              DropdownMenuItem(value: m, child: Text('每 ${_minutes(m)}')),
          ],
          onChanged: (v) => emit(perMinutes: v),
        ),
        amountField('當日上限（選填）', cap, null),
      ],
      if (mode == FeeMode.perVisit) ...[
        amountField('每次金額', amount, '20'),
        DropdownButtonFormField<int?>(
          initialValue: rate?.maxMinutes,
          decoration: const InputDecoration(labelText: '一次可停（選填）'),
          items: [
            const DropdownMenuItem(child: Text('不限時')),
            for (final m in _limits)
              DropdownMenuItem(value: m, child: Text(_minutes(m))),
          ],
          onChanged: (v) => emit(maxMinutes: v, clearLimit: v == null),
        ),
      ],
      if (mode == FeeMode.daily) amountField('每日金額', amount, '30'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<FeeMode?>(
          key: ValueKey('fee-mode-${widget.heavy ? 'heavy' : 'scooter'}'),
          initialValue: mode,
          decoration: InputDecoration(labelText: '${widget.label}收費方式'),
          items: [
            const DropdownMenuItem(child: Text('未確認')),
            for (final m in modes)
              DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
          ],
          onChanged: (v) => v == null ? emit(clear: true) : emit(mode: v),
        ),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 12),
          // Side by side when the pane is wide enough, stacked on phones.
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 12.0;
              final wide = constraints.maxWidth >= 520;
              final width = wide
                  ? (constraints.maxWidth - gap * (details.length - 1)) /
                        details.length
                  : constraints.maxWidth;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final field in details)
                    SizedBox(width: width, child: field),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

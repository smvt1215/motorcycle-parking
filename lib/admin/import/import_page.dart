import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/fee.dart';
import '../admin_theme.dart';
import '../review/review_page.dart' show ChangeBand, reviewCompactWidth;
import 'fee_reading.dart';
import 'file_pick.dart';
import 'import_controller.dart';
import 'import_models.dart';

/// `/imports` (a spots.json file) and `/imports/fees` (fee conversion).
class ImportPage extends StatefulWidget {
  const ImportPage({
    super.key,
    required this.imports,
    required this.fees,
    required this.feeSection,
    this.pickFile = pickJsonFile,
  });
  final ImportController imports;
  final FeeConversionController fees;

  /// Whether the fee conversion section is open.
  final bool feeSection;
  final FilePicker pickFile;

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final note = TextEditingController();
  final date = TextEditingController();

  /// Entries whose changes are open; conflicts are always open.
  final Set<String> open = {};

  ImportController get imports => widget.imports;
  FeeConversionController get fees => widget.fees;

  @override
  void initState() {
    super.initState();
    date.text = imports.effectiveDate;
  }

  @override
  void dispose() {
    note.dispose();
    date.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final PickedFile? file;
    try {
      file = await widget.pickFile();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('無法讀取這個檔案，請重新選擇。')));
      return;
    }
    if (file == null) return;
    open.clear();
    await imports.load(file.name, file.text);
    if (mounted) date.text = imports.effectiveDate;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([imports, fees]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < reviewCompactWidth;
        final gutter = compact ? 16.0 : 24.0;
        final body = widget.feeSection
            ? _FeeSection(
                fees: fees,
                compact: compact,
                gutter: gutter,
                note: note,
              )
            : _FileSection(
                imports: imports,
                compact: compact,
                gutter: gutter,
                open: open,
                onToggleOpen: (id) => setState(
                  () => open.contains(id) ? open.remove(id) : open.add(id),
                ),
                onChoose: _choose,
                note: note,
                date: date,
              );
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 0),
                  child: _Sections(fees: widget.feeSection),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Sections extends StatelessWidget {
  const _Sections({required this.fees});
  final bool fees;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: false, label: Text('匯入檔案')),
        ButtonSegment(value: true, label: Text('費率轉換')),
      ],
      selected: {fees},
      onSelectionChanged: (s) =>
          context.go(s.single ? '/imports/fees' : '/imports'),
    ),
  );
}

/// Shared frame: a scrolling list with a fixed action bar below it.
class _Frame extends StatelessWidget {
  const _Frame({
    required this.gutter,
    required this.header,
    required this.itemCount,
    required this.itemBuilder,
    this.bar,
  });
  final double gutter;
  final List<Widget> header;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final Widget? bar;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: SelectionArea(
          child: ListView.builder(
            padding: EdgeInsets.fromLTRB(gutter, 20, gutter, 32),
            itemCount: header.length + itemCount,
            itemBuilder: (context, i) => i < header.length
                ? header[i]
                : itemBuilder(context, i - header.length),
          ),
        ),
      ),
      ?bar,
    ],
  );
}

class _Intro extends StatelessWidget {
  const _Intro({required this.title, required this.text});
  final String title, text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Its own node, so the heading is not read with the text below it.
        Semantics(
          container: true,
          header: true,
          child: Text(title, style: theme.textTheme.headlineMedium),
        ),
        const SizedBox(height: 8),
        Text(text, style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// A filter that also states how many items it holds.
class _Filter extends StatelessWidget {
  const _Filter({
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    this.color,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // The button is the node; this only adds that it is the chosen filter.
    return Semantics(
      selected: selected,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: icon == null
            ? null
            : Icon(icon, size: 18, color: selected ? colors.surface : color),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: const StadiumBorder(),
          foregroundColor: selected ? colors.surface : colors.onSurface,
          backgroundColor: selected ? colors.onSurface : null,
        ),
      ),
    );
  }
}

({IconData icon, Color color}) _statusLook(
  ImportStatus status,
  ColorScheme colors,
) => switch (status) {
  ImportStatus.added => (
    icon: Icons.add_location_alt_outlined,
    color: colors.primary,
  ),
  ImportStatus.update => (icon: Icons.edit_note, color: colors.primary),
  ImportStatus.conflict => (
    icon: Icons.front_hand_outlined,
    color: colors.error,
  ),
  ImportStatus.unchanged => (icon: Icons.check, color: colors.onSurfaceVariant),
  ImportStatus.existing => (
    icon: Icons.people_outline,
    color: colors.onSurfaceVariant,
  ),
  ImportStatus.invalid => (icon: Icons.block, color: colors.error),
};

class _StatusTag extends StatelessWidget {
  const _StatusTag(this.status);
  final ImportStatus status;

  @override
  Widget build(BuildContext context) {
    final look = _statusLook(status, Theme.of(context).colorScheme);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(look.icon, size: 18, color: look.color),
        const SizedBox(width: 4),
        Text(
          status.label,
          style: TextStyle(color: look.color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

class _FileSection extends StatelessWidget {
  const _FileSection({
    required this.imports,
    required this.compact,
    required this.gutter,
    required this.open,
    required this.onToggleOpen,
    required this.onChoose,
    required this.note,
    required this.date,
  });
  final ImportController imports;
  final bool compact;
  final double gutter;
  final Set<String> open;
  final ValueChanged<String> onToggleOpen;
  final VoidCallback onChoose;
  final TextEditingController note, date;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final loaded = imports.entries.isNotEmpty;
    final visible = imports.visible;
    final choose = loaded
        ? OutlinedButton.icon(
            onPressed: imports.loading || imports.applying ? null : onChoose,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('改選其他檔案'),
          )
        : FilledButton.icon(
            onPressed: imports.loading ? null : onChoose,
            icon: const Icon(Icons.file_open_outlined),
            label: const Text('選擇 spots.json'),
          );
    final header = <Widget>[
      const _Intro(
        title: '匯入停車資料',
        text:
            '選擇 tool/import_mymaps.py 產生的 spots.json（官方點或社群點），先試算會新增、更新哪些點位，再勾選要匯入的項目。'
            '管理員改過的欄位預設保留，隱藏狀態與生效日期不會被匯入改變。',
      ),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          choose,
          if (imports.fileName != null && loaded)
            Text(
              '${imports.fileName}：${imports.entries.length} 筆'
              '${imports.feesRead == 0 ? '' : '，其中 ${imports.feesRead} 筆由收費資訊轉出結構化費率'}',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
        ],
      ),
      const SizedBox(height: 16),
      if (imports.loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (imports.error != null) ...[
        AdminNotice(imports.error!, error: true),
        const SizedBox(height: 16),
      ],
      if (imports.result case final result?) ...[
        AdminNotice(_resultText(result, imported: true)),
        const SizedBox(height: 16),
      ],
      if (loaded) ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _Filter(
              label: '全部 ${imports.entries.length}',
              selected: imports.filter == null,
              onPressed: () => imports.setFilter(null),
            ),
            for (final s in ImportStatus.values)
              if (imports.count(s) > 0)
                _Filter(
                  label: '${s.label} ${imports.count(s)}',
                  icon: _statusLook(s, colors).icon,
                  color: _statusLook(s, colors).color,
                  selected: imports.filter == s,
                  onPressed: () => imports.setFilter(s),
                ),
          ],
        ),
        const SizedBox(height: 12),
        if (compact)
          ..._phoneFields([
            if (imports.needsDate)
              _dateField(date, imports.setEffectiveDate, imports.validDate),
            _noteField(note),
          ]),
        if (visible.any((e) => e.status.applicable))
          Align(
            alignment: Alignment.centerLeft,
            child: Builder(
              builder: (context) {
                final all = visible
                    .where((e) => e.status.applicable)
                    .every((e) => imports.selected.contains(e.sourceId));
                return TextButton(
                  onPressed: () => imports.toggleVisible(!all),
                  child: Text(all ? '取消勾選這些點位' : '勾選這些點位'),
                );
              },
            ),
          ),
        const SizedBox(height: 4),
      ] else if (!imports.loading && imports.error == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            '還沒有選擇檔案。檔案只在按下「匯入」時才會寫入資料庫。',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
    ];
    return _Frame(
      gutter: gutter,
      header: header,
      itemCount: loaded ? visible.length : 0,
      itemBuilder: (context, i) {
        final entry = visible[i];
        return _EntryTile(
          key: ValueKey('import-${entry.sourceId}-$i'),
          entry: entry,
          imports: imports,
          stacked: compact,
          open:
              entry.status == ImportStatus.conflict ||
              open.contains(entry.sourceId),
          onToggleOpen: () => onToggleOpen(entry.sourceId),
        );
      },
      bar: loaded
          ? _ApplyBar(
              compact: compact,
              gutter: gutter,
              count: imports.selected.length,
              busy: imports.applying || imports.loading,
              needsDate: imports.needsDate,
              validDate: imports.validDate,
              date: date,
              note: note,
              onDate: imports.setEffectiveDate,
              onApply: () async {
                await imports.apply(note.text);
                if (imports.error == null) note.clear();
              },
            )
          : null,
    );
  }
}

String _resultText(ImportResult r, {required bool imported}) {
  final done = imported
      ? '已匯入：新增 ${r.inserted} 筆、更新 ${r.updated} 筆。'
      : '已寫入 ${r.updated} 筆費率。';
  if (r.skipped.isEmpty) return done;
  final reasons = <String, int>{};
  for (final s in r.skipped) {
    reasons[s.reason] = (reasons[s.reason] ?? 0) + 1;
  }
  return '$done${r.skipped.length} 筆沒有寫入：'
      '${reasons.entries.map((e) => '${e.key}（${e.value} 筆）').join('；')}';
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.entry,
    required this.imports,
    required this.stacked,
    required this.open,
    required this.onToggleOpen,
  });
  final ImportEntry entry;
  final ImportController imports;
  final bool stacked, open;
  final VoidCallback onToggleOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant);
    final place = [entry.city, entry.district].join();
    final meta = [
      entry.official ? '官方點' : '社群點',
      if (place.isNotEmpty) place,
      if (entry.hidden) '地圖上已隱藏，匯入不會恢復顯示',
    ].join('，');
    final chosen = imports.selected.contains(entry.sourceId);
    final title = Text(
      entry.name.isEmpty ? '（沒有名稱）' : entry.name,
      style: const TextStyle(fontWeight: FontWeight.w700),
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: entry.status.applicable
                ? Checkbox(
                    value: chosen,
                    semanticLabel: '匯入${entry.name}',
                    onChanged: imports.applying
                        ? null
                        : (v) => imports.toggle(entry.sourceId, v ?? false),
                  )
                : null,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (stacked) ...[
                    title,
                    const SizedBox(height: 2),
                    _StatusTag(entry.status),
                  ] else
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: title),
                        const SizedBox(width: 12),
                        _StatusTag(entry.status),
                      ],
                    ),
                  const SizedBox(height: 2),
                  Text(meta, style: muted),
                  if (entry.reason.isNotEmpty &&
                      entry.status != ImportStatus.existing)
                    Text(entry.reason, style: TextStyle(color: colors.error)),
                  if (entry.changes.isNotEmpty) ...[
                    if (entry.status != ImportStatus.conflict)
                      TextButton.icon(
                        onPressed: onToggleOpen,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                        ),
                        label: Text(
                          open ? '收起變更' : '顯示 ${entry.changes.length} 個欄位的變更',
                        ),
                      ),
                    if (open) ...[
                      const SizedBox(height: 8),
                      _ChangeTable(
                        entry: entry,
                        imports: imports,
                        stacked: stacked,
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChangeTable extends StatelessWidget {
  const _ChangeTable({
    required this.entry,
    required this.imports,
    required this.stacked,
  });
  final ImportEntry entry;
  final ImportController imports;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant);
    final replace = imports.overwrite[entry.sourceId] ?? const <String>{};

    Widget incoming(ImportChange c) {
      final text = formatImportValue(c.field, c.incoming);
      final written = !c.byAdmin || replace.contains(c.field);
      return written
          ? Align(alignment: Alignment.centerLeft, child: ChangeBand(text))
          : Text(
              '$text（不匯入）',
              style: muted.copyWith(decoration: TextDecoration.lineThrough),
            );
    }

    Widget current(ImportChange c) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(formatImportValue(c.field, c.current)),
        if (c.byAdmin)
          Text(
            '管理員${_date(c.adminAt!)}${adminActionLabel(c.adminAction)}',
            style: TextStyle(
              color: colors.error,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );

    Widget choice(ImportChange c) => SwitchListTile(
      value: replace.contains(c.field),
      onChanged: imports.applying
          ? null
          : (v) => imports.setOverwrite(entry.sourceId, c.field, v),
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(
        replace.contains(c.field) ? '以匯入值覆寫' : '保留管理員修改',
        style: const TextStyle(fontSize: 14),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!stacked)
            Container(
              color: Theme.of(context).scaffoldBackgroundColor,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: DefaultTextStyle.merge(
                style: muted.copyWith(fontSize: 13),
                child: const Row(
                  children: [
                    Expanded(flex: 6, child: Text('欄位')),
                    SizedBox(width: 12),
                    Expanded(flex: 10, child: Text('目前')),
                    SizedBox(width: 12),
                    Expanded(flex: 12, child: Text('匯入')),
                  ],
                ),
              ),
            ),
          for (final (i, c) in entry.changes.indexed)
            Container(
              decoration: BoxDecoration(
                border: i == 0 && stacked
                    ? null
                    : Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: stacked
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          importFieldLabel(c.field),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        _Labelled('目前', current(c)),
                        const SizedBox(height: 6),
                        _Labelled('匯入', incoming(c)),
                        if (c.byAdmin) choice(c),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 6,
                          child: Text(importFieldLabel(c.field), style: muted),
                        ),
                        const SizedBox(width: 12),
                        Expanded(flex: 10, child: current(c)),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 12,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [incoming(c), if (c.byAdmin) choice(c)],
                          ),
                        ),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}

String _date(DateTime at) {
  final local = at.toLocal();
  return '${local.year}/${local.month}/${local.day} ';
}

class _Labelled extends StatelessWidget {
  const _Labelled(this.label, this.child);
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 44,
        child: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      Expanded(child: child),
    ],
  );
}

Widget _dateField(
  TextEditingController date,
  ValueChanged<String> onDate,
  bool valid,
) => TextField(
  controller: date,
  onChanged: onDate,
  keyboardType: TextInputType.datetime,
  decoration: InputDecoration(
    labelText: '新官方點的生效日期',
    hintText: 'YYYY-MM-DD',
    errorText: valid ? null : '請填寫日期，例如 2026-10-26',
  ),
);

Widget _noteField(TextEditingController note) => TextField(
  controller: note,
  maxLength: 500,
  decoration: const InputDecoration(
    labelText: '處理說明（選填，寫入稽核紀錄）',
    counterText: '',
  ),
);

/// On a phone the fields scroll with the list, so the fixed bar holds only
/// the action and the rows keep most of the screen.
List<Widget> _phoneFields(List<Widget> fields) => [
  for (final f in fields) ...[f, const SizedBox(height: 12)],
];

class _ApplyBar extends StatelessWidget {
  const _ApplyBar({
    required this.compact,
    required this.gutter,
    required this.count,
    required this.busy,
    required this.needsDate,
    required this.validDate,
    required this.date,
    required this.note,
    required this.onDate,
    required this.onApply,
  });
  final bool compact, busy, needsDate, validDate;
  final double gutter;
  final int count;
  final TextEditingController date, note;
  final ValueChanged<String> onDate;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dateField = _dateField(date, onDate, validDate);
    final noteField = _noteField(note);
    final button = FilledButton.icon(
      onPressed: busy || count == 0 || (needsDate && !validDate)
          ? null
          : onApply,
      icon: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.file_upload_outlined),
      label: Text(
        count == 0
            ? '請先勾選要匯入的點位'
            : needsDate && !validDate
            ? '請填寫新官方點的生效日期'
            : '匯入勾選的 $count 筆',
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 12),
      child: compact
          ? button
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (needsDate) ...[
                  SizedBox(width: 220, child: dateField),
                  const SizedBox(width: 12),
                ],
                Expanded(child: noteField),
                const SizedBox(width: 12),
                Padding(padding: const EdgeInsets.only(top: 4), child: button),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------

const _verdicts = [
  (
    verdict: FeeVerdict.convertible,
    label: '可轉換',
    icon: Icons.check_circle_outline,
  ),
  (verdict: FeeVerdict.manual, label: '需人工確認', icon: Icons.front_hand_outlined),
  (verdict: FeeVerdict.unknown, label: '無法判斷', icon: Icons.help_outline),
];

class _FeeSection extends StatelessWidget {
  const _FeeSection({
    required this.fees,
    required this.compact,
    required this.gutter,
    required this.note,
  });
  final FeeConversionController fees;
  final bool compact;
  final double gutter;
  final TextEditingController note;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visible = fees.visible;
    final header = <Widget>[
      const _Intro(
        title: '費率轉換',
        text:
            '把現有點位的收費資訊轉成結構化費率，供之後依價格篩選。只轉換能確定的寫法：'
            '「請依現場公告」「未知」維持未確認；混有汽車、月租、身障費率或依日期時段而不同、無法確定者交給人工確認。'
            '勾選確認後才會寫入，收費資訊的文字不會改變。轉換完成前，App 不開放依價格篩選。',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: fees.loaded
            ? OutlinedButton.icon(
                onPressed: fees.loading || fees.converting ? null : fees.load,
                icon: const Icon(Icons.refresh),
                label: const Text('重新讀取'),
              )
            : FilledButton.icon(
                onPressed: fees.loading ? null : fees.load,
                icon: const Icon(Icons.download_outlined),
                label: const Text('讀取尚未轉換的點位'),
              ),
      ),
      const SizedBox(height: 16),
      if (fees.loading)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      if (fees.error != null) ...[
        AdminNotice(fees.error!, error: true),
        const SizedBox(height: 16),
      ],
      if (fees.result case final result?) ...[
        AdminNotice(_resultText(result, imported: false)),
        const SizedBox(height: 16),
      ],
      if (fees.loaded) ...[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final v in _verdicts)
              _Filter(
                label: '${v.label} ${fees.spots(v.verdict)} 筆',
                icon: v.icon,
                selected: fees.verdict == v.verdict,
                onPressed: () => fees.show(v.verdict),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (compact) ..._phoneFields([_noteField(note)]),
        Text(switch (fees.verdict) {
          FeeVerdict.convertible => '這些寫法可以確定費率，預設勾選；取消勾選的不會寫入。',
          FeeVerdict.manual => '有建議值的可以勾選採用；沒有建議值的請到點位頁逐筆設定費率。',
          FeeVerdict.unknown => '這些點位沒有可轉換的機車費率，維持未確認，不需處理。',
        }, style: TextStyle(color: colors.onSurfaceVariant)),
        if (visible.any(fees.writable))
          Align(
            alignment: Alignment.centerLeft,
            child: Builder(
              builder: (context) {
                final all = visible
                    .where(fees.writable)
                    .every((g) => fees.selected.contains(g.key));
                return TextButton(
                  onPressed: () => fees.toggleVisible(!all),
                  child: Text(all ? '取消勾選這些寫法' : '勾選這些寫法'),
                );
              },
            ),
          ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text(
              '這一類沒有待處理的點位。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 4),
      ],
    ];
    return _Frame(
      gutter: gutter,
      header: header,
      itemCount: fees.loaded ? visible.length : 0,
      itemBuilder: (context, i) => _FeeGroupTile(
        key: ValueKey('fee-${visible[i].key}'),
        group: visible[i],
        fees: fees,
      ),
      bar: fees.loaded
          ? Container(
              decoration: BoxDecoration(
                color: colors.surface,
                border: Border(top: BorderSide(color: colors.outlineVariant)),
              ),
              padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!compact) ...[
                    Expanded(child: _noteField(note)),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    flex: compact ? 1 : 0,
                    child: Padding(
                      padding: EdgeInsets.only(top: compact ? 0 : 4),
                      child: FilledButton.icon(
                        onPressed:
                            fees.converting ||
                                fees.loading ||
                                fees.selectedSpots == 0
                            ? null
                            : () async {
                                await fees.convert(note.text);
                                if (fees.error == null) note.clear();
                              },
                        icon: fees.converting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                        label: Text(
                          fees.selectedSpots == 0
                              ? '請先勾選要寫入的費率'
                              : '寫入 ${fees.selectedSpots} 筆費率',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            )
          : null,
    );
  }
}

class _FeeGroupTile extends StatelessWidget {
  const _FeeGroupTile({super.key, required this.group, required this.fees});
  final FeeGroup group;
  final FeeConversionController fees;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant);
    final reading = group.reading;
    final fee = reading.fee;
    final first = group.spots.first;
    final where = group.spots.length == 1
        ? '${first.name}（${first.city}${first.district}）'
        : '${first.name}等 ${group.spots.length} 處';
    final manual = reading.verdict == FeeVerdict.manual;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.outlineVariant)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: fees.writable(group)
                ? Checkbox(
                    value: fees.selected.contains(group.key),
                    semanticLabel: manual ? '採用建議費率' : '寫入這個費率',
                    onChanged: fees.converting
                        ? null
                        : (v) => fees.toggle(group, v ?? false),
                  )
                : null,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.note.isEmpty ? '（沒有收費資訊）' : group.note,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(where, style: muted),
                  const SizedBox(height: 6),
                  if (fee != null)
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(manual ? '建議' : '轉換為', style: muted),
                        ChangeBand(feeNoteOf(fee)),
                      ],
                    ),
                  Text(
                    reading.reason,
                    style: manual
                        ? TextStyle(color: colors.error)
                        : muted.copyWith(fontSize: 13),
                  ),
                  if (manual && fee == null)
                    Wrap(
                      spacing: 4,
                      children: [
                        for (final s in group.spots.take(5))
                          TextButton(
                            onPressed: () => context.go('/spots/${s.sourceId}'),
                            child: Text('設定「${s.name}」的費率'),
                          ),
                        if (group.spots.length > 5)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            child: Text(
                              '另有 ${group.spots.length - 5} 處',
                              style: muted,
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

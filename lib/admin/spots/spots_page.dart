import 'dart:async';

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../models/parking.dart';
import '../admin_theme.dart';
import '../review/review_page.dart' show ChangeBand, reviewCompactWidth;
import 'spot_models.dart';
import 'spots_controller.dart';

const _wideWidth = 1040.0;

/// `/spots` and `/spots/<source id>`: search both tables and edit one spot.
class SpotsPage extends StatefulWidget {
  const SpotsPage({super.key, required this.spots, required this.selectedId});
  final SpotsController spots;
  final String? selectedId;

  @override
  State<SpotsPage> createState() => _SpotsPageState();
}

class _SpotsPageState extends State<SpotsPage> {
  final query = TextEditingController();
  final note = TextEditingController();
  Timer? _debounce;

  SpotsController get spots => widget.spots;

  @override
  void initState() {
    super.initState();
    query.text = spots.query;
    // Loading notifies listeners; never during this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!spots.searched && !spots.searching) spots.search();
      _follow();
    });
  }

  @override
  void didUpdateWidget(covariant SpotsPage old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  /// Keeps the form on the spot named by the URL.
  void _follow() {
    final id = widget.selectedId;
    if (!mounted) return;
    if (id == null) {
      if (spots.record != null) spots.close();
    } else if (spots.record?.sourceId != id && !spots.opening) {
      note.clear();
      spots.open(id);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    query.dispose();
    note.dispose();
    super.dispose();
  }

  /// Leaving a form with unsaved changes asks first.
  Future<bool> _mayLeave() async {
    if (!spots.dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放棄未儲存的修改？'),
        content: const Text('這個點位有尚未儲存的修改，離開後會遺失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('繼續編輯'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放棄修改'),
          ),
        ],
      ),
    );
    if (leave == true) spots.discard();
    return leave == true;
  }

  Future<void> _go(String? id) async {
    if (id == spots.record?.sourceId && id != null) return;
    if (!await _mayLeave() || !mounted) return;
    context.go(id == null ? '/spots' : '/spots/$id');
  }

  void _search(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      spots.query = value;
      spots.search();
    });
  }

  Future<void> _save() async {
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = spots.draft['name'] as String? ?? '';
    if (await spots.save(note.text.trim())) {
      note.clear();
      messenger.showSnackBar(SnackBar(content: Text('已儲存：$name')));
      router.go('/spots');
    }
  }

  Future<void> _setHidden(bool hide) async {
    final messenger = ScaffoldMessenger.of(context);
    final record = spots.record;
    if (record == null) return;
    if (await spots.setHidden(hide)) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${hide ? '已隱藏' : '已恢復顯示'}：${record.name}'),
            action: SnackBarAction(
              label: '復原',
              onPressed: () => spots.setHidden(!hide),
            ),
          ),
        );
    }
  }

  Future<void> _promote() async {
    if (spots.dirty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('請先儲存或放棄目前的修改，再改為官方點。')));
      return;
    }
    final router = GoRouter.of(context);
    final result = await showDialog<(Map<String, dynamic>, String)>(
      context: context,
      builder: (context) => const _PromoteDialog(),
    );
    if (result == null || !mounted) return;
    final id = await spots.promote(result.$1, result.$2);
    if (id != null) router.go('/spots/$id');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: spots,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < reviewCompactWidth;
        final list = _ListPane(
          spots: spots,
          query: query,
          selectedId: widget.selectedId,
          compact: compact,
          onQuery: _search,
          onPick: _go,
        );
        final form = _FormPane(
          spots: spots,
          note: note,
          compact: compact,
          selectedId: widget.selectedId,
          onBack: () => _go(null),
          onSave: _save,
          onHide: _setHidden,
          onPromote: _promote,
          onReload: () {
            final id = widget.selectedId;
            if (id != null) spots.open(id);
          },
        );
        if (compact) return widget.selectedId == null ? list : form;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth >= _wideWidth ? 380 : 300,
                child: _Pane(child: list),
              ),
              const SizedBox(width: 20),
              Expanded(child: _Pane(child: form)),
            ],
          ),
        );
      },
    ),
  );
}

class _Pane extends StatelessWidget {
  const _Pane({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(11), child: child),
    );
  }
}

const _states = [
  (null, '全部狀態'),
  ('visible', '顯示中'),
  ('pending', '待確認'),
  ('confirmed', '已確認存在'),
  ('hidden', '已隱藏'),
];

class _ListPane extends StatelessWidget {
  const _ListPane({
    required this.spots,
    required this.query,
    required this.selectedId,
    required this.compact,
    required this.onQuery,
    required this.onPick,
  });
  final SpotsController spots;
  final TextEditingController query;
  final String? selectedId;
  final bool compact;
  final ValueChanged<String> onQuery;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget chips(List<Widget> children) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          for (final c in children) ...[c, const SizedBox(width: 6)],
        ],
      ),
    );
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('停車點位', style: text.titleLarge),
                  ),
                ),
                IconButton(
                  tooltip: '重新搜尋',
                  onPressed: spots.searching ? null : spots.search,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: TextField(
              key: const ValueKey('spot-search'),
              controller: query,
              onChanged: onQuery,
              decoration: const InputDecoration(
                labelText: '搜尋名稱、地址、路段或行政區',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
            ),
          ),
          Semantics(
            label: '依來源篩選',
            container: true,
            child: chips([
              for (final k in [null, ...SpotKind.values])
                _Chip(
                  label: k?.label ?? '全部來源',
                  selected: spots.kind == k,
                  onPressed: () =>
                      spots.setFilters(kind: k, state: spots.state),
                ),
            ]),
          ),
          Semantics(
            label: '依狀態篩選',
            container: true,
            child: chips([
              for (final (value, label) in _states)
                _Chip(
                  label: label,
                  selected: spots.state == value,
                  onPressed: () =>
                      spots.setFilters(kind: spots.kind, state: value),
                ),
            ]),
          ),
          if (spots.searchError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: AdminNotice(spots.searchError!, error: true),
            ),
          Divider(height: 1, color: colors.outlineVariant),
          Expanded(
            child: !spots.searched
                ? Center(
                    child: spots.searching
                        ? const CircularProgressIndicator()
                        : const SizedBox(),
                  )
                : spots.results.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      '沒有符合的點位。換個關鍵字，或調整來源與狀態篩選。',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : ListView.separated(
                    itemCount: spots.results.length + 1,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: colors.outlineVariant),
                    itemBuilder: (context, i) => i == spots.results.length
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(
                              spots.results.length >= 200
                                  ? '只顯示最近更新的 200 筆，請用關鍵字縮小範圍。'
                                  : '共 ${spots.results.length} 筆',
                              style: TextStyle(
                                fontSize: 13,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          )
                        : _SpotItem(
                            spot: spots.results[i],
                            selected:
                                !compact &&
                                spots.results[i].sourceId == selectedId,
                            onPressed: () => onPick(spots.results[i].sourceId),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onPressed,
  });
  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(44, 44),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: const StadiumBorder(),
          foregroundColor: selected ? colors.surface : colors.onSurface,
          backgroundColor: selected ? colors.onSurface : null,
        ),
        child: Text(label),
      ),
    );
  }
}

class _SpotItem extends StatelessWidget {
  const _SpotItem({
    required this.spot,
    required this.selected,
    required this.onPressed,
  });
  final SpotSummary spot;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final type = SpaceType.values.asNameMap()[spot.spaceType]?.label;
    return Semantics(
      selected: selected,
      child: TextButton(
        key: ValueKey('spot-${spot.sourceId}'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          shape: const RoundedRectangleBorder(),
          foregroundColor: colors.onSurface,
          backgroundColor: selected
              ? colors.primary.withValues(alpha: .1)
              : null,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 18, 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                spot.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${spot.city}${spot.district}，${spot.kind.label}${type == null ? '' : '，$type'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
              if (spot.address.isNotEmpty)
                Text(
                  spot.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
              if (spot.hidden || spot.state == 'pending')
                Text(
                  spot.hidden ? '已隱藏' : '待確認',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: spot.hidden ? colors.error : colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FormPane extends StatelessWidget {
  const _FormPane({
    required this.spots,
    required this.note,
    required this.compact,
    required this.selectedId,
    required this.onBack,
    required this.onSave,
    required this.onHide,
    required this.onPromote,
    required this.onReload,
  });
  final SpotsController spots;
  final TextEditingController note;
  final bool compact;
  final String? selectedId;
  final VoidCallback onBack, onSave, onPromote, onReload;
  final ValueChanged<bool> onHide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final record = spots.record;
    final pad = compact ? 16.0 : 24.0;
    final back = compact
        ? Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回點位清單'),
            ),
          )
        : null;
    if (selectedId == null) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
          children: [
            Text('選擇一個點位', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              '從左側清單搜尋並選擇點位，即可在這裡編輯、隱藏，或把社群點改為官方點。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (record == null || record.sourceId != selectedId) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: EdgeInsets.all(pad),
          children: [
            ?back,
            const SizedBox(height: 24),
            if (spots.openError != null) ...[
              AdminNotice(spots.openError!, error: true),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: onReload,
                  child: const Text('重新載入'),
                ),
              ),
            ] else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }
    final errors = spots.errors;
    final fields = spots.fields;
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 22, pad, 24),
              children: [
                ?back,
                Text(
                  record.official
                      ? '官方點（${(record.values['source_name'] as String?)?.isNotEmpty == true ? record.values['source_name'] : '未填來源'}）'
                      : '社群點（社群回報整理）',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(
                  header: true,
                  child: Text(
                    record.name,
                    style: text.headlineMedium?.copyWith(
                      fontSize: compact ? 22 : 26,
                      height: 1.3,
                    ),
                  ),
                ),
                if (record.hidden) ...[
                  const SizedBox(height: 8),
                  const AdminNotice('這個點位已隱藏，App 地圖上不會顯示。', error: true),
                ],
                if (spots.saveError != null) ...[
                  const SizedBox(height: 12),
                  AdminNotice(spots.saveError!, error: true),
                  if (spots.stale) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: onReload,
                        child: const Text('重新載入（放棄目前的修改）'),
                      ),
                    ),
                  ],
                ],
                for (final group in SpotGroup.values) ...[
                  const SizedBox(height: 24),
                  Semantics(
                    header: true,
                    child: Text(
                      group.label,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (group == SpotGroup.source) _SourceFacts(record: record),
                  if (group == SpotGroup.location)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '地圖選位與門牌反查將在位置選擇元件上線後提供；目前可直接輸入座標。',
                        style: TextStyle(
                          fontSize: 13,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  for (final f in fields.where((f) => f.group == group))
                    _FieldRow(
                      key: ValueKey(
                        '${record.sourceId}-${record.updatedAt}-${f.key}',
                      ),
                      field: f,
                      value: spots.draft[f.key],
                      changed: spots.changed(f.key),
                      error: errors[f.key],
                      onChanged: (v) => spots.set(f.key, v),
                    ),
                ],
                const SizedBox(height: 24),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: TextField(
                    key: const ValueKey('spot-note'),
                    controller: note,
                    maxLength: 500,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: '修改說明（選填）',
                      helperText: '會和處理人、時間一起記錄在稽核紀錄。',
                    ),
                  ),
                ),
              ],
            ),
          ),
          _SpotActions(
            compact: compact,
            official: record.official,
            hidden: record.hidden,
            dirty: spots.dirty,
            busy: spots.saving,
            onSave: onSave,
            onDiscard: spots.discard,
            onHide: onHide,
            onPromote: onPromote,
          ),
        ],
      ),
    );
  }
}

class _SourceFacts extends StatelessWidget {
  const _SourceFacts({required this.record});
  final SpotRecord record;

  @override
  Widget build(BuildContext context) {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final facts = record.official
        ? [('官方資料編號', record.values['source_id'] as String? ?? '（手動新增）')]
        : [('資料來源', '社群回報整理'), ('建立方式', record.origin)];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (label, value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 104, child: Text(label, style: muted)),
                  Expanded(child: SelectableText(value)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.field,
    required this.value,
    required this.changed,
    required this.error,
    required this.onChanged,
  });
  final SpotField field;
  final Object? value;
  final bool changed;
  final String? error;
  final ValueChanged<Object?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final decoration = InputDecoration(
      labelText: '${field.label}${field.required ? '' : '（選填）'}',
      helperText: field.help,
      helperMaxLines: 3,
      errorText: error,
      enabledBorder: changed
          ? OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: AdminColors.yellow, width: 2),
            )
          : null,
    );
    Widget input;
    switch (field.input) {
      case SpotInput.text || SpotInput.multiline:
        input = TextFormField(
          initialValue: value as String? ?? '',
          maxLength: field.maxLength,
          minLines: 1,
          maxLines: field.input == SpotInput.multiline ? 4 : 1,
          decoration: decoration,
          onChanged: onChanged,
        );
      case SpotInput.number || SpotInput.integer:
        input = TextFormField(
          initialValue: value?.toString() ?? '',
          keyboardType: TextInputType.numberWithOptions(
            decimal: field.input == SpotInput.number,
          ),
          decoration: decoration,
          onChanged: (v) {
            final t = v.trim();
            if (t.isEmpty) return onChanged(null);
            final parsed = field.input == SpotInput.number
                ? double.tryParse(t)
                : int.tryParse(t);
            onChanged(parsed ?? t);
          },
        );
      case SpotInput.date:
        input = TextFormField(
          initialValue: value as String? ?? '',
          decoration: decoration.copyWith(hintText: 'YYYY-MM-DD'),
          onChanged: onChanged,
        );
      case SpotInput.spaceType:
        input = DropdownButtonFormField<String>(
          initialValue: SpaceType.values.asNameMap().containsKey(value)
              ? value as String
              : null,
          isExpanded: true,
          decoration: decoration,
          items: [
            for (final t in SpaceType.values)
              DropdownMenuItem(value: t.name, child: Text(t.label)),
          ],
          onChanged: onChanged,
        );
      case SpotInput.triState:
        input = DropdownButtonFormField<int>(
          initialValue: switch (value) {
            true => 1,
            false => 0,
            _ => -1,
          },
          isExpanded: true,
          decoration: decoration,
          items: const [
            DropdownMenuItem(value: 1, child: Text('可停')),
            DropdownMenuItem(value: 0, child: Text('不可停')),
            DropdownMenuItem(value: -1, child: Text('未確認')),
          ],
          onChanged: (v) => onChanged(switch (v) {
            1 => true,
            0 => false,
            _ => null,
          }),
        );
      case SpotInput.choice:
        input = DropdownButtonFormField<String?>(
          initialValue: field.choices.containsKey(value)
              ? value as String
              : null,
          isExpanded: true,
          decoration: decoration,
          items: [
            if (!field.required)
              const DropdownMenuItem(value: null, child: Text('未設定')),
            for (final e in field.choices.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: onChanged,
        );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (changed)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: ChangeBand('已修改'),
              ),
            DefaultTextStyle.merge(
              style: TextStyle(color: colors.onSurface),
              child: input,
            ),
          ],
        ),
      ),
    );
  }
}

class _SpotActions extends StatelessWidget {
  const _SpotActions({
    required this.compact,
    required this.official,
    required this.hidden,
    required this.dirty,
    required this.busy,
    required this.onSave,
    required this.onDiscard,
    required this.onHide,
    required this.onPromote,
  });
  final bool compact, official, hidden, dirty, busy;
  final VoidCallback onSave, onDiscard, onPromote;
  final ValueChanged<bool> onHide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final save = FilledButton(
      onPressed: busy || !dirty ? null : onSave,
      child: const Text('儲存並關閉'),
    );
    final others = <Widget>[
      if (dirty)
        OutlinedButton(
          onPressed: busy ? null : onDiscard,
          child: const Text('放棄修改'),
        ),
      if (!official && !hidden)
        OutlinedButton(
          onPressed: busy ? null : onPromote,
          child: const Text('改為官方點'),
        ),
    ];
    final hide = OutlinedButton(
      onPressed: busy ? null : () => onHide(!hidden),
      style: hidden
          ? null
          : OutlinedButton.styleFrom(
              foregroundColor: colors.error,
              side: BorderSide(color: colors.error),
            ),
      child: Text(hidden ? '恢復顯示' : '隱藏點位'),
    );
    return LayoutBuilder(
      builder: (context, box) {
        final stacked = compact || box.maxWidth < 600;
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          padding: EdgeInsets.fromLTRB(
            stacked ? 16 : 24,
            12,
            stacked ? 16 : 24,
            12,
          ),
          child: stacked
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    save,
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [...others, hide],
                    ),
                  ],
                )
              : Row(
                  children: [
                    save,
                    for (final b in others) ...[const SizedBox(width: 10), b],
                    const Spacer(),
                    hide,
                  ],
                ),
        );
      },
    );
  }
}

/// The official source a promotion requires, and what the admin states about
/// eligibility; nothing riders entered is carried over as trusted.
class _PromoteDialog extends StatefulWidget {
  const _PromoteDialog();
  @override
  State<_PromoteDialog> createState() => _PromoteDialogState();
}

class _PromoteDialogState extends State<_PromoteDialog> {
  final form = GlobalKey<FormState>();
  final url = TextEditingController();
  final date = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  final reason = TextEditingController();
  String? government;
  bool? scooter, heavy;

  @override
  void dispose() {
    url.dispose();
    date.dispose();
    reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (!form.currentState!.validate()) return;
    Navigator.pop(context, (
      <String, dynamic>{
        'source_name': government,
        'source_url': url.text.trim(),
        'effective_date': date.text.trim(),
        if (scooter != null) 'scooter_allowed': scooter,
        if (heavy != null) 'heavy_allowed': heavy,
      },
      reason.text.trim(),
    ));
  }

  Widget _tri(String label, bool? value, ValueChanged<bool?> onChanged) =>
      DropdownButtonFormField<int>(
        initialValue: switch (value) {
          true => 1,
          false => 0,
          _ => -1,
        },
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: const [
          DropdownMenuItem(value: -1, child: Text('未確認')),
          DropdownMenuItem(value: 1, child: Text('可停（官方明載）')),
          DropdownMenuItem(value: 0, child: Text('不可停（官方明載）')),
        ],
        onChanged: (v) => onChanged(switch (v) {
          1 => true,
          0 => false,
          _ => null,
        }),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('改為官方點'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '比對官方資料確認點位存在後使用。社群點會隱藏並保留紀錄，未結的回報會改到新的官方點。'
                '騎士填寫的停放資格不會沿用；只有官方明載時才填「可停」或「不可停」。',
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: government,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '資料來源'),
                items: [
                  for (final g in governments)
                    DropdownMenuItem(value: g, child: Text(g)),
                ],
                validator: (v) => v == null ? '請選擇資料來源' : null,
                onChanged: (v) => setState(() => government = v),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: url,
                decoration: const InputDecoration(labelText: '官方資料網址'),
                validator: (v) => v != null && v.trim().startsWith('https://')
                    ? null
                    : '請填寫 https:// 開頭的官方資料網址',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: date,
                decoration: const InputDecoration(
                  labelText: '生效日期',
                  hintText: 'YYYY-MM-DD',
                ),
                validator: (v) => DateTime.tryParse(v?.trim() ?? '') == null
                    ? '格式需為 YYYY-MM-DD'
                    : null,
              ),
              const SizedBox(height: 12),
              _tri('普通機車', scooter, (v) => setState(() => scooter = v)),
              const SizedBox(height: 12),
              _tri('大型重機', heavy, (v) => setState(() => heavy = v)),
              const SizedBox(height: 12),
              TextFormField(
                controller: reason,
                maxLength: 500,
                decoration: const InputDecoration(
                  labelText: '處理說明（選填）',
                  hintText: '例如：比對停管處場站資料',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _submit, child: const Text('改為官方點')),
    ],
  );
}

import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/map/map_legend.dart' show SpotMarker, markerLook;
import '../../features/map/vehicle_sheet.dart' show platesOf;
import '../../models/parking.dart';
import '../admin_theme.dart';
import '../review/review_page.dart' show ChangeBand, reviewCompactWidth;
import 'rule_models.dart';
import 'rules_controller.dart';

const _wideWidth = 1040.0;

/// The detail pane is wide enough for the preview beside the form.
const _sideBySide = 900.0;

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// `/rules` and `/rules/<city>/<vehicle>`: every city's rules and an editor
/// that publishes the next version.
class RulesPage extends StatefulWidget {
  const RulesPage({super.key, required this.rules, this.city, this.vehicle});
  final RulesController rules;
  final String? city;
  final VehicleType? vehicle;

  @override
  State<RulesPage> createState() => _RulesPageState();
}

class _RulesPageState extends State<RulesPage> {
  final note = TextEditingController();

  RulesController get rules => widget.rules;
  bool get _hasSelection =>
      widget.city != null &&
      widget.vehicle != null &&
      ruleCities.contains(widget.city);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!rules.loaded && !rules.loading) rules.load();
      _follow();
    });
  }

  @override
  void didUpdateWidget(covariant RulesPage old) {
    super.didUpdateWidget(old);
    if (old.city != widget.city || old.vehicle != widget.vehicle) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  /// Brings the controller in line with the route. The draft outlives the
  /// page (other tabs, the top "規則" tab), so unpublished edits are confirmed
  /// here; declining returns to the rule being edited.
  Future<void> _follow() async {
    if (!mounted) return;
    final target = _hasSelection ? (widget.city!, widget.vehicle!) : null;
    final current = rules.selected;
    if (target == current) {
      if (target != null) rules.select(target.$1, target.$2);
      return;
    }
    if (rules.dirty) {
      if (!await _mayLeave()) {
        if (mounted && current != null) {
          context.go('/rules/${current.$1}/${current.$2.name}');
        }
        return;
      }
      if (!mounted) return;
    }
    if (target == null) {
      rules.close();
    } else {
      note.clear();
      rules.select(target.$1, target.$2);
    }
  }

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<bool> _mayLeave() async {
    if (!rules.dirty) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放棄未發布的修改？'),
        content: const Text('這條規則有尚未發布的修改，離開後會遺失。'),
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
    if (leave == true) rules.discard();
    return leave == true;
  }

  /// Reloading refills the open form; unpublished edits are confirmed first.
  Future<void> _reload() async {
    if (!await _mayLeave() || !mounted) return;
    await rules.load();
  }

  Future<void> _go(RuleKey? key) async {
    if (key != null && key == rules.selected) return;
    if (!await _mayLeave() || !mounted) return;
    context.go(key == null ? '/rules' : '/rules/${key.$1}/${key.$2.name}');
  }

  Future<void> _publish() async {
    final d = rules.draft;
    if (d == null) return;
    if (rules.errors.isNotEmpty) {
      await rules.publish(note.text.trim());
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final previous = rules.base!.copy();
    final title = '${d.city}${d.vehicle.label}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('發布$title第 ${d.nextVersion} 版？'),
        content: const Text(
          '發布後，連線中的 App 會立即改用這個版本。'
          'App 內建的規則檔（離線或尚未連線時使用）不會跟著改變，'
          '要在下次 App 發版前執行 tool/export_rules.py 更新。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('繼續編輯'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('發布第 ${d.nextVersion} 版'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final row = await rules.publish(note.text.trim());
    if (row == null) return;
    note.clear();
    final version = row['version'] as int;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('已發布$title第 $version 版'),
          action: previous.isNew
              ? null
              : SnackBarAction(
                  label: '復原',
                  onPressed: () async {
                    final undone = await rules.undo(previous, version);
                    if (undone == null) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          '已發布第 ${undone['version']} 版，內容恢復為第 ${previous.version} 版',
                        ),
                      ),
                    );
                  },
                ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: rules,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < reviewCompactWidth;
        final list = _ListPane(
          rules: rules,
          compact: compact,
          onPick: _go,
          onReload: _reload,
        );
        final detail = _DetailPane(
          rules: rules,
          note: note,
          compact: compact,
          hasSelection: _hasSelection,
          onBack: () => _go(null),
          onPublish: _publish,
        );
        if (compact) return _hasSelection ? detail : list;
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: constraints.maxWidth >= _wideWidth ? 340 : 300,
                child: _Pane(child: list),
              ),
              const SizedBox(width: 20),
              Expanded(child: _Pane(child: detail)),
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

/// The vehicle's plate colours, small, as the app's vehicle picker shows.
class _Plates extends StatelessWidget {
  const _Plates(this.vehicle);
  final VehicleType vehicle;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (fill, ink) in platesOf(vehicle))
          Container(
            width: 16,
            height: 11,
            margin: const EdgeInsets.only(right: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(2),
              border: Border.all(color: const Color(0xff1c1c1c)),
            ),
            child: Container(width: 8, height: 2, color: ink),
          ),
      ],
    ),
  );
}

class _ListPane extends StatelessWidget {
  const _ListPane({
    required this.rules,
    required this.compact,
    required this.onPick,
    required this.onReload,
  });
  final RulesController rules;
  final bool compact;
  final ValueChanged<RuleKey> onPick;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summaries = rules.summaries;
    final unsynced = rules.unsyncedCount;
    // One scrollable column: on a short phone at a large text size the
    // header and notices must scroll away with the list.
    return Material(
      color: colors.surface,
      child: !rules.loaded
          ? ListView(
              children: [
                header(text),
                if (rules.loadError != null) error(),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: rules.loading
                        ? const CircularProgressIndicator()
                        : const SizedBox(),
                  ),
                ),
              ],
            )
          : ListView.builder(
              key: const ValueKey('rule-list'),
              itemCount: ruleCities.length + 1,
              itemBuilder: (context, i) {
                if (i == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      header(text),
                      if (rules.loadError != null) error(),
                      if (unsynced > 0)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                          child: AdminNotice(
                            '$unsynced 條規則和 App 內建規則檔的版本不同。'
                            '下次 App 發版前，請執行 python3 tool/export_rules.py 更新內建規則檔。',
                          ),
                        ),
                      Divider(height: 1, color: colors.outlineVariant),
                    ],
                  );
                }
                final city = ruleCities[i - 1];
                return Container(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: colors.outlineVariant),
                    ),
                  ),
                  padding: const EdgeInsets.only(top: 10, bottom: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Semantics(
                          header: true,
                          child: Text(
                            city,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      for (final s in summaries.where((s) => s.city == city))
                        _RuleItem(
                          summary: s,
                          selected:
                              !compact && rules.selected == (s.city, s.vehicle),
                          onPressed: () => onPick((s.city, s.vehicle)),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget header(TextTheme text) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            container: true,
            header: true,
            child: Text('各縣市規則', style: text.titleLarge),
          ),
        ),
        IconButton(
          tooltip: '重新載入規則',
          onPressed: rules.loading || rules.publishing ? null : onReload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
  );

  Widget error() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: AdminNotice(rules.loadError!, error: true),
  );
}

class _RuleItem extends StatelessWidget {
  const _RuleItem({
    required this.summary,
    required this.selected,
    required this.onPressed,
  });
  final RuleSummary summary;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final s = summary;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final restriction = s.restriction == null
        ? null
        : restrictionLabel(s.restriction);
    return Semantics(
      selected: selected,
      label:
          '${s.city}${s.vehicle.label}，${s.version == null ? '尚無規則' : '第 ${s.version} 版'}'
          '${restriction == null ? '' : '，$restriction'}'
          '${s.unsynced ? '，App 內建規則檔尚未更新' : ''}',
      excludeSemantics: true,
      button: true,
      child: TextButton(
        key: ValueKey('rule-${s.city}-${s.vehicle.name}'),
        onPressed: onPressed,
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.zero,
          minimumSize: const Size(48, 48),
          shape: const RoundedRectangleBorder(),
          foregroundColor: colors.onSurface,
          backgroundColor: selected
              ? colors.primary.withValues(alpha: .1)
              : null,
        ),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 8, 18, 8),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 4,
              ),
            ),
          ),
          child: Row(
            children: [
              _Plates(s.vehicle),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.vehicle.label),
                    if (restriction != null) Text(restriction, style: muted),
                    if (s.unsynced)
                      const Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: ChangeBand('App 內建尚未更新'),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                s.version == null ? '尚無規則' : '第 ${s.version} 版',
                style: s.version == null
                    ? muted
                    : const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailPane extends StatelessWidget {
  const _DetailPane({
    required this.rules,
    required this.note,
    required this.compact,
    required this.hasSelection,
    required this.onBack,
    required this.onPublish,
  });
  final RulesController rules;
  final TextEditingController note;
  final bool compact, hasSelection;
  final VoidCallback onBack, onPublish;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pad = compact ? 16.0 : 24.0;
    final d = rules.draft;
    final back = compact
        ? Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回規則清單'),
            ),
          )
        : null;
    if (!hasSelection) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(28, 40, 28, 40),
          children: [
            Text('選擇一條規則', style: text.titleLarge),
            const SizedBox(height: 8),
            Text(
              '從左側選擇縣市與車種，設定各種路邊格位能不能停，預覽 App 地圖上的標記後發布新版本。',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
        ),
      );
    }
    if (d == null || !rules.loaded) {
      return Material(
        color: colors.surface,
        child: ListView(
          padding: EdgeInsets.all(pad),
          children: [
            ?back,
            const SizedBox(height: 24),
            if (rules.loadError != null)
              AdminNotice(rules.loadError!, error: true)
            else
              const Center(child: CircularProgressIndicator()),
          ],
        ),
      );
    }
    final current = rules.base!;
    // Edits made while a publish is in flight would be overwritten by the
    // published version; the form is locked until it returns.
    final form = IgnorePointer(
      ignoring: rules.publishing,
      child: ExcludeFocus(
        excluding: rules.publishing,
        child: _RuleForm(rules: rules, note: note),
      ),
    );
    final previewPane = _Preview(rules: rules);
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final side = box.maxWidth >= _sideBySide;
                final header = <Widget>[
                  ?back,
                  Row(
                    children: [
                      _Plates(d.vehicle),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          current.isNew
                              ? '尚未發布，發布後為第 1 版'
                              : '目前第 ${current.version} 版，${current.effectiveDate} 生效',
                          style: TextStyle(
                            color: colors.primary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Semantics(
                    header: true,
                    child: Text(
                      '${d.city}${d.vehicle.label}規則',
                      style: text.headlineMedium?.copyWith(
                        fontSize: compact ? 22 : 26,
                        height: 1.3,
                      ),
                    ),
                  ),
                  if (rules.publishError != null) ...[
                    const SizedBox(height: 12),
                    AdminNotice(rules.publishError!, error: true),
                    if (rules.stale) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton(
                          onPressed: rules.publishing ? null : rules.load,
                          child: const Text('重新載入（放棄目前的修改）'),
                        ),
                      ),
                    ],
                  ],
                ];
                return ListView(
                  key: ValueKey(
                    'rule-form-${d.city}-${d.vehicle.name}-${rules.formSeq}',
                  ),
                  padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 22, pad, 24),
                  children: [
                    ...header,
                    if (side)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: form),
                          const SizedBox(width: 28),
                          SizedBox(width: 340, child: previewPane),
                        ],
                      )
                    else ...[
                      form,
                      const SizedBox(height: 28),
                      previewPane,
                    ],
                  ],
                );
              },
            ),
          ),
          _PublishBar(
            compact: compact,
            version: d.nextVersion,
            dirty: rules.dirty,
            creating: d.isNew,
            busy: rules.publishing,
            onPublish: onPublish,
            onDiscard: rules.discard,
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, {this.help});
  final String title;
  final String? help;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 28, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (help != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              help!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );
}

/// The yellow band and border every changed field carries.
class _Changed extends StatelessWidget {
  const _Changed({required this.changed, required this.child});
  final bool changed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (changed)
        const Padding(
          padding: EdgeInsets.only(bottom: 6),
          child: ChangeBand('已修改'),
        ),
      child,
    ],
  );
}

InputDecoration _decoration(
  String label, {
  String? help,
  String? error,
  bool changed = false,
  String? hint,
}) => InputDecoration(
  labelText: label,
  helperText: help,
  helperMaxLines: 3,
  errorText: error,
  errorMaxLines: 3,
  hintText: hint,
  enabledBorder: changed
      ? OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AdminColors.yellow, width: 2),
        )
      : null,
);

class _RuleForm extends StatelessWidget {
  const _RuleForm({required this.rules, required this.note});
  final RulesController rules;
  final TextEditingController note;

  @override
  Widget build(BuildContext context) {
    final d = rules.draft!;
    final errors = rules.shownErrors;
    final seq = rules.formSeq;
    Widget text(
      String key,
      String label,
      String value,
      void Function(RuleDraft, String) set, {
      String? help,
      String? hint,
      int maxLines = 1,
      int? maxLength,
    }) => Padding(
      padding: const EdgeInsets.only(top: 14),
      child: _Changed(
        changed: rules.changed(key),
        child: TextFormField(
          key: ValueKey('rule-$key-$seq'),
          initialValue: value,
          minLines: 1,
          maxLines: maxLines,
          maxLength: maxLength,
          decoration: _decoration(
            label,
            help: help,
            hint: hint,
            error: errors[key],
            changed: rules.changed(key),
          ),
          onChanged: (v) => rules.update((d) => set(d, v)),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _Section(
          '路邊格位',
          help:
              '路外停車場依場站資料判斷，不在規則設定。限時停車格比照路邊收費機車格；'
              '身障、電動機車與汽機車彈性共用格依法規與格位本身判斷。',
        ),
        for (final type in streetTypes(d.vehicle))
          _AccessRow(rules: rules, type: type),
        if (d.hasConditional) ...[
          const _Section('限制類型', help: '有條件開放的格位，App 會依限制類型顯示標記與說明。'),
          _RestrictionChoice(rules: rules),
        ],
        const _Section('開放範圍與停放方式'),
        text(
          'districts',
          '公告的開放行政區（選填）',
          d.districts.join('、'),
          (d, v) => d.districts = parseNames(v),
          help: '留空為全縣市。填寫後，清單外行政區的點位顯示待確認。以「、」或逗號分隔。',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _Changed(
            changed: rules.changed('can_use_two_spaces'),
            child: SwitchListTile(
              key: const ValueKey('rule-two-spaces'),
              contentPadding: EdgeInsets.zero,
              title: const Text('可斜停兩格'),
              subtitle: const Text('車身較長時可跨兩格斜停，App 在可停的說明中提醒'),
              value: d.canUseTwoSpaces,
              onChanged: (v) => rules.update((d) => d.canUseTwoSpaces = v),
            ),
          ),
        ),
        const _Section('公告內容'),
        text(
          'fee_note',
          '費率說明',
          d.feeNote,
          (d, v) => d.feeNote = v,
          maxLength: 200,
          maxLines: 3,
        ),
        text(
          'exceptions',
          '例外與注意事項',
          d.exceptions,
          (d, v) => d.exceptions = v,
          help: '騎士看到「不可停」或「有條件」時顯示這段說明。規則沒有時段與截止日欄位：平日／假日、時段或試辦截止日請寫在這裡。',
          maxLength: 500,
          maxLines: 5,
        ),
        text(
          'effective_date',
          '生效日期',
          d.effectiveDate,
          (d, v) => d.effectiveDate = v,
          hint: 'YYYY-MM-DD',
          help: '生效日前，App 仍把這些格位顯示為待確認。',
        ),
        text(
          'source_url',
          '公告網址',
          d.sourceUrl,
          (d, v) => d.sourceUrl = v,
          hint: 'https://',
        ),
        Padding(
          padding: const EdgeInsets.only(top: 22),
          child: TextField(
            key: const ValueKey('rule-note'),
            controller: note,
            maxLength: 500,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '發布說明（選填）',
              helperText: '會和發布人、時間、修改前後內容一起記錄在稽核紀錄。',
              helperMaxLines: 2,
            ),
          ),
        ),
      ],
    );
  }
}

/// One street space: open, conditional or closed, and the districts it is
/// limited to. Stacks under 520 px so nothing scrolls sideways.
class _AccessRow extends StatelessWidget {
  const _AccessRow({required this.rules, required this.type});
  final RulesController rules;
  final SpaceType type;

  @override
  Widget build(BuildContext context) {
    final d = rules.draft!;
    final access = d.access[type]!;
    final changed = rules.changedType(type);
    final colors = Theme.of(context).colorScheme;
    final segments = SegmentedButton<StreetAccess>(
      key: ValueKey('access-${type.name}'),
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      segments: [
        for (final a in StreetAccess.values)
          ButtonSegment(
            value: a,
            label: Text(a.label, softWrap: false),
            icon: Icon(switch (a) {
              StreetAccess.open => Icons.local_parking,
              StreetAccess.conditional => Icons.rule,
              StreetAccess.closed => Icons.close,
            }, size: 18),
          ),
      ],
      selected: {access},
      onSelectionChanged: (v) => rules.update((d) => d.access[type] = v.single),
    );
    final label = Text(
      type.label,
      style: const TextStyle(fontWeight: FontWeight.w700),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: _Changed(
        changed: changed,
        child: Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: changed ? AdminColors.yellow : colors.outlineVariant,
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, box) => box.maxWidth < 520
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [label, const SizedBox(height: 8), segments],
                      )
                    : Row(
                        children: [
                          Expanded(child: label),
                          const SizedBox(width: 12),
                          segments,
                        ],
                      ),
              ),
              if (access != StreetAccess.closed &&
                  (d.typeDistricts[type] ?? const []).isEmpty &&
                  !rules.districtFields.contains(type))
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: ValueKey('open-districts-${type.name}'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    ),
                    onPressed: () => rules.openDistricts(type),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('限定行政區'),
                  ),
                )
              else if (access != StreetAccess.closed)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: TextFormField(
                    key: ValueKey('districts-${type.name}-${rules.formSeq}'),
                    initialValue: (d.typeDistricts[type] ?? const []).join('、'),
                    decoration: _decoration(
                      '只在這些行政區（選填）',
                      help: '留空為全縣市。填寫後，清單外行政區的這種格位顯示不可停。',
                      error: rules.shownErrors['districts:${type.name}'],
                    ),
                    onChanged: (v) => rules.update(
                      (d) => d.typeDistricts[type] = parseNames(v),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RestrictionChoice extends StatelessWidget {
  const _RestrictionChoice({required this.rules});
  final RulesController rules;

  @override
  Widget build(BuildContext context) {
    final d = rules.draft!;
    final colors = Theme.of(context).colorScheme;
    final error = rules.shownErrors['restriction'];
    return _Changed(
      changed: rules.changed('restriction'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final MapEntry(:key, :value) in ruleRestrictions.entries)
            Semantics(
              inMutuallyExclusiveGroup: true,
              selected: d.restriction == key,
              child: InkWell(
                key: ValueKey('restriction-$key'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => rules.update((d) => d.restriction = key),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          d.restriction == key
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: d.restriction == key
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                value.label,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                value.help,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: colors.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(error, style: TextStyle(color: colors.error)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What the app's map will show for each street space once published,
/// judged by the shared eligibility() on an official spot.
class _Preview extends StatelessWidget {
  const _Preview({required this.rules});
  final RulesController rules;

  String _district(String d) => switch (d) {
    otherDistrict => '其他行政區',
    unknownDistrict => '行政區不明',
    _ => d,
  };

  @override
  Widget build(BuildContext context) {
    final d = rules.draft!;
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    final effective = parseDate(d.effectiveDate);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final future = effective != null && effective.isAfter(today);
    final districts = previewDistricts(d);
    final rows = d.toCityRule() == null
        ? null
        : preview(d, rules.previewDate, rules.previewDistrict);
    return Semantics(
      container: true,
      label: '發布後的地圖標記預覽',
      child: Column(
        key: const ValueKey('rule-preview'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Section('發布後的地圖標記', help: '以官方點預覽；社群點未經核實時，App 一律顯示待確認。'),
          if (future) ...[
            const SizedBox(height: 8),
            Text('${_date(effective)} 生效，生效前 App 顯示待確認。', style: muted),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              key: const ValueKey('preview-date'),
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
              segments: const [
                ButtonSegment(value: false, label: Text('今天')),
                ButtonSegment(value: true, label: Text('生效後')),
              ],
              selected: {rules.previewEffective},
              onSelectionChanged: (v) => rules.setPreview(effective: v.single),
            ),
          ],
          if (districts.length > 2) ...[
            const SizedBox(height: 12),
            Text('點位所在行政區', style: muted),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final district in districts)
                  ChoiceChip(
                    key: ValueKey('preview-district-$district'),
                    label: Text(_district(district)),
                    selected: rules.previewDistrict == district,
                    onSelected: (_) => rules.setPreview(district: district),
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (rows == null)
            Text('填入正確的生效日期後顯示預覽。', style: muted)
          else
            for (final row in rows) _PreviewRow(row: row),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({required this.row});
  final PreviewRow row;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final result = row.result;
    return Semantics(
      container: true,
      label: '${row.type.label}：${result.label}。${result.reason}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SpotMarker(look: markerLook(result), size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: row.type.label,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: '　${result.label}'),
                      ],
                    ),
                  ),
                  if (result.reason.isNotEmpty)
                    Text(
                      result.reason,
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PublishBar extends StatelessWidget {
  const _PublishBar({
    required this.compact,
    required this.version,
    required this.dirty,
    required this.creating,
    required this.busy,
    required this.onPublish,
    required this.onDiscard,
  });
  final bool compact, dirty, creating, busy;
  final int version;
  final VoidCallback onPublish, onDiscard;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final publish = FilledButton(
      key: const ValueKey('publish-rule'),
      onPressed: busy || !dirty ? null : onPublish,
      child: Text('發布第 $version 版'),
    );
    final hint = Text(
      dirty ? '發版前以 tool/export_rules.py 更新 App 內建規則檔。' : '沒有要發布的修改。',
      style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
    );
    final discard = dirty && !creating
        ? OutlinedButton(
            onPressed: busy ? null : onDiscard,
            child: const Text('放棄修改'),
          )
        : null;
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
                    // One row on phones: the bar must leave room for the form.
                    Row(
                      children: [
                        Expanded(child: publish),
                        if (discard != null) ...[
                          const SizedBox(width: 8),
                          discard,
                        ],
                      ],
                    ),
                    const SizedBox(height: 6),
                    hint,
                  ],
                )
              : Row(
                  children: [
                    publish,
                    if (discard != null) ...[
                      const SizedBox(width: 10),
                      discard,
                    ],
                    const SizedBox(width: 16),
                    Expanded(child: hint),
                  ],
                ),
        );
      },
    );
  }
}

// S5 and S5b 限時／禁停／共用時段: the rules on a spot's signs, each covering
// some of its zones or segments. From a suggestion this page sends its own
// patch (C6); from a new spot (N1) 完成 hands the rules back and N1 copies
// them into its entries when it sends (C14).
import 'dart:math' as math;

import '../../data/app_store.dart';
import '../../domain/precheck.dart';
import '../../models/fee.dart' show FeeMode;
import '../../models/parking.dart';
import '../../models/parking_condition.dart' show SlotVehicle, evidenceUrlOf;
import '../../ui/adaptive/adaptive.dart';
import '../../ui/time_range_field.dart';
import 'entry_drafts.dart';
import 'entry_pages.dart';
import 'form_parts.dart';
import 'report_sheet.dart' show EvidenceUrlField;
import 'spot_suggestions.dart' show reportSummary;
import 'time_rules.dart';

const _s5Title = '限時／禁停／共用時段';

/// 假日 and days, as both pages note them.
const _holidayNote = '假日含國定假日。';

/// A chip of 管哪幾區: the entry and, when its name does not say so, its bay.
String scopeChipLabel(EntryDraft d) {
  final name = d.displayName, bay = d.kind?.label ?? '';
  return bay.isEmpty || name.contains(bay) ? name : '$name・$bay';
}

/// The rules of [spot] or of a new spot's [drafts].
class TimeRulesPage extends StatefulWidget {
  const TimeRulesPage({
    super.key,
    required this.store,
    required this.type,
    required this.subtitle,
    required this.drafts,
    required this.rules,
    this.spot,
  }) : assert(spot != null || rules != null);
  final AppStore store;
  final EntryType type;
  final String subtitle;

  /// The spot's entries; a new spot's as they stand.
  final List<EntryDraft> drafts;

  /// A new spot's rules so far; null reads them from [drafts].
  final List<TimeRule>? rules;

  /// The spot a suggestion is about; null in a new spot.
  final ParkingSpot? spot;

  @override
  State<TimeRulesPage> createState() => _TimeRulesPageState();
}

class _TimeRulesPageState extends State<TimeRulesPage> {
  late final List<TimeRule> rules =
      widget.rules?.map((r) => r.copy()).toList() ?? rulesOf(widget.drafts);
  int? open;
  bool showErrors = false, sending = false;
  String? refusal;

  /// F1c: blank each time, kept while the summary comes and goes.
  final link = TextEditingController();
  final linkForm = GlobalKey<FormState>();

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  bool get adding => widget.spot == null;
  bool get zones => widget.type == EntryType.zone;
  String get unit => widget.type.unit;
  String get allLabel => zones ? '整個停車場' : '整條路';
  String get allWord => zones ? '全場' : '整條路';
  List<EntryDraft> get drafts => widget.drafts;

  /// A street spot without segments carries its own condition.
  bool get wholeSpot => !adding && drafts.any((d) => d.wholeSpot);

  void update(VoidCallback change) => setState(() {
    change();
    refusal = null;
  });

  void add() => update(() {
    rules.add(TimeRule.create());
    open = rules.length - 1;
    showErrors = false;
  });

  /// 你要改的內容, empty when the rules come to what is stored: the count
  /// is what the patch holds.
  List<ChangeLine> get lines {
    final changes = ruleChanges(rules, drafts, allWord);
    if (adding || changes.isEmpty) return changes;
    applyRules(rules, drafts);
    return drafts.any((d) => d.signs != null || d.slots != null)
        ? changes
        : const [];
  }

  /// Opens the first rule that cannot go and says why.
  bool check() {
    for (final (i, r) in rules.indexed) {
      if (!r.removed && ruleProblems(r, unit).isNotEmpty) {
        setState(() {
          open = i;
          showErrors = true;
        });
        return false;
      }
    }
    final overflow = rulesOverflow(rules, drafts);
    if (overflow != null) setState(() => refusal = overflow);
    return overflow == null;
  }

  /// The patch, or null when an entry cannot take it: a changed entry states
  /// both vehicles, and S5 does not ask them.
  Map<String, Object?>? proposal() {
    applyRules(rules, drafts);
    if (wholeSpot) {
      final spot = widget.spot!;
      final free = spot.fee?.scooter?.mode == FeeMode.free;
      return spotRulesProposal(spot, drafts.single, free: free);
    }
    for (final d in drafts) {
      if ((d.signs != null || d.slots != null) && !d.stated) {
        setState(() => refusal = unstatedEntryNote(d));
        return null;
      }
    }
    return {widget.type.key: entriesPatchOf(drafts, spotFee: widget.spot!.fee)};
  }

  Future<void> submit() async {
    if (!check() || !SuggestionLink.check(linkForm)) return;
    final proposed = proposal();
    if (proposed == null) return;
    final spot = widget.spot!;
    final payload = {
      'action': 'flag',
      'source_id': spot.id,
      'reason': reportSummary(
        '$_s5Title：${[for (final l in lines) '${l.label}：${l.from} → ${l.to}'].join('；')}',
      ),
      'field': wholeSpot ? 'space_type' : widget.type.field,
      if (link.text.trim().isNotEmpty) 'evidence_url': evidenceUrlOf(link.text),
      'proposed': proposed,
    };
    final blocking = precheckBlocking(
      precheck(
        payload,
        current: {
          'fee': ?spot.fee?.toJson(),
          'condition': ?spot.condition?.toJson(),
          'scooter_allowed': ?spot.scooterAllowed,
          'heavy_allowed': ?spot.heavyAllowed,
          widget.type.key: [for (final d in drafts) ?d.original],
        },
      ),
    );
    if (blocking.firstOrNull case final issue?) {
      setState(() => refusal = issue.message);
      return;
    }
    setState(() => sending = true);
    final sent = await sendSuggestion(context, widget.store, payload);
    if (!mounted) return;
    setState(() => sending = false);
    if (!sent) return;
    closeFlow(context);
    showMessage(
      context,
      widget.store.demo ? '範例模式：建議沒有實際送出，只用來測試流程。' : '建議已送出。管理員審核通過後會更新地圖。',
    );
  }

  Widget _card(int i, TimeRule rule) {
    final colors = Theme.of(context).colorScheme;
    final (icon, color) = switch (rule.kind) {
      RuleKind.limit => (Icons.timer_outlined, conditionalColor),
      RuleKind.noParking => (Icons.block, deniedColor),
      RuleKind.share => (Icons.directions_car_outlined, brand),
    };
    return RuleFoldCard(
      key: ValueKey('rule-card-$i'),
      icon: icon,
      iconColor: color,
      title: rule.kind.label,
      summary: ruleSummary(rule, drafts, allWord),
      badge: rule.removed
          ? '將移除'
          : adding || !rule.changed
          ? null
          : '修改中',
      badgeColor: rule.removed ? colors.error : null,
      open: open == i,
      onToggle: () => setState(() {
        open = open == i ? null : i;
        showErrors = false;
      }),
      child: rule.removed
          ? RemoveEntryButton(
              label: '取消移除',
              icon: Icons.undo,
              note: '送出後由管理員確認，再從地圖移除。',
              onPressed: () => update(() => rule.removed = false),
            )
          : _RuleFields(
              rule: rule,
              drafts: drafts,
              zones: zones,
              allLabel: allLabel,
              problems: showErrors && open == i
                  ? ruleProblems(rule, unit)
                  : const {},
              onChanged: update,
              onRemove: () => update(() {
                if (rule.isNew) {
                  rules.removeAt(i);
                  open = null;
                } else {
                  rule.removed = true;
                }
              }),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final changes = lines;
    final count = changes.length;
    return FormPage(
      header: FormHeader(
        title: _s5Title,
        subtitle: widget.subtitle,
        leading: FormHeaderLeading.back,
      ),
      footer: SubmitBar(
        label: adding ? '完成' : '送出 $count 項建議',
        note: adding ? null : '管理員審核後才會更新地圖',
        sending: sending,
        onPressed: adding
            ? () {
                if (check()) Navigator.of(context).pop(rules);
              }
            : count == 0
            ? null
            : submit,
      ),
      children: [
        FormInfoNote(
          icon: Icons.signpost_outlined,
          text: zones
              ? '照入口或場內告示牌填，每條規定選它管哪幾區。點一條展開來改，不確定的就不要動。'
              : '照路邊告示牌填，每條規定選它管哪幾段。點一條展開來改。',
        ),
        const SizedBox(height: 12),
        for (final (i, rule) in rules.indexed) ...[
          _card(i, rule),
          const SizedBox(height: 8),
        ],
        AddEntryButton(label: '新增一條規定', onPressed: add),
        if (!adding && changes.isNotEmpty) ...[
          const SizedBox(height: 16),
          SuggestionLink(
            form: linkForm,
            controller: link,
            field: EvidenceUrlField(controller: link),
          ),
          Divider(color: colors.outlineVariant),
          const SizedBox(height: 8),
          const FormLabel('你要改的內容'),
          const SizedBox(height: 6),
          ChangeSummary(lines: changes),
        ],
        if (refusal != null) ...[
          const SizedBox(height: 12),
          FormInfoNote(
            key: const ValueKey('rule-refusal'),
            icon: Icons.error_outline,
            text: refusal!,
            tone: FormNoteTone.error,
          ),
        ],
      ],
    );
  }
}

/// An open rule's questions.
class _RuleFields extends StatelessWidget {
  const _RuleFields({
    required this.rule,
    required this.drafts,
    required this.zones,
    required this.allLabel,
    required this.problems,
    required this.onChanged,
    required this.onRemove,
  });
  final TimeRule rule;
  final List<EntryDraft> drafts;
  final bool zones;
  final String allLabel;
  final Map<String, String> problems;
  final ValueChanged<VoidCallback> onChanged;
  final VoidCallback onRemove;

  /// 30-minute steps; a stored 20 or 45 stays until the rider moves it.
  static int _snap(int minutes, int low) =>
      math.max(low, minutes ~/ ruleMinutesStep * ruleMinutesStep);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: colors.onSurfaceVariant);
    Widget gap([double h = 14]) => SizedBox(height: h);
    Widget error(String key) => problems[key] == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              problems[key]!,
              key: ValueKey('rule-error-$key'),
              style: TextStyle(fontSize: 13, color: colors.error),
            ),
          );
    final low = math.min(ruleMinutesMin, rule.minutes);
    final high = math.max(ruleMinutesMax, rule.minutes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FormLabel('哪一種規定？'),
        gap(6),
        Semantics(
          label: '規定種類',
          container: true,
          // The iOS control is a fixed height; past this it overflows.
          child: MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.4,
            child: AdaptiveSegmented<RuleKind>(
              key: const ValueKey('rule-kind'),
              options: {for (final k in RuleKind.values) k: k.label},
              value: rule.kind,
              onChanged: (k) => onChanged(() => rule.kind = k),
            ),
          ),
        ),
        gap(),
        FormLabel(zones ? '管哪幾區？' : '管哪幾段？', aside: '可複選'),
        gap(6),
        ScopeChips(
          allLabel: allLabel,
          semanticLabel: zones ? '適用分區' : '適用路段',
          items: [
            for (final d in drafts)
              if (!d.wholeSpot) (d.token, scopeChipLabel(d)),
          ],
          all: rule.all,
          value: rule.scope,
          onChanged: (all, value) => onChanged(() {
            rule.all = all;
            rule.scope = {...value};
          }),
        ),
        error('scope'),
        gap(4),
        Text(
          zones
              ? '依「分區與格位」已有的分區自動列出；那邊新增或刪掉一區，這裡跟著變。'
              : '依「路段與格位」已有的路段自動列出；那邊新增或刪掉一段，這裡跟著變。',
          style: muted,
        ),
        gap(),
        const FormLabel('哪幾天？'),
        gap(6),
        DaysPicker(
          days: rule.days,
          onChanged: (v) => onChanged(() => rule.days = v),
        ),
        error('days'),
        gap(4),
        Text(_holidayNote, style: muted),
        gap(),
        const FormLabel('什麼時段？'),
        gap(6),
        TimeRangeField(
          keyPrefix: 'rule',
          from: rule.from,
          to: rule.to,
          allDay: rule.allDay,
          onChanged: (r) => onChanged(() {
            rule
              ..from = r.from
              ..to = r.to
              ..allDay = r.allDay;
          }),
        ),
        error('time'),
        if (rule.kind == RuleKind.limit) ...[
          gap(),
          const FormLabel('每次限停多久？'),
          gap(6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AdaptiveStepper(
              key: const ValueKey('rule-minutes'),
              label: '每次限停多久',
              value: rule.minutes,
              min: low,
              max: high,
              step: ruleMinutesStep,
              format: minuteLabel,
              onChanged: (v) => onChanged(() => rule.minutes = _snap(v, low)),
            ),
          ),
          gap(10),
          const FormLabel('可以延長幾次？'),
          gap(6),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: AdaptiveStepper(
              key: const ValueKey('rule-extensions'),
              label: '可以延長幾次',
              value: rule.extensions ?? 0,
              min: 0,
              max: ruleExtensionsMax,
              format: (v) => v == 0 ? '不能延長' : '$v 次',
              onChanged: (v) => onChanged(() => rule.extensions = v),
            ),
          ),
          gap(4),
          Text('0 次＝不能延長。延長要多少錢在「怎麼算錢」填。', style: muted),
        ],
        if (rule.kind == RuleKind.share) ...[
          gap(),
          const FormLabel('這段時間開放給', aside: '可複選'),
          gap(6),
          Semantics(
            label: '開放車種',
            container: true,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in SlotVehicle.values)
                  ChoiceTile(
                    key: ValueKey('rule-vehicle-${v.name}'),
                    label: slotVehicleLabel(v),
                    selected: rule.vehicles.contains(v),
                    radius: 22,
                    onTap: () => onChanged(
                      () => rule.vehicles.contains(v)
                          ? rule.vehicles.remove(v)
                          : rule.vehicles.add(v),
                    ),
                  ),
              ],
            ),
          ),
          error('vehicles'),
        ],
        gap(),
        RemoveEntryButton(
          label: '現場沒有這條規定了',
          icon: Icons.delete_outline,
          onPressed: onRemove,
        ),
      ],
    );
  }
}

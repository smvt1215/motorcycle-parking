/// One zone of a lot or one segment of a street while a rider edits it (#190
/// S2, S4): what the form holds, the entry it sends, and what changed.
///
/// A new spot's entries are sent whole with the spot (N1, C14); a suggestion
/// sends a patch by id (`entriesDiff`, C6). Pure Dart.
library;

import 'dart:convert';

import '../../domain/parking_decision.dart' show segmentConditionOf;
import '../../models/fee.dart';
import '../../models/parking.dart';
import '../../models/parking_condition.dart';
import '../../models/space_kind.dart';
import '../../models/zone_entries.dart';
import 'report_rules.dart';

export '../../models/zone_entries.dart' show RoadSide;

/// Whether a draft is a lot's zone or a street's segment.
enum EntryType {
  zone(
    unit: '區',
    field: 'zones',
    key: 'parking_zones',
    guideMax: 200,
    maxEntries: 10,
  ),
  segment(
    unit: '段',
    field: 'segments',
    key: 'parking_segments',
    guideMax: segmentGuideMaxLength,
    maxEntries: segmentMaxEntries,
  );

  const EntryType({
    required this.unit,
    required this.field,
    required this.key,
    required this.guideMax,
    required this.maxEntries,
  });

  /// How forms count them: 新增一區、新增一段.
  final String unit;

  /// The `field` a suggestion is sent under.
  final String field;

  /// The spot's list key.
  final String key;

  /// The guide's limit (C13).
  final int guideMax;

  /// How many entries a spot takes.
  final int maxEntries;
}

/// A zone's name limit (`validRiderZone`).
const zoneNameMaxLength = 40;

/// The painted bay [kind] stands for, charge left unsaid: the bay forms do
/// not ask it (FIX; a street bay's fee says it).
ParkingCondition bayConditionOf(SpaceKind kind) {
  final base = conditionOf(kind.baseType);
  return ParkingCondition(
    bay: base?.bay,
    use: kind == SpaceKind.scooterHeavy ? BayUse.share : base?.use,
    share: kind == SpaceKind.scooterHeavy
        ? ShareKind.scooterHeavy
        : base?.share,
    limits: base?.limits ?? const [],
  );
}

/// Why a bay of [kind] cannot take these vehicles, or null: a heavy bay
/// never takes scooters (`validCondition`). Any other pick can be written;
/// a zone without a derived `access` simply carries none (#356).
String? bayAllowProblem(SpaceKind? kind, Eligible? scooter) =>
    kind == SpaceKind.heavy && scooter == Eligible.allowed
    ? '重機專用格不能開放普通機車。普通機車請改選不可停，或改選地面畫的格位。'
    : null;

/// The name a segment takes when left blank (C3): 「{側}・{格位}」, the bay
/// alone without a side, and 2, 3… after it when [taken] has that name.
String autoSegmentName(
  RoadSide? side,
  SpaceKind? kind,
  Iterable<String> taken,
) {
  final bay = kind?.label ?? '路段';
  final base = side == null ? bay : '${side.label}・$bay';
  if (!taken.contains(base)) return base;
  var n = 2;
  while (taken.contains('$base $n')) {
    n++;
  }
  return '$base $n';
}

/// 從 and 到 as `range` (C4): 「{從}至{到}」, 「{從}起」, 「至{到}」 or empty.
String composeRange(String from, String to) {
  final a = from.trim(), b = to.trim();
  if (a.isEmpty) return b.isEmpty ? '' : '至$b';
  return b.isEmpty ? '$a起' : '$a至$b';
}

/// A stored `range` in 從 and 到; one that does not split stays whole in 從
/// (C4).
(String, String) splitRange(String range) {
  final parts = range.split('至');
  if (parts.length == 2) {
    if (parts[0].isEmpty) return ('', parts[1]);
    if (parts[1].isNotEmpty) return (parts[0], parts[1]);
  }
  if (parts.length == 1 && range.length > 1 && range.endsWith('起')) {
    return (range.substring(0, range.length - 1), '');
  }
  return (range, '');
}

/// A stored [ParkingLimit] as a new write takes it (#188 layer 2): with its
/// periods. An old all-day one becomes a period that does not extend; one
/// without minutes says nothing a write can keep.
ParkingLimit? writableLimit(ParkingLimit limit) {
  if (limit.kind != LimitKind.timeLimit || limit.periods.isNotEmpty) {
    return limit;
  }
  final minutes = limit.maxMinutes;
  if (minutes == null) return null;
  return ParkingLimit(
    LimitKind.timeLimit,
    periods: [LimitPeriod(days: 'all', maxMinutes: minutes, extensions: 0)],
  );
}

/// What [fee] says a motorcycle bay charges: toll or free when the vehicles
/// parking there agree, a rate by time being toll if any period is. Null when
/// it says neither or they differ; that stays unconfirmed (`ruleKindsOf`).
Charge? chargeOfFee(Fee fee) =>
    Charge.values.asNameMap()[chargeOfFeeJson(fee.toJson())];

/// One zone or segment as a form holds it.
class EntryDraft {
  EntryDraft.create(this.type) : original = null, stored = null;

  /// [zone] as stored; its vehicles read from its condition, else its access.
  EntryDraft.ofZone(ParkingZone zone)
    : type = EntryType.zone,
      original = zone.toJson(),
      stored = zone.condition ?? zoneConditionOf(zone.access) {
    name = zone.name;
    guide = zone.guide;
    evidence = zone.evidenceUrl;
    fee = zone.fee;
    _load();
  }

  /// [segment] as stored; a name C3 would give shows as blank, so a new side
  /// or bay names it again. What it inherits from [spot] reads as decisions
  /// read it: nothing is sent for it until the rider changes the condition,
  /// which then states all of it, as a bay stops the inheriting.
  EntryDraft.ofSegment(ParkingSegment segment, {ParkingSpot? spot})
    : type = EntryType.segment,
      original = segment.toJson(),
      stored = spot == null
          ? segment.condition
          : segmentConditionOf(segment, spot) {
    side = segment.side;
    guide = segment.guide;
    evidence = segment.evidenceUrl;
    total = segment.total == null ? '' : '${segment.total}';
    fee = segment.fee;
    final (start, end) = splitRange(segment.range);
    from = start;
    to = end;
    _load();
    name = segment.name == autoSegmentName(side, kind, const [])
        ? ''
        : segment.name;
    _loadedName = name;
    _loadedFrom = from;
    _loadedTo = to;
  }

  /// The whole of a street spot without segments, as the one segment it has
  /// been so far (GAP risk 7): nothing changes until the rider does, and it
  /// is then sent as a new segment, with the spot's limits, periods and
  /// count, as decisions and the seat plate then read the segment.
  EntryDraft.ofSpot(ParkingSpot spot)
    : type = EntryType.segment,
      original = null,
      stored = spot.condition ?? conditionOf(spot.spaceType) {
    kind = SpaceKind.of(spot.spaceType, spot.condition);
    scooter = Eligible.of(spot.scooterAllowed);
    heavy = Eligible.of(spot.heavyAllowed);
    guide = spot.parkingGuide;
    // A count no segment can carry would only block the form.
    if (spot.scooterTotal case final count?
        when count >= segmentTotalRange.$1 && count <= segmentTotalRange.$2) {
      total = '$count';
    }
    _loadedTotal = total;
    wholeSpot = true;
    _loadedKind = kind;
    _loadedScooter = scooter;
    _loadedHeavy = heavy;
    _loadedGuide = guide;
  }

  EntryDraft._copy(EntryDraft d)
    : type = d.type,
      original = d.original,
      stored = d.stored,
      wholeSpot = d.wholeSpot,
      name = d.name,
      from = d.from,
      to = d.to,
      total = d.total,
      guide = d.guide,
      evidence = d.evidence,
      side = d.side,
      kind = d.kind,
      scooter = d.scooter,
      heavy = d.heavy,
      removed = d.removed,
      vehiclesEdited = d.vehiclesEdited,
      fee = d.fee,
      token = d.token,
      signs = d.signs,
      slots = d.slots,
      _loadedKind = d._loadedKind,
      _loadedScooter = d._loadedScooter,
      _loadedHeavy = d._loadedHeavy,
      _loadedName = d._loadedName,
      _loadedFrom = d._loadedFrom,
      _loadedTo = d._loadedTo,
      _loadedGuide = d._loadedGuide,
      _loadedTotal = d._loadedTotal;

  final EntryType type;

  /// The entry as stored; null for a new one.
  final Map<String, dynamic>? original;

  /// The stored condition, an access-only zone's as its access reads.
  final ParkingCondition? stored;

  /// Stands for a spot without segments ([EntryDraft.ofSpot]).
  bool wholeSpot = false;

  String name = '', from = '', to = '', total = '', guide = '', evidence = '';
  RoadSide? side;
  SpaceKind? kind;
  Eligible? scooter, heavy;

  /// 這區已撤除 / 這段已撤除: goes as `{id, removed: true}`.
  bool removed = false;

  /// Once the rider picks a vehicle, a new bay kind no longer refills them.
  bool vehiclesEdited = false;

  /// Its own rates; null takes the spot's (#242).
  Fee? fee;

  /// Names this entry across its copies: 管哪幾區 keeps it (S5).
  Object token = Object();

  /// The 限時 and 禁停 limits, and the 共用時段, S5 and S5b set; null keeps
  /// the stored ones.
  List<ParkingLimit>? signs;
  List<ScheduleSlot>? slots;

  SpaceKind? _loadedKind;
  Eligible? _loadedScooter, _loadedHeavy;
  String _loadedName = '', _loadedFrom = '', _loadedTo = '', _loadedGuide = '';
  String _loadedTotal = '';

  void _load() {
    final c = stored;
    kind = switch (bayKindOf(c)) {
      final bay? => SpaceKind.ofBay(bay),
      null => null,
    };
    scooter = _eligible(c, 'scooter');
    heavy = _eligible(c, 'heavy');
    _loadedKind = kind;
    _loadedScooter = scooter;
    _loadedHeavy = heavy;
    _loadedName = name;
    _loadedGuide = guide;
    _loadedTotal = total;
  }

  static Eligible? _eligible(ParkingCondition? c, String vehicle) {
    final a = c?.allow;
    if (a == null) return null;
    return vehicle == 'heavy'
        ? Eligible.of(a.heavy, notStated: a.heavyNotStated)
        : Eligible.of(a.scooter, notStated: a.scooterNotStated);
  }

  /// A copy a page edits, kept only when the rider confirms it.
  EntryDraft copy() => EntryDraft._copy(this);

  bool get isNew => original == null;
  String? get id => original?['id'] as String?;

  /// Whether it says who may park: a changed entry must (#201, layer 2).
  bool get stated => scooter != null && heavy != null;

  /// A stored entry without an id cannot be patched (the table gives every
  /// entry one, so only old caches read so).
  bool get editable => isNew || id != null;

  /// What a page calls it: its name, else the name C3 gives it.
  String get displayName {
    if (name.trim().isNotEmpty) return name.trim();
    if (wholeSpot) return '整段';
    if (type == EntryType.segment) return autoSegmentName(side, kind, const []);
    return '新的分區';
  }

  /// 汽機車共用格・6 格.
  String get detail => [
    ?kind?.label,
    if (type == EntryType.segment && total.isNotEmpty) '$total 格',
  ].join('・');

  /// A collapsed row: 北側　汽機車共用格・6 格. The side always leads; a
  /// name follows it unless it only repeats the bay.
  String get rowLabel {
    final named = name.trim();
    final bay = kind?.label ?? '';
    final repeats = bay.isNotEmpty && named.contains(bay);
    return [
      ?side?.label,
      if (named.isNotEmpty && !repeats)
        named
      else if (named.isEmpty && side == null && type == EntryType.zone)
        displayName,
      detail,
    ].where((t) => t.isNotEmpty).join('　');
  }

  /// The map's words for this entry as loaded, whatever the form holds now
  /// (S2's and S4's 地圖上目前寫的).
  String get storedLabel {
    final kind = _loadedKind?.label;
    final stored = original?['name'] as String? ?? '';
    return kind == null ? stored : '$stored（$kind）';
  }

  /// [storedLabel] for a segment: where it runs, how many, who may park.
  String get storedDetail {
    final range = original?['range'] as String? ?? '';
    return [
      if (range.isNotEmpty) range,
      if (_loadedTotal.isNotEmpty) '共 $_loadedTotal 格',
      if (_loadedScooter != null && _loadedHeavy != null)
        '普通機車${_loadedScooter!.label}、大型重機${_loadedHeavy!.label}',
    ].join('，');
  }

  /// `range` as sent: the stored words while 從 and 到 read as they did.
  String get range => from == _loadedFrom && to == _loadedTo && !isNew
      ? (original?['range'] as String? ?? '')
      : composeRange(from, to);

  /// The eligibility a new [kind] suggests until the rider picks (S4).
  void applyDefaults(
    List<CityRule> rules,
    String? city, {
    String district = '',
  }) {
    if (vehiclesEdited || kind == null) return;
    final d = bayDefaults(rules, kind!, city, district: district);
    scooter = Eligible.of(d.scooter);
    heavy = Eligible.of(d.heavy);
  }

  bool get _conditionChanged =>
      kind != _loadedKind ||
      scooter != _loadedScooter ||
      heavy != _loadedHeavy ||
      signs != null ||
      slots != null ||
      // A segment without `allow` states both once it changes (#188 layer 2).
      (type == EntryType.segment && _segmentUnstated);

  bool get _segmentUnstated {
    final a = stored?.allow;
    return a == null || !a.states('scooter') || !a.states('heavy');
  }

  /// The condition sent: every facet this form does not show stays as
  /// stored while the bay does (limits and periods go on across bays, a
  /// schedule only on a shared car bay), never a basis (§1.4).
  ParkingCondition get condition => conditionUnder(null);

  /// [condition] with the charge a street bay's rates say, its own or else
  /// [spotFee], when nothing stored says it: the bay forms do not ask it.
  ParkingCondition conditionUnder(Fee? spotFee) {
    final kind = this.kind;
    final same = kind == _loadedKind;
    final bay = kind == null ? const ParkingCondition() : bayConditionOf(kind);
    final old = stored;
    final kept = same ? old : null;
    final signs =
        this.signs ??
        [
          for (final l in old?.limits ?? const <ParkingLimit>[])
            if (l.kind == LimitKind.timeLimit || l.kind == LimitKind.noParking)
              ?writableLimit(l),
        ];
    // Any other limit is the bay's: those stored stay while the bay does.
    final fixed = same && old != null
        ? [
            for (final l in old.limits)
              if (l.kind != LimitKind.timeLimit &&
                  l.kind != LimitKind.noParking)
                l,
          ]
        : bay.limits;
    final rates = fee ?? spotFee;
    return ParkingCondition(
      bay: kept?.bay ?? bay.bay,
      use: kept?.use ?? bay.use,
      share: kept?.share ?? bay.share,
      charge:
          old?.charge ??
          (type == EntryType.segment &&
                  kind?.asksCharge == true &&
                  rates != null
              ? chargeOfFee(rates)
              : null),
      limits: [...fixed, ...signs],
      schedule:
          slots ??
          (same || kind == SpaceKind.carMotorcycle
              ? old?.schedule ?? const []
              : const []),
      allow: ZoneAllow(
        scooter: scooter?.flag,
        heavy: heavy?.flag,
        scooterNotStated: scooter == Eligible.notStated,
        heavyNotStated: heavy == Eligible.notStated,
      ),
    );
  }

  /// The entry as it would be stored; [taken] names C3 must avoid, and
  /// [spotFee] is the rates it falls back on.
  Map<String, Object?> toJson(Iterable<String> taken, {Fee? spotFee}) {
    final text = name.trim();
    final out = <String, Object?>{...?original};
    if (type == EntryType.zone) {
      out['name'] = text;
    } else {
      out['name'] = text.isEmpty ? autoSegmentName(side, kind, taken) : text;
      void put(String key, Object? value) =>
          value == null ? out.remove(key) : out[key] = value;
      put('side', side?.name);
      put('range', range.isEmpty ? null : range);
      put('total', int.tryParse(total.trim()));
    }
    guide.trim().isEmpty ? out.remove('guide') : out['guide'] = guide.trim();
    evidence.trim().isEmpty
        ? out.remove('evidence_url')
        : out['evidence_url'] = evidenceUrlOf(evidence);
    if (isNew || _conditionChanged) {
      final c = conditionUnder(spotFee);
      out['condition'] = c.toJson();
      if (type == EntryType.zone) {
        out.remove('access');
        if (legacyAccess(c) case final access?) out['access'] = access.name;
      }
    }
    // Without its own rates it follows the spot's again (F1b).
    if (fee case final fee? when !fee.isEmpty) {
      out['fee'] = fee.toJson();
    } else {
      out.remove('fee');
    }
    return out;
  }

  bool get _feeChanged {
    if (isNew) return false;
    final now = fee == null || fee!.isEmpty ? null : fee!.toJson();
    return jsonEncode(now) != jsonEncode(original!['fee']);
  }

  /// Whether the rider changed anything.
  bool get changed {
    // S5's rules and F1's rates, which have no line of their own here.
    if (removed || signs != null || slots != null || _feeChanged) return true;
    if (wholeSpot) {
      return kind != _loadedKind ||
          scooter != _loadedScooter ||
          heavy != _loadedHeavy ||
          guide.trim() != _loadedGuide ||
          name.trim().isNotEmpty ||
          from.trim().isNotEmpty ||
          to.trim().isNotEmpty ||
          total.trim() != _loadedTotal ||
          evidence.trim().isNotEmpty ||
          side != null;
    }
    return isNew || changeLines().isNotEmpty;
  }

  static String _shown(String value) => value.isEmpty ? '未填' : value;
  static String _vehicle(Eligible? value) => value?.label ?? '待確認';

  /// 你要改的內容 for this entry, one line per changed value.
  List<ChangeLine> changeLines() {
    if (removed) {
      return [ChangeLine(label: '這${type.unit}', from: '地圖上有', to: '已撤除')];
    }
    if (isNew && !wholeSpot) {
      return [
        ChangeLine(label: '新增一${type.unit}', from: '沒有', to: displayName),
      ];
    }
    ChangeLine? line(String label, String a, String b) => a == b
        ? null
        : ChangeLine(label: label, from: _shown(a), to: _shown(b));
    final oldName = wholeSpot ? '' : _loadedName;
    return [
      ?line('名稱', oldName, name.trim()),
      if (type == EntryType.segment) ...[
        ?line('哪一側', switch (original?['side']) {
          final String s => RoadSide.values.byName(s).label,
          _ => '',
        }, side?.label ?? ''),
        ?line('範圍', original?['range'] as String? ?? '', range),
        ?line('共幾格', _loadedTotal, total.trim()),
      ],
      ?line('格位', _loadedKind?.label ?? '', kind?.label ?? ''),
      if (scooter != _loadedScooter)
        ChangeLine(
          label: '普通機車',
          from: _vehicle(_loadedScooter),
          to: _vehicle(scooter),
        ),
      if (heavy != _loadedHeavy)
        ChangeLine(
          label: '大型重機',
          from: _vehicle(_loadedHeavy),
          to: _vehicle(heavy),
        ),
      ?line('指引', _loadedGuide, guide.trim()),
      ?line(
        '公告連結',
        evidenceUrlOf(original?['evidence_url'] as String?),
        evidenceUrlOf(evidence),
      ),
    ];
  }
}

/// 全區 or 整條路 (Z1): who may park, set once for the entries not set apart.
/// It lives only while a form is open: sending expands it into each entry's
/// own value, so stored data never holds it (#408).
class EntryWhole {
  const EntryWhole(this.scooter, this.heavy);
  final Eligible scooter, heavy;

  /// 普機 可停，重機 不可停.
  String get summary => '普機 ${scooter.label}，重機 ${heavy.label}';

  /// [d] holds this value already.
  bool matches(EntryDraft d) => d.scooter == scooter && d.heavy == heavy;

  /// [d] takes this value, unless its own was set apart ([matches] false
  /// and stated): the caller decides. A heavy bay keeps scooters out
  /// (`validCondition`).
  void applyTo(EntryDraft d) {
    final heavyBay = d.kind == SpaceKind.heavy && scooter == Eligible.allowed;
    d.scooter = heavyBay ? (d.scooter ?? Eligible.notAllowed) : scooter;
    d.heavy = heavy;
    d.vehiclesEdited = true;
  }

  @override
  bool operator ==(Object other) =>
      other is EntryWhole && other.scooter == scooter && other.heavy == heavy;

  @override
  int get hashCode => Object.hash(scooter, heavy);
}

/// What the stored [drafts] read as a 全區: the value every entry stating
/// who may park shares, null when they differ or none states it (#408:
/// nothing stores a 全區, so it is judged from whether the values agree).
/// Taken from what was loaded, so it holds while the rider edits a copy.
EntryWhole? entryWholeOf(Iterable<EntryDraft> drafts) {
  final seen = <EntryWhole>{};
  for (final d in drafts) {
    if (d.removed || d.isNew) continue;
    final scooter = d._loadedScooter, heavy = d._loadedHeavy;
    if (scooter == null || heavy == null) continue;
    seen.add(EntryWhole(scooter, heavy));
    if (seen.length > 1) return null;
  }
  return seen.singleOrNull;
}

/// Whether [d] takes a change of 全區 ([whole], the value before it) with
/// nothing set apart: it follows that value, or says nothing yet.
bool entryFollows(EntryDraft d, EntryWhole? whole) =>
    !d.stated || (whole?.matches(d) ?? false);

/// Why [d] cannot take a change from a page that does not ask who may park.
String unstatedEntryNote(EntryDraft d) =>
    '「${d.displayName}」還沒寫哪些車種可停，請先到「停哪裡」補上，再改這裡。';

/// One row of 你要改的內容.
class ChangeLine {
  const ChangeLine({required this.label, required this.from, required this.to});
  final String label, from, to;
}

/// Whether [d] goes with a suggestion on [drafts]. A whole-spot entry goes
/// with any new segment even when untouched: once a spot has segments,
/// decisions read only those, so its bay, limits and periods must become
/// the first one rather than lapse.
bool entrySent(EntryDraft d, List<EntryDraft> drafts) =>
    d.changed ||
    (d.wholeSpot && drafts.any((o) => !o.wholeSpot && !o.removed && o.isNew));

/// 你要改的內容 for [d] among [drafts]: an untouched whole-spot entry that
/// goes as the first segment says so, so the summary and count show it.
List<ChangeLine> entryLines(EntryDraft d, List<EntryDraft> drafts) {
  final lines = d.changeLines();
  return lines.isEmpty && entrySent(d, drafts)
      ? const [ChangeLine(label: '第一段', from: '沒有', to: '沿用目前的內容')]
      : lines;
}

/// The names [draft] must not take: the other entries' as they will read.
Iterable<String> _others(List<EntryDraft> drafts, EntryDraft draft) => [
  for (final d in drafts)
    if (!identical(d, draft) && !d.removed && d.name.trim().isNotEmpty)
      d.name.trim()
    else if (!identical(d, draft) && !d.removed && !d.isNew)
      d.original!['name'] as String,
];

/// [drafts] as sent with a new spot: each with its name, none with an id.
/// [spotFee] is the rates an entry without its own takes.
List<Map<String, Object?>> entriesOf(List<EntryDraft> drafts, {Fee? spotFee}) {
  final out = <Map<String, Object?>>[];
  final taken = <String>[];
  for (final d in drafts) {
    final json = d.toJson([..._others(drafts, d), ...taken], spotFee: spotFee);
    taken.add(json['name']! as String);
    out.add(json);
  }
  return out;
}

/// The patch a suggestion sends for [drafts] (`entries_patch()`): only the
/// entries changed. A zone's condition goes with the access it derives, as
/// the check reads the two together; with none derived, a stored access is
/// cleared by the diff's null and no key is sent otherwise (#356).
List<Map<String, Object?>> entriesPatchOf(
  List<EntryDraft> drafts, {
  Fee? spotFee,
}) {
  final current = [
    for (final d in drafts)
      if (d.editable) ?d.original,
  ];
  final next = <Map<String, Object?>>[];
  final taken = <String>[];
  for (final d in drafts) {
    if (d.removed || !d.editable) continue;
    if (d.wholeSpot && !entrySent(d, drafts)) continue;
    // An entry left alone stays as stored: toJson would state its allow.
    if (!d.isNew && !d.changed) {
      next.add(d.original!);
      taken.add(d.original!['name'] as String);
      continue;
    }
    final json = d.toJson([..._others(drafts, d), ...taken], spotFee: spotFee);
    taken.add(json['name']! as String);
    next.add(json);
  }
  return [
    for (final change in entriesDiff(current, next))
      if (change.containsKey('id') && change.containsKey('condition'))
        {
          ...change,
          'access': ?next.firstWhere((e) => e['id'] == change['id'])['access'],
        }
      else
        change,
  ];
}

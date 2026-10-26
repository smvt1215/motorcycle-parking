import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../models/parking.dart';
import '../../ui/location_picker.dart';
import '../admin_theme.dart';
import '../review/review_page.dart' show ChangeBand, reviewCompactWidth;
import 'spot_map.dart';
import 'spot_models.dart';
import 'spots_controller.dart';

const _wideWidth = 1040.0;

/// Widths of the panels over the map; the camera keeps the open spot clear
/// of them.
double _listWidth(double width) => width >= _wideWidth ? 380 : 300;
double _formWidth(double width) =>
    width >= _wideWidth ? 480 : (width * .56).clamp(360.0, 440.0);

/// `/spots` and `/spots/<source id>`: search both tables and edit one spot.
class SpotsPage extends StatefulWidget {
  const SpotsPage({
    super.key,
    required this.spots,
    required this.map,
    required this.selectedId,
    this.newKind,
    this.locationMapBuilder,
    this.spotMapBuilder = googleSpotMap,
  });
  final SpotsController spots;
  final SpotMapController map;
  final SpotMapBuilder spotMapBuilder;

  /// A source id, `new` for a spot being created, or null for the list.
  final String? selectedId;

  /// The kind of a new spot, from `/spots/new?kind=`.
  final SpotKind? newKind;
  final LocationMapBuilder? locationMapBuilder;

  @override
  State<SpotsPage> createState() => _SpotsPageState();
}

class _SpotsPageState extends State<SpotsPage> {
  final query = TextEditingController();
  final note = TextEditingController();
  Timer? _debounce;
  Timer? _locate;

  /// Bumped when the picker moves the spot, so the coordinate fields show it.
  int _moves = 0;

  /// Where a new spot starts: the last spot opened, else Taipei Main Station.
  (double, double) _center = (25.0478, 121.5170);

  /// The list panel beside the map (680 px and wider). At 680–1039 px it
  /// steps aside while a form is open, unless the admin brings it back for
  /// that form ([_listBesideForm]).
  bool _listOpen = true;
  bool _listBesideForm = false;

  bool _showsList(double width, bool open) => width < reviewCompactWidth
      ? false
      : width >= _wideWidth || !open
      ? _listOpen
      : _listBesideForm;

  /// Below 680 px the map and the list take turns.
  bool _phoneList = false;

  /// The next spot opened came from its marker: the map pans only as far as
  /// needed to clear the form, keeping the zoom.
  bool _fromMarker = false;
  SpotMapFocus? _focus;
  int _focusSeq = 0;
  String? _focusedFor;

  /// The open spot and version, so a write reloads the map's spots.
  String? _shownVersion;
  double _width = 1280;

  SpotsController get spots => widget.spots;
  SpotMapController get map => widget.map;

  @override
  void initState() {
    super.initState();
    query.text = spots.query;
    spots.addListener(_spotsChanged);
    // Loading notifies listeners; never during this first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!spots.searched && !spots.searching) spots.search();
      _follow();
    });
  }

  /// Follows the open spot on the map: moves there once it has loaded, and
  /// reloads the map after a write changed it.
  void _spotsChanged() {
    final r = spots.record;
    final version = r == null
        ? null
        : '${r.sourceId}@${r.updatedAt}@${r.hidden}';
    final previous = _shownVersion;
    _shownVersion = version;
    if (version != null &&
        previous != null &&
        previous != version &&
        (previous.startsWith('${r!.sourceId}@') ||
            previous.startsWith('new@'))) {
      map.refresh();
    }
    final key = r?.sourceId;
    if (key == _focusedFor) return;
    _focusedFor = key;
    final lat = spots.draft['lat'] ?? r?.values['lat'];
    final lng = spots.draft['lng'] ?? r?.values['lng'];
    _listBesideForm = false;
    if (r == null || lat is! num || lng is! num) return;
    final compact = _width < reviewCompactWidth;
    final left = _showsList(_width, true) ? _listWidth(_width) : 0.0;
    final right = compact ? 0.0 : _formWidth(_width);
    final fromMarker = _fromMarker;
    _fromMarker = false;
    _setState(
      () => _focus = SpotMapFocus(
        lat: lat.toDouble(),
        lng: lng.toDouble(),
        zoom: fromMarker ? null : 18,
        leftOfCenter: (right - left) / 2,
        seq: ++_focusSeq,
      ),
    );
  }

  void _setState(VoidCallback change) {
    if (!mounted) return;
    // The controller may notify during a build; apply after it.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(change);
      });
    } else {
      setState(change);
    }
  }

  @override
  void didUpdateWidget(covariant SpotsPage old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId || old.newKind != widget.newKind) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
    }
  }

  /// Keeps the form on the spot named by the URL.
  void _follow() {
    final id = widget.selectedId;
    if (!mounted) return;
    final current = spots.record;
    final lat = current?.values['lat'], lng = current?.values['lng'];
    if (current != null && !current.isNew && lat is num && lng is num) {
      _center = (lat.toDouble(), lng.toDouble());
    }
    if (id == 'new') {
      final kind = widget.newKind ?? SpotKind.community;
      if (current == null || !current.isNew || current.newKind != kind) {
        note.clear();
        spots.startNew(kind, _center.$1, _center.$2);
      }
    } else if (id == null) {
      if (current != null) spots.close();
    } else if (current?.sourceId != id && !spots.opening) {
      note.clear();
      spots.open(id);
    }
  }

  @override
  void dispose() {
    spots.removeListener(_spotsChanged);
    _debounce?.cancel();
    _locate?.cancel();
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

  /// True when it navigated.
  Future<bool> _go(String? id) async {
    if (id == spots.record?.sourceId && id != null) return false;
    if (!await _mayLeave() || !mounted) return false;
    context.go(id == null ? '/spots' : '/spots/$id');
    return true;
  }

  void _search(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      spots.query = value;
      spots.search();
    });
  }

  /// A position change from the picker or the coordinate fields; the county,
  /// district and duplicates follow once the admin stops moving it.
  void _move(double lat, double lng, {bool fromPicker = true}) {
    spots.set('lat', lat);
    spots.set('lng', lng);
    if (fromPicker) setState(() => _moves++);
    _locate?.cancel();
    _locate = Timer(const Duration(milliseconds: 600), spots.locate);
  }

  Future<void> _save() async {
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final name = spots.draft['name'] as String? ?? '';
    final creating = spots.record?.isNew == true;
    // The save runs the lookup itself; a pending debounce would only repeat it.
    _locate?.cancel();
    final notes = spots.notes;
    if (notes.far) {
      final same = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('移動超過 150 m'),
          content: Text(
            '新位置距原位置約 ${notes.moved!.round()} m。確認這仍是同一個點位？'
            '若是另一個停車點，請改用「新增停車點」。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('回去調整'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('是同一個點位，儲存'),
            ),
          ],
        ),
      );
      if (same != true || !mounted) return;
    }
    if (await spots.save(note.text.trim())) {
      note.clear();
      messenger.showSnackBar(
        SnackBar(content: Text('${creating ? '已建立' : '已儲存'}：$name')),
      );
      router.go(creating ? '/spots/${spots.record!.sourceId}' : '/spots');
    }
  }

  Future<void> _create() async {
    final kind = await showDialog<SpotKind>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('新增停車點'),
        children: [
          // Tappable tiles expose one button each to screen readers.
          ListTile(
            onTap: () => Navigator.pop(context, SpotKind.community),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('社群點'),
            subtitle: const Text('現場確認、尚無官方資料的停車點'),
          ),
          ListTile(
            onTap: () => Navigator.pop(context, SpotKind.official),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            title: const Text('官方點'),
            subtitle: const Text('有縣市政府公告或場站資料，需填官方來源'),
          ),
        ],
      ),
    );
    if (kind == null || !mounted || !await _mayLeave() || !mounted) return;
    final current = spots.record;
    if (widget.selectedId == 'new' &&
        current != null &&
        current.isNew &&
        current.newKind == kind) {
      // Same URL: nothing follows the navigation, and the discard above
      // dropped the looked-up county and district; start over here.
      _locate?.cancel();
      note.clear();
      spots.startNew(kind, _center.$1, _center.$2);
      return;
    }
    context.go('/spots/new?kind=${kind.name}');
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
    if (id != null) {
      map.refresh();
      router.go('/spots/$id');
    }
  }

  /// Opens a spot from its marker; the list and the URL open the others.
  void _tapMarker(ParkingSpot spot) {
    if (spot.id == spots.record?.sourceId) return;
    _fromMarker = true;
    _go(spot.id).then((went) {
      // Stayed on the current form: the next open is not from this marker.
      if (!went) _fromMarker = false;
    });
  }

  Widget _map(bool covered) {
    final record = spots.record;
    final open = widget.selectedId != null;
    return widget.spotMapBuilder(
      context,
      SpotMapView(
        center: LatLng(_center.$1, _center.$2),
        spots: map.shown,
        eligibility: map.eligible,
        dimmed: map.isHidden,
        satellite: map.satellite,
        covered: covered,
        focus: _focus,
        selected: open && record != null && record.sourceId == widget.selectedId
            ? selectedSpot(record, spots.draft, map.find(record.sourceId))
            : null,
        onViewport: map.show,
        onSpotTap: _tapMarker,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([spots, map]),
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        _width = width;
        final compact = width < reviewCompactWidth;
        final open = widget.selectedId != null;
        final list = _ListPane(
          spots: spots,
          query: query,
          selectedId: widget.selectedId,
          compact: compact,
          onQuery: _search,
          onPick: _go,
          onCreate: _create,
        );
        final form = _FormPane(
          spots: spots,
          note: note,
          compact: compact,
          selectedId: widget.selectedId,
          backLabel: _phoneList ? '返回點位清單' : '返回地圖',
          onBack: () => _go(null),
          onSave: _save,
          onHide: _setHidden,
          onPromote: _promote,
          onMove: _move,
          moves: _moves,
          mapBuilder: widget.locationMapBuilder,
          onReload: () {
            final id = widget.selectedId;
            if (id != null) spots.open(id);
          },
        );
        final controls = _intercept(SpotMapControls(map: map));
        if (compact) {
          // Phone: the form, or the map and list taking turns. The map
          // stays mounted underneath so its camera survives.
          final covered = open || _phoneList;
          return Stack(
            children: [
              Positioned.fill(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _PhoneSwitch(
                      list: _phoneList,
                      onChanged: (v) => setState(() => _phoneList = v),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(child: _map(covered)),
                          if (!covered)
                            Positioned(
                              left: 12,
                              right: 12,
                              top: 12,
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: controls,
                              ),
                            ),
                          if (_phoneList && !open)
                            Positioned.fill(child: _intercept(list)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (open) Positioned.fill(child: _intercept(form)),
            ],
          );
        }
        final listWidth = _listWidth(width);
        final formWidth = _formWidth(width);
        final showList = _showsList(width, open);
        final left = showList ? listWidth : 0.0;
        final right = open ? formWidth : 0.0;
        final colors = Theme.of(context).colorScheme;
        final edge = BorderSide(color: colors.outlineVariant);
        return Stack(
          children: [
            Positioned.fill(child: _map(false)),
            if (showList)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: listWidth,
                child: _intercept(
                  DecoratedBox(
                    decoration: BoxDecoration(border: Border(right: edge)),
                    child: list,
                  ),
                ),
              ),
            if (open)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: formWidth,
                child: _intercept(
                  DecoratedBox(
                    decoration: BoxDecoration(border: Border(left: edge)),
                    child: form,
                  ),
                ),
              ),
            Positioned(
              left: left + 12,
              top: 12,
              // With no room between the panels, the list toggle alone
              // stays reachable over the form's empty top corner.
              right: width - left - right >= 260 ? right + 12 : null,
              child: Align(
                alignment: Alignment.topLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _intercept(
                      _ListToggle(
                        open: showList,
                        // A narrow map between the panels keeps the icon only.
                        iconOnly: width - left - right < 520,
                        onPressed: () => setState(() {
                          if (width >= _wideWidth || !open) {
                            _listOpen = !showList;
                          } else {
                            _listBesideForm = !showList;
                          }
                        }),
                      ),
                    ),
                    // Both panels open on a narrow window leave no room.
                    if (width - left - right >= 260) ...[
                      const SizedBox(width: 8),
                      Flexible(child: controls),
                    ],
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// Panels over the Google map take the pointer on the web; elsewhere this
/// is the child itself.
Widget _intercept(Widget child) =>
    PointerInterceptor(intercepting: kIsWeb, child: child);

/// Shows or hides the list panel beside the map.
class _ListToggle extends StatelessWidget {
  const _ListToggle({
    required this.open,
    required this.onPressed,
    this.iconOnly = false,
  });
  final bool open, iconOnly;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: open || iconOnly
          ? IconButton(
              key: const ValueKey('list-toggle'),
              tooltip: open ? '收起清單' : '顯示清單',
              constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
              onPressed: onPressed,
              icon: Icon(open ? Icons.chevron_left : Icons.view_list_outlined),
            )
          : Padding(
              padding: const EdgeInsets.all(4),
              child: TextButton.icon(
                key: const ValueKey('list-toggle'),
                onPressed: onPressed,
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                icon: const Icon(Icons.view_list_outlined),
                label: const Text('顯示清單'),
              ),
            ),
    );
  }
}

/// The phone's map and list take turns.
class _PhoneSwitch extends StatelessWidget {
  const _PhoneSwitch({required this.list, required this.onChanged});
  final bool list;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return _intercept(
      Material(
        color: colors.surface,
        // Full width: the web pointer interceptor loosens constraints.
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.outlineVariant)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: SegmentedButton<bool>(
            key: const ValueKey('phone-view'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.map_outlined),
                label: Text('地圖'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.view_list_outlined),
                label: Text('清單'),
              ),
            ],
            selected: {list},
            onSelectionChanged: (v) => onChanged(v.single),
            style: SegmentedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
        ),
      ),
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
    required this.onCreate,
  });
  final SpotsController spots;
  final VoidCallback onCreate;
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
                TextButton.icon(
                  onPressed: onCreate,
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: const Text('新增停車點'),
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
    required this.backLabel,
    required this.onBack,
    required this.onSave,
    required this.onHide,
    required this.onPromote,
    required this.onReload,
    required this.onMove,
    required this.moves,
    required this.mapBuilder,
  });
  final SpotsController spots;
  final TextEditingController note;
  final bool compact;
  final String? selectedId;

  /// The phone's way back: to the map or the list it came from.
  final String backLabel;
  final VoidCallback onBack, onSave, onPromote, onReload;
  final ValueChanged<bool> onHide;
  final void Function(double lat, double lng, {bool fromPicker}) onMove;
  final int moves;
  final LocationMapBuilder? mapBuilder;

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
              label: Text(backLabel),
            ),
          )
        : Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const ValueKey('close-form'),
              tooltip: '關閉表單',
              onPressed: onBack,
              icon: const Icon(Icons.close),
            ),
          );
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
            back,
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
    final errors = spots.shownErrors;
    final fields = spots.fields;
    return Material(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              // Another spot starts at the top, not where the last one was.
              key: ValueKey('spot-form-${record.sourceId}-${spots.formSeq}'),
              padding: EdgeInsets.fromLTRB(pad, compact ? 8 : 22, pad, 24),
              children: [
                back,
                Text(
                  record.isNew
                      ? '新增${record.kind.label}'
                      : record.official
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
                    record.isNew && record.name.isEmpty ? '新的停車點' : record.name,
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
                    _LocationSection(
                      spots: spots,
                      onMove: onMove,
                      mapBuilder: mapBuilder,
                    ),
                  for (final f in fields.where((f) => f.group == group))
                    _FieldRow(
                      // Coordinates follow the picker and the county
                      // follows the lookup; their fields must show it.
                      key: ValueKey(
                        '${record.sourceId}-${spots.formSeq}-${f.key}'
                        '${switch (f.key) {
                          'lat' || 'lng' => '-$moves',
                          'city' || 'district' => '-${spots.filled}',
                          _ => '',
                        }}',
                      ),
                      field: f,
                      value: spots.draft[f.key],
                      changed: spots.changed(f.key),
                      error: errors[f.key],
                      onChanged: (v) {
                        spots.set(f.key, v);
                        final lat = spots.draft['lat'];
                        final lng = spots.draft['lng'];
                        if ((f.key == 'lat' || f.key == 'lng') &&
                            lat is num &&
                            lng is num) {
                          onMove(
                            lat.toDouble(),
                            lng.toDouble(),
                            fromPicker: false,
                          );
                        }
                      },
                    ),
                  if (group == SpotGroup.vehicles &&
                      !record.isNew &&
                      !record.official)
                    _VehicleVerification(spots: spots),
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
            creating: record.isNew,
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

/// The stored vehicle access an admin has verified, and a way to verify it
/// as it stands. The app trusts a verified vehicle like official data for
/// 180 days.
class _VehicleVerification extends StatelessWidget {
  const _VehicleVerification({required this.spots});
  final SpotsController spots;

  static const _labels = {'scooter_allowed': '普通機車', 'heavy_allowed': '大型重機'};

  String _state(SpotRecord record, String flag) {
    if (record.values[flag] is! bool) return '未確認，無法核驗';
    final at = record.verifiedAt(flag);
    if (at == null) return '尚未核驗';
    String two(int n) => n.toString().padLeft(2, '0');
    return '已核驗（${at.year}-${two(at.month)}-${two(at.day)}）';
  }

  @override
  Widget build(BuildContext context) {
    final record = spots.record!;
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final canVerify =
        !spots.dirty && !spots.saving && record.verifiableFlags.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          key: const ValueKey('vehicle-verification'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final flag in vehicleFlags)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 104,
                      child: Text('${_labels[flag]}核驗', style: muted),
                    ),
                    Expanded(child: Text(_state(record, flag))),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('verify-vehicles'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: canVerify
                  ? () async {
                      final messenger = ScaffoldMessenger.of(context);
                      if (await spots.verifyVehicles()) {
                        messenger.showSnackBar(
                          const SnackBar(content: Text('已核驗目前車種')),
                        );
                      }
                    }
                  : null,
              icon: const Icon(Icons.verified_outlined),
              label: const Text('核驗目前車種'),
            ),
            const SizedBox(height: 4),
            Text(
              spots.dirty
                  ? '有未儲存的修改，請先儲存或捨棄後再核驗。'
                  : '實地或依公告確認上方車種設定正確後按下；儲存或採納車種欄位也會自動核驗。'
                        'App 會在 180 天內把核驗過的車種當成可信資料判定可停或不可停。',
              style: muted.copyWith(fontSize: 13),
            ),
          ],
        ),
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
    required this.creating,
    required this.official,
    required this.hidden,
    required this.dirty,
    required this.busy,
    required this.onSave,
    required this.onDiscard,
    required this.onHide,
    required this.onPromote,
  });
  final bool compact, creating, official, hidden, dirty, busy;
  final VoidCallback onSave, onDiscard, onPromote;
  final ValueChanged<bool> onHide;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final save = FilledButton(
      onPressed: busy || !dirty ? null : onSave,
      child: Text(creating ? '建立停車點' : '儲存並關閉'),
    );
    final others = <Widget>[
      if (dirty && !creating)
        OutlinedButton(
          onPressed: busy ? null : onDiscard,
          child: const Text('放棄修改'),
        ),
      if (!official && !hidden && !creating)
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
                      children: [...others, if (!creating) hide],
                    ),
                  ],
                )
              : Row(
                  children: [
                    save,
                    for (final b in others) ...[const SizedBox(width: 10), b],
                    const Spacer(),
                    if (!creating) hide,
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

/// The picker with what the admin should know about the position.
class _LocationSection extends StatelessWidget {
  const _LocationSection({
    required this.spots,
    required this.onMove,
    required this.mapBuilder,
  });
  final SpotsController spots;
  final void Function(double lat, double lng, {bool fromPicker}) onMove;
  final LocationMapBuilder? mapBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final record = spots.record!;
    final lat = spots.draft['lat'], lng = spots.draft['lng'];
    final origin = record.isNew ? null : record.values;
    final notes = spots.notes;
    final muted = TextStyle(fontSize: 13, color: colors.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (lat is num && lng is num)
              LocationPicker(
                lat: lat.toDouble(),
                lng: lng.toDouble(),
                originLat: (origin?['lat'] as num?)?.toDouble(),
                originLng: (origin?['lng'] as num?)?.toDouble(),
                nudgeButtons: true,
                mapBuilder: mapBuilder,
                onChanged: (a, b) => onMove(a, b),
              )
            else
              const AdminNotice('座標格式不正確，修正後地圖才會顯示。', error: true),
            const SizedBox(height: 4),
            Text('拖曳標記或點地圖選位置；縣市與行政區會依位置自動帶入。', style: muted),
            if (spots.locating) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
            if (spots.locateError != null) ...[
              const SizedBox(height: 8),
              AdminNotice(spots.locateError!, error: true),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: spots.locating ? null : spots.locate,
                    child: const Text('重新查詢'),
                  ),
                  // The service may be down; the admin can still vouch for
                  // the county and district typed below.
                  OutlinedButton(
                    onPressed: () {
                      if (!spots.confirmManualTown()) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('請先在下方填寫縣市。')),
                        );
                      }
                    },
                    child: const Text('使用手動填寫的縣市與行政區'),
                  ),
                ],
              ),
            ],
            if (notes.cityChanged) ...[
              const SizedBox(height: 8),
              AdminNotice(
                '新位置在${spots.draft['city']}，和原本的${origin?['city']}不同，適用的停車規則會改變。',
              ),
            ],
            if (notes.far) ...[
              const SizedBox(height: 8),
              AdminNotice(
                '距原位置約 ${notes.moved!.round()} m，超過 150 m；儲存前會再確認是否仍是同一個點位。',
              ),
            ],
            if (notes.duplicates.isNotEmpty) ...[
              const SizedBox(height: 8),
              AdminNotice(
                '15 m 內已有同類型的停車點，可能重複：'
                '${notes.duplicates.map((d) => d.name).join('、')}',
                error: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

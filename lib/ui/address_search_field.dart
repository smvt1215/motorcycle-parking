import '../core/address_search.dart';
import 'adaptive/adaptive.dart';

/// Opens [AddressSearchField] in a sheet (phones) or a dialog (wide
/// screens) and returns the result picked; `LocationPicker.onSearch` uses it.
Future<AddressCandidate?> showAddressSearch(
  BuildContext context, {
  required AddressSearcher search,
  double? lat,
  double? lng,
}) {
  Widget body(BuildContext context) =>
      _AddressSearchPanel(search: search, lat: lat, lng: lng);
  if (MediaQuery.sizeOf(context).width >= 600) {
    return showDialog<AddressCandidate>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
          child: body(context),
        ),
      ),
    );
  }
  return showAdaptiveSheet<AddressCandidate>(context, body);
}

class _AddressSearchPanel extends StatelessWidget {
  const _AddressSearchPanel({required this.search, this.lat, this.lng});
  final AddressSearcher search;
  final double? lat, lng;

  @override
  Widget build(BuildContext context) => Padding(
    // The keyboard must not cover the field or the results.
    padding: EdgeInsets.fromLTRB(
      20,
      12,
      20,
      16 + MediaQuery.viewInsetsOf(context).bottom,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '搜尋位置',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: '關閉搜尋',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AddressSearchField(
            search: search,
            lat: lat,
            lng: lng,
            autofocus: true,
            onPicked: (c) => Navigator.pop(context, c),
          ),
        ],
      ),
    ),
  );
}

/// Searches a house number, road or intersection; shared by the admin site
/// and the app (docs/ADMIN_WEB.md「位置選擇」).
/// Each search is a request against a daily limit, so it runs on 「搜尋地址」
/// or the keyboard's search key, never while typing.
class AddressSearchField extends StatefulWidget {
  const AddressSearchField({
    super.key,
    required this.search,
    required this.onPicked,
    this.lat,
    this.lng,
    this.autofocus = false,
  });

  final AddressSearcher search;

  /// Where the map is; results near it come first.
  final double? lat, lng;

  /// The caller moves the marker and fills [AddressCandidate.field].
  final void Function(AddressCandidate) onPicked;
  final bool autofocus;

  @override
  State<AddressSearchField> createState() => _AddressSearchFieldState();
}

class _AddressSearchFieldState extends State<AddressSearchField> {
  final _query = TextEditingController();
  List<AddressCandidate>? _results;
  String? _searched;
  AddressSearchException? _error;
  bool _busy = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _query.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _canSearch => !_busy && _query.text.trim().length >= 2;

  Future<void> _run() async {
    final text = _query.text.trim();
    if (text.length < 2 || _busy) return;
    final seq = ++_seq;
    setState(() {
      _busy = true;
      _error = null;
      _results = null;
    });
    try {
      final found = await widget.search(text, lat: widget.lat, lng: widget.lng);
      if (!mounted || seq != _seq) return;
      setState(() {
        _results = found;
        _searched = text;
      });
    } on AddressSearchException catch (e) {
      if (mounted && seq == _seq) setState(() => _error = e);
    } catch (_) {
      if (mounted && seq == _seq) {
        setState(() => _error = const AddressSearchException('unavailable'));
      }
    } finally {
      if (mounted && seq == _seq) setState(() => _busy = false);
    }
  }

  void _pick(AddressCandidate c) {
    setState(() => _results = null);
    widget.onPicked(c);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final muted = TextStyle(color: colors.onSurfaceVariant);
    final results = _results;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final field = TextField(
              key: const ValueKey('address-search'),
              controller: _query,
              autofocus: widget.autofocus,
              textInputAction: TextInputAction.search,
              maxLength: 100,
              onSubmitted: (_) => _run(),
              decoration: const InputDecoration(
                labelText: '搜尋門牌、路段或路口',
                hintText: '例如 中山北路二段與南京東路',
                prefixIcon: Icon(Icons.search),
                counterText: '',
              ),
            );
            final button = OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _canSearch ? _run : null,
              child: const Text('搜尋地址'),
            );
            // Phones and large text put the button under the field, so the
            // field keeps room for its label.
            final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
            if (box.maxWidth < 360 * scale) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [field, const SizedBox(height: 8), button],
              );
            }
            return Row(
              children: [
                Expanded(child: field),
                const SizedBox(width: 8),
                button,
              ],
            );
          },
        ),
        if (_busy) ...[
          const SizedBox(height: 8),
          const LinearProgressIndicator(semanticsLabel: '正在搜尋地址'),
        ],
        if (_error case final error?) ...[
          const SizedBox(height: 8),
          _Line(
            icon: Icons.error_outline,
            color: colors.error,
            text: error.message,
            action: error.retryable
                ? TextButton(onPressed: _run, child: const Text('重新搜尋'))
                : null,
          ),
        ],
        if (results != null && results.isEmpty) ...[
          const SizedBox(height: 8),
          _Line(
            icon: Icons.search_off,
            color: colors.onSurfaceVariant,
            text:
                '找不到「$_searched」。門牌請寫到「號」；路口請寫兩條路名，'
                '例如「中山北路二段與南京東路一段」。也可以直接拖曳標記選位置。',
          ),
        ],
        if (results != null && results.isNotEmpty) ...[
          const SizedBox(height: 4),
          Semantics(
            container: true,
            label: '地址搜尋結果 ${results.length} 筆',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, c) in results.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _ResultRow(candidate: c, onTap: () => _pick(c)),
                ],
              ],
            ),
          ),
          Text('點一筆結果，標記會移到該位置。', style: muted),
        ],
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.candidate, required this.onTap});
  final AddressCandidate candidate;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final c = candidate;
    final what = switch (c.kind) {
      AddressKind.address when c.precision != AddressPrecision.exact =>
        '門牌，推估位置',
      AddressKind.address => '門牌',
      AddressKind.road => '路段，只到中心點',
      AddressKind.intersection => '路口，只到交會點',
      AddressKind.area => '區域，只到中心點',
    };
    final detail = c.place == null ? what : '${c.place}的$what';
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              Icon(switch (c.kind) {
                AddressKind.address => Icons.door_front_door_outlined,
                AddressKind.road => Icons.add_road,
                AddressKind.intersection => Icons.signpost_outlined,
                AddressKind.area => Icons.place_outlined,
              }, color: colors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.label),
                    Text(
                      detail,
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
    );
  }
}

/// A one-line status under the field: what happened and what to do.
class _Line extends StatelessWidget {
  const _Line({
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });
  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
        ?action,
      ],
    ),
  );
}

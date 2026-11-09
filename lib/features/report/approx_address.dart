import 'dart:async';

import '../../core/address_search.dart';
import '../../core/geo.dart';
import '../../ui/adaptive/adaptive.dart';

/// What the door row under the picker says (N1b, S6).
enum ApproxStatus {
  dragging,
  loading,
  found,
  roadOnly,
  none,
  failed,
  dailyLimit,
  serviceLimit,
  signedOut,
}

/// The approximate door at the marker, for one form (#407). It is only shown:
/// nothing here reaches a report, and the answer lives as long as the form,
/// never shared between riders (Service Specific Terms 6.3.2).
class ApproxAddressController extends ChangeNotifier {
  ApproxAddressController({
    required this.lookup,
    required this.auth,
    required this.signedIn,
    required this.lat,
    required this.lng,
  }) : _wasSignedIn = signedIn() {
    auth.addListener(_authChanged);
    _settle(delay: Duration.zero);
  }

  final Future<ApproxAddress?> Function(double lat, double lng) lookup;

  /// Notifies when [signedIn] may have changed.
  final Listenable auth;
  final bool Function() signedIn;

  /// How long the marker must rest before a lookup, as for the county.
  static const pause = Duration(milliseconds: 600);

  /// Closer than this to the last answer, the door stays as it is.
  static const sameDoorMeters = 10.0;

  /// Where the marker is.
  double lat, lng;
  bool _wasSignedIn, _dragging = false, _closed = false;
  ({double lat, double lng, ApproxAddress? address})? _answer;

  /// Set once the day's quota is gone; further moves cannot be answered.
  ApproxStatus? _limit;
  ApproxStatus _status = ApproxStatus.loading;
  Timer? _timer;
  int _round = 0;

  ApproxStatus get status => _status;

  /// The door behind [ApproxStatus.found] and [ApproxStatus.roadOnly].
  ApproxAddress? get address => _answer?.address;

  void _show(ApproxStatus next) {
    _status = next;
    notifyListeners();
  }

  /// Drops a timer or a request still in flight for an earlier position.
  void _cancel() {
    _timer?.cancel();
    _round++;
  }

  ApproxStatus _statusOf(ApproxAddress? address) => switch (address) {
    null => ApproxStatus.none,
    ApproxAddress(number: null) => ApproxStatus.roadOnly,
    _ => ApproxStatus.found,
  };

  void _settle({Duration delay = pause}) {
    _cancel();
    if (_limit case final limit?) return _show(limit);
    if (!signedIn()) return _show(ApproxStatus.signedOut);
    if (_answer case final a?
        when distanceMeters(a.lat, a.lng, lat, lng) < sameDoorMeters) {
      return _show(_statusOf(a.address));
    }
    _show(ApproxStatus.loading);
    final round = _round;
    _timer = Timer(delay, () => _ask(round));
  }

  Future<void> _ask(int round) async {
    final (askedLat, askedLng) = (lat, lng);
    bool stale() => _closed || round != _round;
    void answered(ApproxAddress? address) {
      _answer = (lat: askedLat, lng: askedLng, address: address);
      _show(_statusOf(address));
    }

    try {
      final address = await lookup(askedLat, askedLng);
      if (!stale()) answered(address);
    } on AddressSearchException catch (e) {
      if (stale()) return;
      switch (e.code) {
        case 'daily_limit':
          _show(_limit = ApproxStatus.dailyLimit);
        case 'service_limit':
          _show(_limit = ApproxStatus.serviceLimit);
        case 'sign_in_required':
          _show(ApproxStatus.signedOut);
        // Outside the bounds the server takes: nothing there to find.
        case 'invalid_query':
          answered(null);
        default:
          _show(ApproxStatus.failed);
      }
    } catch (_) {
      if (!stale()) _show(ApproxStatus.failed);
    }
  }

  /// The marker was lifted or put down.
  void dragging(bool on) {
    _dragging = on;
    if (!on) return _settle();
    _cancel();
    // Nothing would be looked up on release, so nothing to promise.
    if (_limit != null || !signedIn()) return;
    _show(ApproxStatus.dragging);
  }

  /// The marker came to rest at a new point.
  void moved(double newLat, double newLng) {
    lat = newLat;
    lng = newLng;
    if (!_dragging) _settle();
  }

  void _authChanged() {
    final now = signedIn();
    if (now == _wasSignedIn) return;
    _wasSignedIn = now;
    // Another account has its own quota.
    _limit = null;
    if (!_dragging) _settle(delay: Duration.zero);
  }

  @override
  void dispose() {
    _closed = true;
    _timer?.cancel();
    auth.removeListener(_authChanged);
    super.dispose();
  }
}

/// The door row between the map and the county (N1b, S6). The caller leaves
/// it out when [ApproxAddressController] does not apply.
class ApproxAddressRow extends StatelessWidget {
  const ApproxAddressRow({super.key, required this.controller});
  final ApproxAddressController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final door = controller.address;
    final (icon, title, note, answer) = switch (controller.status) {
      ApproxStatus.dragging => (Icons.open_with, '放開標記後查約略門牌', null, false),
      ApproxStatus.loading => (Icons.autorenew, '正在查約略門牌…', null, false),
      ApproxStatus.found => (
        Icons.pin_drop,
        '約 ${door?.road} ${door?.number} 號附近',
        '由地圖位置推估，只給你對照，不會存進資料。',
        true,
      ),
      ApproxStatus.roadOnly => (
        Icons.add_road,
        '約在 ${door?.road} 上',
        '查不到門牌號碼，只查到路名。這是推估，不會存進資料。',
        true,
      ),
      ApproxStatus.none => (
        Icons.help_outline,
        '這個位置查不到門牌',
        '拖曳標記對準停車格就好，不影響送出。',
        false,
      ),
      ApproxStatus.failed => (
        Icons.cloud_off,
        '暫時查不到門牌',
        '移動標記會再查一次，不影響送出。',
        false,
      ),
      ApproxStatus.dailyLimit => (
        Icons.hourglass_empty,
        '今天的地址查詢次數已用完，明天會恢復',
        '和「搜尋地址」共用次數。不顯示門牌，不影響送出。',
        false,
      ),
      ApproxStatus.serviceLimit => (
        Icons.hourglass_empty,
        '地址查詢今天的總次數已用完，明天會恢復',
        '不顯示門牌，不影響送出。',
        false,
      ),
      ApproxStatus.signedOut => (
        Icons.login,
        '登入 Google 或 Apple 帳號後，才會顯示約略門牌',
        '也可以直接拖曳標記選位置。',
        false,
      ),
    };
    return Semantics(
      key: const ValueKey('approx-address'),
      container: true,
      liveRegion: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    icon,
                    size: 20,
                    color: answer ? colors.primary : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.4,
                          fontWeight: answer
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: answer
                              ? colors.onSurface
                              : colors.onSurfaceVariant,
                        ),
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          note,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

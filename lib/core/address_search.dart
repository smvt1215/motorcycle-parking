import 'package:supabase_flutter/supabase_flutter.dart';

/// What a search result points at (docs/ADMIN_WEB.md「位置選擇」).
enum AddressKind {
  /// A house number; its text belongs in the spot's address.
  address('門牌'),

  /// A road or section; the point is only its centre.
  road('路段'),

  /// Where two roads meet; the point is only the crossing.
  intersection('路口'),

  /// A district, landmark or anything else; only moves the map.
  area('區域');

  const AddressKind(this.label);
  final String label;
}

/// How close the point is to what was asked for.
enum AddressPrecision { exact, interpolated, center, approximate }

class AddressCandidate {
  const AddressCandidate({
    required this.kind,
    required this.label,
    required this.lat,
    required this.lng,
    this.place,
    this.precision = AddressPrecision.exact,
  });

  final AddressKind kind;
  final String label;

  /// County and district of a road or intersection, whose [label] is only
  /// the road names (the way `road_segment` is written).
  final String? place;
  final double lat, lng;
  final AddressPrecision precision;

  /// The spot field the label fills: `address` for a house number,
  /// `road_segment` for a road or intersection, none for an area.
  String? get field => switch (kind) {
    AddressKind.address => 'address',
    AddressKind.road || AddressKind.intersection => 'road_segment',
    AddressKind.area => null,
  };

  /// What the rider must still do after picking this result; null when the
  /// point is a door found as asked.
  String? get reminder => switch (kind) {
    AddressKind.road => '路段只定位到中心點，請把標記拖到實際停車位置。',
    AddressKind.intersection => '路口只定位到兩條路的交會點，請把標記拖到實際停車位置。',
    AddressKind.area => '只定位到這個區域的中心，請把標記拖到實際停車位置。',
    AddressKind.address when precision != AddressPrecision.exact =>
      '這個門牌是推估位置，請對照地圖確認標記在門口。',
    AddressKind.address => null,
  };

  static AddressCandidate? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = AddressKind.values.asNameMap()[json['kind']];
    final label = json['label'], lat = json['lat'], lng = json['lng'];
    if (kind == null || label is! String || lat is! num || lng is! num) {
      return null;
    }
    return AddressCandidate(
      kind: kind,
      label: label,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      place: json['place'] is String ? json['place'] as String : null,
      precision:
          AddressPrecision.values.asNameMap()[json['precision']] ??
          AddressPrecision.approximate,
    );
  }
}

/// Why a search found nothing to show; [message] says what to do instead.
class AddressSearchException implements Exception {
  const AddressSearchException(this.code);

  /// The `geocode` Edge Function's error code, or `network`.
  final String code;

  /// Retrying the same search may work.
  bool get retryable => code == 'network' || code == 'unavailable';

  String get message => switch (code) {
    'sign_in_required' => '登入 Google 或 Apple 帳號後才能搜尋地址；也可以直接拖曳標記選位置。',
    'daily_limit' => '今天的地址搜尋次數已用完，明天會恢復。現在可以直接拖曳標記或點地圖選位置。',
    'service_limit' => '地址搜尋今天的總次數已用完，明天會恢復。現在可以直接拖曳標記或點地圖選位置。',
    'not_configured' => '地址搜尋尚未開放，請直接拖曳標記或點地圖選位置。',
    'invalid_query' => '請輸入 2 到 100 個字的門牌、路名或路口。',
    'network' => '連不上地址搜尋，請檢查網路後重試；也可以直接拖曳標記。',
    _ => '地址搜尋暫時無法使用，請稍後重試；也可以直接拖曳標記。',
  };

  @override
  String toString() => 'AddressSearchException($code)';
}

/// Searches near a point; the map passes where it is looking.
typedef AddressSearcher = Future<List<AddressCandidate>> Function(
  String query, {
  double? lat,
  double? lng,
});

/// The `geocode` Edge Function, shared by the app and the admin site. The
/// provider key stays in the function; clients only send the user's token.
Future<List<AddressCandidate>> geocodeSearch(
  FunctionsClient functions,
  String query, {
  double? lat,
  double? lng,
}) async {
  final FunctionResponse res;
  try {
    res = await functions
        .invoke(
          'geocode',
          body: {
            'query': query,
            if (lat != null && lng != null) 'near': {'lat': lat, 'lng': lng},
          },
        )
        .timeout(const Duration(seconds: 15));
  } on FunctionException catch (e) {
    final details = e.details;
    final code = details is Map ? details['error'] : null;
    throw AddressSearchException(
      code is String ? code : (e.status == 0 ? 'network' : 'unavailable'),
    );
  } catch (_) {
    throw const AddressSearchException('network');
  }
  return parseCandidates(res.data);
}

List<AddressCandidate> parseCandidates(Object? data) {
  final list = data is Map ? data['candidates'] : null;
  if (list is! List) throw const AddressSearchException('unavailable');
  return [for (final item in list) ?AddressCandidate.fromJson(item)];
}

import 'dart:convert';

import 'package:http/http.dart' as http;

/// The county or city and the district a point falls in.
class Town {
  const Town(this.city, this.district);
  final String city, district;

  @override
  bool operator ==(Object other) =>
      other is Town && other.city == city && other.district == district;
  @override
  int get hashCode => Object.hash(city, district);
  @override
  String toString() => '$city$district';
}

/// National Land Surveying and Mapping Center reverse lookup, the same
/// service `tool/import_mymaps.py` uses. Free, keyless and CORS-enabled.
/// Returns null at sea or outside Taiwan.
Future<Town?> lookupTown(double lat, double lng, {http.Client? client}) async {
  final uri = Uri.parse(
    'https://api.nlsc.gov.tw/other/TownVillagePointQuery/$lng/$lat/4326',
  );
  final response = await (client?.get(uri) ?? http.get(uri)).timeout(
    const Duration(seconds: 10),
  );
  if (response.statusCode != 200) {
    throw StateError('Town lookup failed: ${response.statusCode}');
  }
  return parseTown(utf8.decode(response.bodyBytes));
}

String? _tag(String xml, String name) =>
    RegExp('<$name>([^<]*)</$name>').firstMatch(xml)?.group(1)?.trim();

Town? parseTown(String xml) {
  final city = _tag(xml, 'ctyName');
  if (city == null || city.isEmpty) return null;
  return Town(city, _tag(xml, 'townName') ?? '');
}

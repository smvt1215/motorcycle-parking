import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Google Maps has an app-only scheme on iOS. Trying it directly lets the
/// actual launch decide availability, without a canOpenURL allowlist check.
List<Uri> navigationTargets(
  double lat,
  double lng, {
  required TargetPlatform platform,
  bool web = false,
}) {
  if (!web && platform == TargetPlatform.iOS) {
    return [
      Uri.parse('comgooglemaps://?daddr=$lat,$lng&directionsmode=driving'),
      Uri.https('maps.apple.com', '/', {'daddr': '$lat,$lng', 'dirflg': 'd'}),
    ];
  }
  return [
    Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'destination': '$lat,$lng',
      'travelmode': 'driving',
    }),
  ];
}

Future<void> launchNavigation(double lat, double lng) async {
  for (final uri in navigationTargets(
    lat,
    lng,
    platform: defaultTargetPlatform,
    web: kIsWeb,
  )) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } on PlatformException {
      // A missing or unavailable handler may throw instead of returning false.
      // The next target is still a usable route into Maps on iOS.
    }
  }
  throw StateError('無法開啟導航');
}

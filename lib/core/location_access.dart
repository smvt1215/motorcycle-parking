import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Why the device location cannot be read, with the copy and settings page
/// that let the user fix it.
enum LocationIssue {
  serviceOff(
    title: '定位服務未開啟',
    message: '開啟裝置的定位服務後，地圖才能顯示你附近的停車點、記錄停車位置，回報時也才能把標記移到你所在的地方。',
    action: '開啟定位設定',
    short: '請開啟裝置定位服務',
  ),
  denied(
    title: '尚未允許使用位置',
    message: '請到設定允許「機車停車指南」使用你的位置，地圖才能顯示你附近的停車點、記錄停車位置，回報時也才能把標記移到你所在的地方。',
    action: '前往設定',
    short: '定位未授權，請在設定中開啟定位權限',
  );

  const LocationIssue({
    required this.title,
    required this.message,
    required this.action,
    required this.short,
  });
  final String title, message, action, short;

  /// Browsers have no settings page an app can open.
  bool get canOpenSettings => !kIsWeb;

  Future<bool> openSettings() => this == serviceOff
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();
}

/// Thrown when location is off or not permitted; actions show a settings
/// prompt for it instead of a plain message.
class LocationAccessError extends StateError {
  LocationAccessError(this.issue) : super(issue.short);
  final LocationIssue issue;
}

/// Thrown instead of asking the system for location when the rider has not
/// been told why yet (#458, Android after 先不要 on the launch explanation).
/// The action shows the explanation; on 繼續 it calls [accept] and runs
/// again, which then asks the system. On 先不要 nothing else happens.
class LocationRationaleNeeded implements Exception {
  LocationRationaleNeeded(this._accept);
  final void Function() _accept;
  void accept() => _accept();
}

/// The device's location calls, apart from the store so tests can stand in
/// for the platform.
///
/// What [checkPermission] reports before the system has ever asked (#458):
/// - iOS: `notDetermined` (and `restricted`) read as
///   [LocationPermission.denied]; a refusal reads as
///   [LocationPermission.deniedForever].
/// - Android: [LocationPermission.denied] both before the first ask and
///   after a refusal, so the store keeps its own record of having asked.
class LocationDevice {
  const LocationDevice();

  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();
  Future<Position?> lastKnownPosition() => Geolocator.getLastKnownPosition();
  Future<Position> currentPosition() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      timeLimit: Duration(seconds: 20),
    ),
  );
}

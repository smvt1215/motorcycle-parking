import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Why the device location cannot be read, with the copy and settings page
/// that let the user fix it.
enum LocationIssue {
  serviceOff(
    title: '定位服務未開啟',
    message: '開啟裝置的定位服務後，地圖才能顯示你附近的停車點，也才能記錄停車位置。',
    action: '開啟定位設定',
    short: '請開啟裝置定位服務',
  ),
  denied(
    title: '尚未允許使用位置',
    message: '請到設定允許「機車停車指南」使用你的位置，地圖才能顯示你附近的停車點，也才能記錄停車位置。',
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

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class ParkingNotifications {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  Future<void> _initialize() async {
    if (!_ready) {
      tzdata.initializeTimeZones();
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
    }
  }

  Future<bool> schedule(DateTime at) async {
    if (kIsWeb) return false;
    await _initialize();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (android != null &&
        await android.requestNotificationsPermission() == false) {
      return false;
    }
    if (ios != null &&
        await ios.requestPermissions(alert: true, sound: true) == false) {
      return false;
    }
    await _plugin.zonedSchedule(
      1,
      '停車計時提醒',
      '記得確認停車費與停車時間',
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'parking',
          '停車提醒',
          importance: Importance.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
    return true;
  }

  Future<void> cancel() async {
    if (kIsWeb) return;
    await _initialize();
    await _plugin.cancel(1);
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// ローカル通知の初期化・スケジュールを担うサービス
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static const _channelId = 'daily_reminder';
  static const _channelName = '毎日のリマインダー';
  static const _channelDescription = '今日の一枚を記録するリマインドです';

  /// 事前スケジュールする日数（アプリ起動時に必ず再スケジュールされる前提）
  static const int scheduleDays = 14;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    tz_data.initializeTimeZones();
    final localName = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(localName));

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );

    _initialized = true;
  }

  /// 通知許可をリクエスト（iOS は明示的、Android 13+ は POST_NOTIFICATIONS）
  Future<bool> requestPermissions() async {
    final iosImpl = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    final iosGranted = await iosImpl?.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final androidGranted = await androidImpl?.requestNotificationsPermission();

    return (iosGranted ?? true) && (androidGranted ?? true);
  }

  /// すべての予約通知をキャンセル
  Future<void> cancelAll() => _plugin.cancelAll();

  /// 指定された時刻で今後 [scheduleDays] 日分の通知を予約する。
  /// [skipDates] に含まれる日（YYYY-MM-DD 形式）はスキップ。
  Future<void> scheduleDailyReminder({
    required TimeOfDay time,
    required Set<String> skipDates,
  }) async {
    await cancelAll();

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDescription,
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final now = tz.TZDateTime.now(tz.local);
    for (var offset = 0; offset < scheduleDays; offset++) {
      final target = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        time.hour,
        time.minute,
      ).add(Duration(days: offset));

      if (target.isBefore(now)) continue;

      final dateKey = target.toIso8601String().substring(0, 10);
      if (skipDates.contains(dateKey)) continue;

      await _plugin.zonedSchedule(
        offset,
        '今日の一枚を記録しましょう',
        'カメラを開いて、今日の一瞬を残そう',
        target,
        notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }
}

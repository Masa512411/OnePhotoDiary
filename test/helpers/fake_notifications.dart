import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:one_photo_diary/services/notification_service.dart';
import 'package:timezone/timezone.dart' as tz;

/// テスト用のFlutterLocalNotificationsPlugin（予約内容を記録する）
class FakeNotificationsPlugin implements FlutterLocalNotificationsPlugin {
  /// 予約中の通知（id → 予約日時）
  final scheduled = <int, tz.TZDateTime>{};
  final matchComponents = <int, DateTimeComponents?>{};
  int cancelAllCalls = 0;

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    scheduled.clear();
    matchComponents.clear();
  }

  @override
  Future<void> zonedSchedule(
    int id,
    String? title,
    String? body,
    tz.TZDateTime scheduledDate,
    NotificationDetails notificationDetails, {
    required UILocalNotificationDateInterpretation
    uiLocalNotificationDateInterpretation,
    bool androidAllowWhileIdle = false,
    AndroidScheduleMode? androidScheduleMode,
    String? payload,
    DateTimeComponents? matchDateTimeComponents,
  }) async {
    scheduled[id] = scheduledDate;
    matchComponents[id] = matchDateTimeComponents;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// テスト用のNotificationService（呼び出しを記録する）
class FakeNotificationService implements NotificationService {
  final scheduleCalls = <({TimeOfDay time, Set<String> skipDates})>[];
  int cancelAllCalls = 0;
  bool permissionGranted;

  /// 設定すると、完了するまでscheduleDailyReminderを終わらせない
  Completer<void>? pendingSchedule;

  /// 設定するとscheduleDailyReminderでこの例外を投げる
  Object? scheduleError;

  /// 実行中のscheduleDailyReminderの数の最大値（直列化の確認用）
  int maxConcurrent = 0;
  int _running = 0;

  FakeNotificationService({this.permissionGranted = true});

  @override
  Future<bool> requestPermissions() async => permissionGranted;

  @override
  Future<void> cancelAll() async => cancelAllCalls++;

  @override
  Future<void> scheduleDailyReminder({
    required TimeOfDay time,
    required Set<String> skipDates,
  }) async {
    _running++;
    if (_running > maxConcurrent) maxConcurrent = _running;
    scheduleCalls.add((time: time, skipDates: skipDates));
    try {
      if (pendingSchedule != null) await pendingSchedule!.future;
      if (scheduleError != null) throw scheduleError!;
    } finally {
      _running--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

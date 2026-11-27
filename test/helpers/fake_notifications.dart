import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:one_photo_diary/services/notification_service.dart';
import 'package:timezone/timezone.dart' as tz;

/// テスト用のFlutterLocalNotificationsPlugin（予約・表示中の通知を記録する）
class FakeNotificationsPlugin implements FlutterLocalNotificationsPlugin {
  /// 予約中の通知（id → 予約日時）
  final scheduled = <int, tz.TZDateTime>{};
  final payloads = <int, String?>{};
  final matchComponents = <int, DateTimeComponents?>{};

  /// 通知センターに表示中の通知のID
  final displayed = <int>{};

  final cancelledIds = <int>[];
  final scheduledIds = <int>[];
  int cancelAllCalls = 0;

  /// 予約中の通知が届いたことにする（予約一覧から消え、表示中になる）
  void deliver(int id) {
    scheduled.remove(id);
    payloads.remove(id);
    displayed.add(id);
  }

  @override
  Future<List<PendingNotificationRequest>>
  pendingNotificationRequests() async => [
    for (final id in scheduled.keys)
      PendingNotificationRequest(id, null, null, payloads[id]),
  ];

  @override
  Future<void> cancel(int id, {String? tag}) async {
    cancelledIds.add(id);
    scheduled.remove(id);
    payloads.remove(id);
    displayed.remove(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
    scheduled.clear();
    payloads.clear();
    displayed.clear();
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
    scheduledIds.add(id);
    scheduled[id] = scheduledDate;
    payloads[id] = payload;
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

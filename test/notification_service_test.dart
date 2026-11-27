import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/services/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'helpers/fake_notifications.dart';

void main() {
  late FakeNotificationsPlugin plugin;
  late tz.Location tokyo;

  setUpAll(() {
    tz_data.initializeTimeZones();
    tokyo = tz.getLocation('Asia/Tokyo');
  });

  setUp(() => plugin = FakeNotificationsPlugin());

  NotificationService createService(tz.TZDateTime now) =>
      NotificationService(plugin: plugin, clock: () => now);

  String dateKey(tz.TZDateTime d) => d.toIso8601String().substring(0, 10);

  group('NotificationService.scheduleDailyReminder', () {
    test('今日の時刻前なら今日から14日分を予約する', () async {
      final service = createService(tz.TZDateTime(tokyo, 2026, 11, 28, 20));

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 21, minute: 0),
        skipDates: {},
      );

      expect(plugin.scheduled, hasLength(NotificationService.scheduleDays));
      expect(plugin.scheduled[0], tz.TZDateTime(tokyo, 2026, 11, 28, 21));
      expect(plugin.scheduled[13], tz.TZDateTime(tokyo, 2026, 12, 11, 21));
      // 記録済みの日を飛ばすため、繰り返し通知ではなく単発通知で予約する
      expect(plugin.matchComponents.values, everyElement(isNull));
    });

    test('今日の時刻を過ぎていれば明日から予約する', () async {
      final service = createService(tz.TZDateTime(tokyo, 2026, 11, 28, 22));

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 21, minute: 0),
        skipDates: {},
      );

      expect(plugin.scheduled, hasLength(NotificationService.scheduleDays - 1));
      expect(plugin.scheduled.containsKey(0), isFalse);
      expect(plugin.scheduled[1], tz.TZDateTime(tokyo, 2026, 11, 29, 21));
    });

    test('記録済みの日はスキップする', () async {
      final service = createService(tz.TZDateTime(tokyo, 2026, 11, 28, 8));

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 21, minute: 0),
        skipDates: {'2026-11-28', '2026-11-30'},
      );

      final dates = plugin.scheduled.values.map(dateKey).toSet();
      expect(dates, isNot(contains('2026-11-28')));
      expect(dates, isNot(contains('2026-11-30')));
      expect(dates, contains('2026-11-29'));
      expect(plugin.scheduled, hasLength(NotificationService.scheduleDays - 2));
    });

    test('再スケジュール時は既存の予約を取り消してから入れ直す', () async {
      final service = createService(tz.TZDateTime(tokyo, 2026, 11, 28, 8));
      const time = TimeOfDay(hour: 21, minute: 0);

      await service.scheduleDailyReminder(time: time, skipDates: {});
      await service.scheduleDailyReminder(
        time: time,
        skipDates: {'2026-11-28'},
      );

      expect(plugin.cancelAllCalls, 2);
      expect(plugin.scheduled.containsKey(0), isFalse);
      expect(plugin.scheduled, hasLength(NotificationService.scheduleDays - 1));
    });

    test('夏時間の切り替わりをまたいでも同じ時刻に予約する', () async {
      final newYork = tz.getLocation('America/New_York');
      // 2026-03-08 に夏時間が始まる
      final service = createService(tz.TZDateTime(newYork, 2026, 3, 1, 8));

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 21, minute: 0),
        skipDates: {},
      );

      for (final target in plugin.scheduled.values) {
        expect(target.hour, 21, reason: '$target');
        expect(target.minute, 0, reason: '$target');
      }
    });
  });
}

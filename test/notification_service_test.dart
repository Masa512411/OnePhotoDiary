import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/services/notification_service.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import 'helpers/fake_notifications.dart';

void main() {
  late FakeNotificationsPlugin plugin;
  late tz.Location tokyo;
  late tz.TZDateTime now;

  const nine = TimeOfDay(hour: 21, minute: 0);
  const days = NotificationService.scheduleDays;

  setUpAll(() {
    tz_data.initializeTimeZones();
    tokyo = tz.getLocation('Asia/Tokyo');
  });

  setUp(() {
    plugin = FakeNotificationsPlugin();
    now = tz.TZDateTime(tokyo, 2026, 11, 28, 20);
  });

  // clock は now を参照するので、テスト中に時刻を進められる
  NotificationService createService() =>
      NotificationService(plugin: plugin, clock: () => now);

  int id(int y, int m, int d) =>
      NotificationService.idForDate(DateTime(y, m, d));
  String dateKey(tz.TZDateTime d) => d.toIso8601String().substring(0, 10);

  group('NotificationService.scheduleDailyReminder', () {
    test('iOSの予約上限64件以内に収まる', () {
      expect(days, lessThanOrEqualTo(64));
    });

    test('今日の時刻前なら今日から日付ごとのIDで予約する', () async {
      await createService().scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.scheduled, hasLength(days));
      expect(
        plugin.scheduled[id(2026, 11, 28)],
        tz.TZDateTime(tokyo, 2026, 11, 28, 21),
      );
      expect(
        plugin.scheduled[id(2027, 1, 26)],
        tz.TZDateTime(tokyo, 2027, 1, 26, 21),
      );
      // 記録済みの日を飛ばすため、繰り返し通知ではなく単発通知で予約する
      expect(plugin.matchComponents.values, everyElement(isNull));
      expect(plugin.cancelAllCalls, 0);
    });

    test('今日の時刻を過ぎていれば明日から予約する', () async {
      now = tz.TZDateTime(tokyo, 2026, 11, 28, 22);

      await createService().scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.scheduled, hasLength(days - 1));
      expect(plugin.scheduled.containsKey(id(2026, 11, 28)), isFalse);
      expect(plugin.scheduled.containsKey(id(2026, 11, 29)), isTrue);
    });

    test('2回続けて呼んでも何も取り消さず、入れ直しもしない', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      final before = Map.of(plugin.scheduled);
      plugin.scheduledIds.clear();

      await service.scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.cancelledIds, isEmpty);
      expect(plugin.scheduledIds, isEmpty);
      expect(plugin.scheduled, before);
    });

    test('記録済みになった日の予約だけを取り消す', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      plugin.scheduledIds.clear();

      await service.scheduleDailyReminder(
        time: nine,
        skipDates: {'2026-11-28', '2026-11-30'},
      );

      expect(
        plugin.cancelledIds,
        unorderedEquals([id(2026, 11, 28), id(2026, 11, 30)]),
      );
      expect(plugin.scheduledIds, isEmpty);
      final dates = plugin.scheduled.values.map(dateKey).toSet();
      expect(dates, isNot(contains('2026-11-28')));
      expect(dates, isNot(contains('2026-11-30')));
      expect(plugin.scheduled, hasLength(days - 2));
    });

    test('時刻を変えると同じIDで予約を上書きし、取り消しはしない', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      plugin.scheduledIds.clear();

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 22, minute: 15),
        skipDates: {},
      );

      expect(plugin.cancelledIds, isEmpty);
      expect(plugin.scheduledIds, hasLength(days));
      expect(
        plugin.scheduled[id(2026, 11, 28)],
        tz.TZDateTime(tokyo, 2026, 11, 28, 22, 15),
      );
    });

    test('時刻を変えて今日の分が過ぎたら、今日の予約は取り消す', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});

      await service.scheduleDailyReminder(
        time: const TimeOfDay(hour: 19, minute: 0),
        skipDates: {},
      );

      expect(plugin.cancelledIds, [id(2026, 11, 28)]);
      expect(plugin.scheduled.containsKey(id(2026, 11, 28)), isFalse);
    });

    test('表示中の今日のリマインダーは復帰時の再スケジュールで消さない', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      // 21:00 に届いて通知センターに表示されたまま、21:30 にアプリへ戻る
      plugin.deliver(id(2026, 11, 28));
      now = tz.TZDateTime(tokyo, 2026, 11, 28, 21, 30);

      await service.scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.displayed, contains(id(2026, 11, 28)));
      expect(plugin.cancelledIds, isEmpty);
      expect(plugin.cancelAllCalls, 0);
    });

    test('時刻を過ぎてまだ届いていない今日の予約は残す', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      // Android の inexact 予約が遅れて、まだ届いていない
      now = tz.TZDateTime(tokyo, 2026, 11, 28, 21, 5);

      await service.scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.cancelledIds, isEmpty);
      expect(plugin.scheduled.containsKey(id(2026, 11, 28)), isTrue);
    });

    test('今日を記録したら表示中の今日のリマインダーも消す', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      plugin.deliver(id(2026, 11, 28));
      now = tz.TZDateTime(tokyo, 2026, 11, 28, 21, 30);

      await service.scheduleDailyReminder(
        time: nine,
        skipDates: {'2026-11-28'},
      );

      expect(plugin.displayed, isNot(contains(id(2026, 11, 28))));
      expect(plugin.cancelledIds, [id(2026, 11, 28)]);
    });

    test('日付が進むと期間外になった予約がなくても新しい日を足すだけ', () async {
      final service = createService();
      await service.scheduleDailyReminder(time: nine, skipDates: {});
      for (final pendingId in plugin.scheduled.keys.toList()) {
        if (pendingId == id(2026, 11, 28)) plugin.deliver(pendingId);
      }
      plugin.scheduledIds.clear();
      now = tz.TZDateTime(tokyo, 2026, 11, 29, 8);

      await service.scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.cancelledIds, isEmpty);
      expect(plugin.scheduledIds, [id(2027, 1, 27)]);
      expect(plugin.displayed, contains(id(2026, 11, 28)));
    });

    test('関係ないIDの予約は取り消さず、旧形式のIDは取り消す', () async {
      plugin.scheduled[999] = now;
      plugin.scheduled[3] = now;

      await createService().scheduleDailyReminder(time: nine, skipDates: {});

      expect(plugin.cancelledIds, [3]);
      expect(plugin.scheduled.containsKey(999), isTrue);
    });

    test('夏時間の切り替わりをまたいでも同じ時刻に予約する', () async {
      final newYork = tz.getLocation('America/New_York');
      // 2026-03-08 に夏時間が始まる
      now = tz.TZDateTime(newYork, 2026, 3, 1, 8);

      await createService().scheduleDailyReminder(time: nine, skipDates: {});

      for (final target in plugin.scheduled.values) {
        expect(target.hour, 21, reason: '$target');
        expect(target.minute, 0, reason: '$target');
      }
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';
import 'package:one_photo_diary/providers/reminder_provider.dart';

import 'helpers/fake_notifications.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNotificationService fake;

  /// 保存済みの設定・記録済み日付をストレージに入れておく
  void setStorage({bool enabled = true, Set<String> dates = const {}}) {
    FlutterSecureStorage.setMockInitialValues({
      'reminder_enabled': enabled.toString(),
      'reminder_hour': '21',
      'reminder_minute': '30',
      if (dates.isNotEmpty) 'diary_dates': jsonEncode(dates.toList()),
    });
  }

  Future<ProviderContainer> createContainer() async {
    final c = ProviderContainer(
      overrides: [notificationServiceProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    // 起動時と同じくreminderProviderを読み込み、ストレージ読み込みを待つ
    c.read(reminderProvider);
    await pumpEventQueue();
    return c;
  }

  void simulateResume() {
    final binding = TestWidgetsFlutterBinding.instance;
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
    }
  }

  setUp(() {
    fake = FakeNotificationService();
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
  });

  group('ReminderNotifierの再スケジュールのきっかけ', () {
    test('起動時に有効なら記録済み日付を反映して予約する', () async {
      setStorage(dates: {'2026-11-28'});

      await createContainer();

      expect(fake.scheduleCalls, isNotEmpty);
      final last = fake.scheduleCalls.last;
      expect(last.time, const TimeOfDay(hour: 21, minute: 30));
      // 記録済み日付の読み込みが後になっても、最後の予約には反映される
      expect(last.skipDates, {'2026-11-28'});
    });

    test('起動時に無効なら予約しない', () async {
      setStorage(enabled: false, dates: {'2026-11-28'});

      await createContainer();
      simulateResume();
      await pumpEventQueue();

      expect(fake.scheduleCalls, isEmpty);
    });

    test('バックグラウンドからの復帰で再スケジュールする', () async {
      setStorage();
      await createContainer();
      final before = fake.scheduleCalls.length;

      simulateResume();
      await pumpEventQueue();

      expect(fake.scheduleCalls.length, before + 1);
    });

    test('復帰時はタイムゾーンを読み直してから再スケジュールする', () async {
      setStorage();
      await createContainer();
      fake.calls.clear();

      simulateResume();
      await pumpEventQueue();

      expect(fake.calls, ['refreshTimeZone', 'schedule']);
    });

    test('復帰時・記録時の予約失敗は捕捉される', () async {
      setStorage();
      final c = await createContainer();
      fake.scheduleError = StateError('platform');

      // 捕捉されない例外があるとテストが失敗する
      simulateResume();
      await pumpEventQueue();
      await c
          .read(diaryProvider.notifier)
          .saveEntry(photo: File('photo.jpg'), caption: '');
      await pumpEventQueue();

      expect(fake.calls.where((c) => c == 'schedule').length, greaterThan(1));
    });

    test('破棄後は復帰しても再スケジュールしない', () async {
      setStorage();
      final c = await createContainer();
      final before = fake.scheduleCalls.length;

      c.dispose();
      simulateResume();
      await pumpEventQueue();

      expect(fake.scheduleCalls.length, before);
    });

    test('記録の保存で再スケジュールし、その日をスキップする', () async {
      setStorage();
      final c = await createContainer();
      final before = fake.scheduleCalls.length;

      await c
          .read(diaryProvider.notifier)
          .saveEntry(photo: File('photo.jpg'), caption: '');
      await pumpEventQueue();

      final today = DateTime.now().toIso8601String().substring(0, 10);
      expect(fake.scheduleCalls.length, before + 1);
      expect(fake.scheduleCalls.last.skipDates, contains(today));
    });
  });

  group('ReminderNotifier.reschedule', () {
    test('連続した要求は直列に実行し、待機中のものは1回にまとめる', () async {
      setStorage();
      final c = await createContainer();
      final notifier = c.read(reminderProvider.notifier);
      fake.scheduleCalls.clear();
      fake.pendingSchedule = Completer<void>();

      final first = notifier.reschedule();
      await pumpEventQueue();
      // 1回目の実行中に届いた要求はまとめて1回だけ後で実行する
      final second = notifier.reschedule();
      final third = notifier.reschedule();
      expect(identical(second, third), isTrue);

      fake.pendingSchedule!.complete();
      await Future.wait([first, second, third]);

      expect(fake.scheduleCalls, hasLength(2));
      expect(fake.maxConcurrent, 1);
    });

    test('無効化した後に実行待ちの再スケジュールは予約しない', () async {
      setStorage();
      final c = await createContainer();
      final notifier = c.read(reminderProvider.notifier);
      fake.scheduleCalls.clear();
      fake.pendingSchedule = Completer<void>();

      final first = notifier.reschedule();
      await pumpEventQueue();
      final pending = notifier.reschedule();
      final disable = notifier.setEnabled(false);

      fake.pendingSchedule!.complete();
      await Future.wait([first, pending, disable]);

      expect(fake.scheduleCalls, hasLength(1));
      expect(fake.cancelAllCalls, 1);
    });

    test('予約が失敗しても後続の再スケジュールは実行する', () async {
      setStorage();
      final c = await createContainer();
      final notifier = c.read(reminderProvider.notifier);
      fake.scheduleCalls.clear();
      fake.scheduleError = StateError('x');

      await expectLater(notifier.reschedule(), throwsStateError);
      fake.scheduleError = null;
      await notifier.reschedule();

      expect(fake.scheduleCalls, hasLength(2));
    });
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/notification_service.dart';
import 'diary_provider.dart';

class ReminderState {
  final bool enabled;
  final TimeOfDay time;

  const ReminderState({required this.enabled, required this.time});

  ReminderState copyWith({bool? enabled, TimeOfDay? time}) =>
      ReminderState(enabled: enabled ?? this.enabled, time: time ?? this.time);

  static const defaultState = ReminderState(
    enabled: false,
    time: TimeOfDay(hour: 21, minute: 0),
  );
}

/// NotificationServiceのProvider（テストで差し替え可能にする）
final notificationServiceProvider = Provider<NotificationService>(
  (ref) => NotificationService.instance,
);

class ReminderNotifier extends Notifier<ReminderState> {
  static const _enabledKey = 'reminder_enabled';
  static const _hourKey = 'reminder_hour';
  static const _minuteKey = 'reminder_minute';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  NotificationService get _notifications =>
      ref.read(notificationServiceProvider);

  /// 通知の予約・取り消しを直列に実行するためのキュー
  Future<void> _queue = Future.value();

  /// 実行待ちの再スケジュール（連続した要求を1回にまとめる）
  Future<void>? _pendingReschedule;

  @override
  ReminderState build() {
    // 予約は scheduleDays 日分だけなので、バックグラウンドから戻るたびに予約を延長する
    final lifecycleListener = AppLifecycleListener(onResume: reschedule);
    ref.onDispose(lifecycleListener.dispose);
    // エントリ保存・削除時（起動直後の読み込み完了を含む）に再スケジュールして、記録済みの日をスキップ
    ref.listen<DiaryState>(diaryProvider, (prev, next) {
      if (prev?.datesWithEntries != next.datesWithEntries) reschedule();
    });
    _load();
    return ReminderState.defaultState;
  }

  Future<void> _load() async {
    final enabledStr = await _storage.read(key: _enabledKey);
    final hourStr = await _storage.read(key: _hourKey);
    final minuteStr = await _storage.read(key: _minuteKey);

    final enabled = enabledStr == 'true';
    final hour = int.tryParse(hourStr ?? '') ?? 21;
    final minute = int.tryParse(minuteStr ?? '') ?? 0;

    state = ReminderState(
      enabled: enabled,
      time: TimeOfDay(hour: hour, minute: minute),
    );

    if (enabled) {
      await reschedule();
    }
  }

  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      final granted = await _notifications.requestPermissions();
      if (!granted) return;
    }
    await _storage.write(key: _enabledKey, value: enabled.toString());
    state = state.copyWith(enabled: enabled);
    if (enabled) {
      await reschedule();
    } else {
      await _enqueue(() => _notifications.cancelAll());
    }
  }

  Future<void> setTime(TimeOfDay time) async {
    await _storage.write(key: _hourKey, value: time.hour.toString());
    await _storage.write(key: _minuteKey, value: time.minute.toString());
    state = state.copyWith(time: time);
    if (state.enabled) {
      await reschedule();
    }
  }

  /// 現在の設定とエントリ済み日付を反映して通知を再スケジュールする
  ///
  /// 取り消し→予約の途中で別の再スケジュールが割り込むと古い予約が残るため直列化する。
  /// 設定と記録済み日付は実行時点の最新値を読む。
  Future<void> reschedule() {
    return _pendingReschedule ??= _enqueue(() async {
      _pendingReschedule = null;
      if (!state.enabled) return;
      final diaryState = ref.read(diaryProvider);
      await _notifications.scheduleDailyReminder(
        time: state.time,
        skipDates: diaryState.datesWithEntries,
      );
    });
  }

  Future<void> _enqueue(Future<void> Function() task) {
    final result = _queue.then((_) => task());
    // 失敗しても後続の予約を止めない
    _queue = result.catchError((Object _) {});
    return result;
  }
}

final reminderProvider = NotifierProvider<ReminderNotifier, ReminderState>(
  () => ReminderNotifier(),
);

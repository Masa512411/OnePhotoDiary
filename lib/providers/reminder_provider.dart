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

class ReminderNotifier extends Notifier<ReminderState> {
  static const _enabledKey = 'reminder_enabled';
  static const _hourKey = 'reminder_hour';
  static const _minuteKey = 'reminder_minute';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  ReminderState build() {
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
      final granted = await NotificationService.instance.requestPermissions();
      if (!granted) return;
    }
    await _storage.write(key: _enabledKey, value: enabled.toString());
    state = state.copyWith(enabled: enabled);
    if (enabled) {
      await reschedule();
    } else {
      await NotificationService.instance.cancelAll();
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
  Future<void> reschedule() async {
    if (!state.enabled) return;
    final diaryState = ref.read(diaryProvider);
    await NotificationService.instance.scheduleDailyReminder(
      time: state.time,
      skipDates: diaryState.datesWithEntries,
    );
  }
}

final reminderProvider = NotifierProvider<ReminderNotifier, ReminderState>(
  () => ReminderNotifier(),
);

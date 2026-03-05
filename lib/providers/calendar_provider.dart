import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';

/// カレンダーの状態を保持するクラス
class CalendarState {
  final CalendarFormat calendarFormat;
  final DateTime focusedDay;
  final DateTime? selectedDay;

  const CalendarState({
    this.calendarFormat = CalendarFormat.month,
    required this.focusedDay,
    this.selectedDay,
  });

  CalendarState copyWith({
    CalendarFormat? calendarFormat,
    DateTime? focusedDay,
    DateTime? selectedDay,
  }) {
    return CalendarState(
      calendarFormat: calendarFormat ?? this.calendarFormat,
      focusedDay: focusedDay ?? this.focusedDay,
      selectedDay: selectedDay ?? this.selectedDay,
    );
  }
}

/// カレンダー状態を管理するNotifier
class CalendarNotifier extends Notifier<CalendarState> {
  @override
  CalendarState build() {
    final now = DateTime.now();
    return CalendarState(
      focusedDay: now,
      selectedDay: now,
    );
  }

  /// 日付を選択する
  void selectDay(DateTime selectedDay, DateTime focusedDay) {
    state = state.copyWith(
      selectedDay: selectedDay,
      focusedDay: focusedDay,
    );
  }

  /// カレンダーフォーマットを変更する
  void changeFormat(CalendarFormat format) {
    state = state.copyWith(calendarFormat: format);
  }

  /// ページ変更時にfocusedDayを更新する
  void changePage(DateTime focusedDay) {
    state = state.copyWith(focusedDay: focusedDay);
  }
}

/// カレンダー状態のProvider
final calendarProvider = NotifierProvider<CalendarNotifier, CalendarState>(
  () => CalendarNotifier(),
);

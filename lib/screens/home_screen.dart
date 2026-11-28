import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/calendar_provider.dart';
import 'camera_screen.dart';
import 'editor_screen.dart';
import 'entry_actions.dart';
import 'gallery_screen.dart';
import 'selection_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const double _daysOfWeekFontSize = 14.0;
  static const double _dayFontSize = 16.0;

  @override
  void initState() {
    super.initState();
    initializeDateFormatting('ja_JP');
  }

  List<String> _getEventsForDay(DateTime day, DiaryState diaryState) {
    return diaryState.hasEntry(day) ? ['photo'] : [];
  }

  void _openCamera() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const CameraScreen(),
      ),
    );
    ref.read(pendingPhotosProvider.notifier).reload();
  }

  /// 記録の無い過去の日を、取り込んだ写真で記録する
  void _recordPastDay(String dateKey) async {
    final photo = await pickEntryPhoto(context);
    if (photo == null || !mounted) return;
    // 保存されなかった場合、取り込んだ写真は編集画面を閉じるときに削除される
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EditorScreen(
          selectedPhoto: photo,
          date: dateKey,
          photoIsImported: true,
        ),
      ),
    );
  }

  void _openSelection(List<File> photos) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SelectionScreen(photos: photos),
      ),
    );
    ref.read(pendingPhotosProvider.notifier).reload();
  }

  @override
  Widget build(BuildContext context) {
    final pendingPhotos = ref.watch(pendingPhotosProvider);
    final calendarState = ref.watch(calendarProvider);
    final diaryState = ref.watch(diaryProvider);
    // 日本語フォントは行の高さが大きく、端末の文字サイズ設定でも拡大されるため、
    // TableCalendar の固定値(曜日行 16 / 日付行 52)では文字の下側が見切れる。
    // 実際の文字サイズから高さを算出する。
    final textScaler = MediaQuery.textScalerOf(context);
    final daysOfWeekHeight = textScaler.scale(_daysOfWeekFontSize) * 1.6;
    final rowHeight = max(52.0, textScaler.scale(_dayFontSize) * 1.6 + 12.0);

    final events = calendarState.selectedDay != null
        ? _getEventsForDay(calendarState.selectedDay!, diaryState)
        : [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('One Photo Diary'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'ギャラリー',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const GalleryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '設定',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStreakBanner(diaryState),
          if (pendingPhotos.isNotEmpty)
            GestureDetector(
              onTap: () => _openSelection(pendingPhotos),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blueGrey.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.photo_library, color: Colors.blueGrey),
                    const SizedBox(width: 16),
                    const Expanded(
                      child: Text(
                        '今日の写真が未選択です\nタップして「今日の一枚」を選びましょう',
                        style: TextStyle(color: Colors.blueGrey),
                      ),
                    ),
                    const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.blueGrey),
                  ],
                ),
              ),
            ),
          TableCalendar(
            locale: 'ja_JP',
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: calendarState.focusedDay,
            calendarFormat: calendarState.calendarFormat,
            selectedDayPredicate: (day) =>
                isSameDay(calendarState.selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              if (!isSameDay(calendarState.selectedDay, selectedDay)) {
                ref
                    .read(calendarProvider.notifier)
                    .selectDay(selectedDay, focusedDay);
              }
            },
            eventLoader: (day) => _getEventsForDay(day, diaryState),
            onFormatChanged: (format) {
              if (calendarState.calendarFormat != format) {
                ref.read(calendarProvider.notifier).changeFormat(format);
              }
            },
            onPageChanged: (focusedDay) {
              ref.read(calendarProvider.notifier).changePage(focusedDay);
            },
            daysOfWeekHeight: daysOfWeekHeight,
            rowHeight: rowHeight,
            daysOfWeekStyle: const DaysOfWeekStyle(
              weekdayStyle: TextStyle(
                fontSize: _daysOfWeekFontSize,
                color: Color(0xFF4F4F4F),
              ),
              weekendStyle: TextStyle(
                fontSize: _daysOfWeekFontSize,
                color: Color(0xFF6A6A6A),
              ),
            ),
            headerStyle: const HeaderStyle(
              formatButtonVisible: false,
              titleCentered: true,
            ),
            calendarStyle: const CalendarStyle(
              todayDecoration: BoxDecoration(
                color: Colors.black12,
                shape: BoxShape.circle,
              ),
              selectedDecoration: BoxDecoration(
                color: Colors.blueGrey,
                shape: BoxShape.circle,
              ),
              markerDecoration: BoxDecoration(
                color: Colors.blueGrey,
                shape: BoxShape.circle,
              ),
            ),
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, date, events) {
                if (events.isNotEmpty) {
                  return Positioned(
                    right: 1,
                    bottom: 1,
                    child: Icon(
                      Icons.check_circle,
                      size: 12.0,
                      color: Colors.blueGrey,
                    ),
                  );
                }
                return null;
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: calendarState.selectedDay != null && events.isNotEmpty
                ? _buildPhotoDetail(calendarState.selectedDay!)
                : _buildEmptyState(calendarState.selectedDay),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openCamera,
        backgroundColor: Colors.blueGrey,
        child: const Icon(Icons.camera_alt),
      ),
    );
  }

  Widget _buildPhotoDetail(DateTime selectedDay) {
    final dateKey = selectedDay.toIso8601String().substring(0, 10);
    final entryAsync = ref.watch(diaryEntryProvider(dateKey));
    return entryAsync.when(
      data: (entry) {
        if (entry == null) return _buildEmptyState(selectedDay);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      DateFormat('yyyy年MM月dd日 (E)', 'ja_JP')
                          .format(selectedDay),
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.black54,
                      ),
                    ),
                  ),
                  EntryActionsMenu(entry: entry, color: Colors.black54),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  entry.photo,
                  width: double.infinity,
                  height: 250,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: double.infinity,
                    height: 250,
                    color: Colors.grey[200],
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined,
                        color: Colors.black26, size: 48),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                entry.caption,
                style: const TextStyle(
                  fontSize: 16,
                  height: 1.6,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, st) => _buildEmptyState(selectedDay),
    );
  }

  Widget _buildStreakBanner(DiaryState diaryState) {
    final streak = diaryState.currentStreak;
    final hasToday = diaryState.hasEntryToday;

    if (streak == 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: streak >= 7
              ? [Colors.orange.shade400, Colors.deepOrange.shade400]
              : [Colors.blueGrey.shade300, Colors.blueGrey.shade500],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Text(
            streak >= 7 ? '🔥' : '✨',
            style: const TextStyle(fontSize: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$streak日連続記録中！',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                if (!hasToday)
                  const Text(
                    '今日も記録して継続しよう',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 記録が無い日の表示
  /// 今日は撮影、過去の日はその日の記録ができる。未来の日は記録できない
  Widget _buildEmptyState(DateTime? selectedDay) {
    final todayKey = DateTime.now().toIso8601String().substring(0, 10);
    final dateKey = selectedDay?.toIso8601String().substring(0, 10) ?? todayKey;
    // カレンダーの日付はUTCの0時で渡されるため、時刻ではなく日付の文字列で比べる
    final order = dateKey.compareTo(todayKey);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey[300]),
          const SizedBox(height: 16),
          Text(
            'この日の記録はありません',
            style: TextStyle(color: Colors.grey[500]),
          ),
          const SizedBox(height: 8),
          if (order == 0)
            TextButton(
              onPressed: _openCamera,
              child: const Text('写真を撮る'),
            )
          else if (order < 0)
            TextButton(
              onPressed: () => _recordPastDay(dateKey),
              child: const Text('この日を記録する'),
            ),
        ],
      ),
    );
  }
}

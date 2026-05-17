import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';
import '../providers/calendar_provider.dart';
import '../providers/reminder_provider.dart';
import 'camera_screen.dart';
import 'gallery_screen.dart';
import 'selection_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
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

    // エントリ保存・削除時にリマインダーを再スケジュールして、当日分の通知をスキップ
    ref.listen<DiaryState>(diaryProvider, (prev, next) {
      if (prev?.datesWithEntries != next.datesWithEntries) {
        ref.read(reminderProvider.notifier).reschedule();
      }
    });
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
                : _buildEmptyState(),
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
        if (entry == null) return _buildEmptyState();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                DateFormat('yyyy年MM月dd日 (E)', 'ja_JP').format(selectedDay),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  entry.photo,
                  width: double.infinity,
                  height: 250,
                  fit: BoxFit.cover,
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
      error: (e, st) => _buildEmptyState(),
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

  Widget _buildEmptyState() {
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
          TextButton(
            onPressed: _openCamera,
            child: const Text('写真を撮る'),
          ),
        ],
      ),
    );
  }
}

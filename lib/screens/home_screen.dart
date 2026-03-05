import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../providers/photo_provider.dart';
import '../providers/calendar_provider.dart';
import 'camera_screen.dart';
import 'selection_screen.dart';

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

  // TODO: 実際のデータをFirestoreから取得するように変更する
  List<String> _getEventsForDay(DateTime day) {
    // 仮実装: 偶数日には「記録あり」としてイベントを返す
    if (day.day % 2 == 0) {
      return ['photo'];
    }
    return [];
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
    final events = calendarState.selectedDay != null
        ? _getEventsForDay(calendarState.selectedDay!)
        : [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('One Photo Diary'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Column(
        children: [
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
            eventLoader: _getEventsForDay,
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
          Container(
            height: 250,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
              image: const DecorationImage(
                image: NetworkImage('https://picsum.photos/400/300'),
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '今日は近所の公園を散歩しました。木漏れ日がとても綺麗で、思わず立ち止まってしまいました。静かな一日でした。',
            style: TextStyle(
              fontSize: 16,
              height: 1.6,
              color: Colors.black87,
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

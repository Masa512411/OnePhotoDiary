import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = _focusedDay;
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

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    if (!isSameDay(_selectedDay, selectedDay)) {
      setState(() {
        _selectedDay = selectedDay;
        _focusedDay = focusedDay;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = _selectedDay != null ? _getEventsForDay(_selectedDay!) : [];

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
          TableCalendar(
            locale: 'ja_JP',
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: _onDaySelected,
            eventLoader: _getEventsForDay, // イベント（記録）がある日を判定
            onFormatChanged: (format) {
              if (_calendarFormat != format) {
                setState(() {
                  _calendarFormat = format;
                });
              }
            },
            onPageChanged: (focusedDay) {
              _focusedDay = focusedDay;
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
            // カレンダーのマーカーをカスタマイズ（チェックマーク）
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
          // 下部エリア：写真とテキスト
          Expanded(
            child: _selectedDay != null && events.isNotEmpty
                ? _buildPhotoDetail()
                : _buildEmptyState(),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          // TODO: カメラ起動処理
          print('Camera button tapped');
        },
        backgroundColor: Colors.blueGrey,
        child: const Icon(Icons.camera_alt),
      ),
    );
  }

  // 記録がある場合の表示
  Widget _buildPhotoDetail() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            DateFormat('yyyy年MM月dd日 (E)', 'ja_JP').format(_selectedDay!),
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 16),
          // 写真エリア（仮）
          Container(
            height: 250,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
              image: const DecorationImage(
                image: NetworkImage('https://picsum.photos/400/300'), // ダミー画像
                fit: BoxFit.cover,
              ),
            ),
          ),
          const SizedBox(height: 16),
          // テキストエリア
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

  // 記録がない場合の表示
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
            onPressed: () {
              // TODO: カメラ起動
            },
            child: const Text('写真を撮る'),
          ),
        ],
      ),
    );
  }
}

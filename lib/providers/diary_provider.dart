import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DiaryEntry {
  final File photo;
  final String caption;
  final String date;

  const DiaryEntry({
    required this.photo,
    required this.caption,
    required this.date,
  });

  factory DiaryEntry.fromJson(Map<String, dynamic> json) => DiaryEntry(
        photo: File(json['photo'] as String),
        caption: json['caption'] as String,
        date: json['date'] as String,
      );

  Map<String, dynamic> toJson() => {
        'photo': photo.path,
        'caption': caption,
        'date': date,
      };
}

class DiaryState {
  final Set<String> datesWithEntries;

  const DiaryState({this.datesWithEntries = const {}});

  DiaryState copyWith({Set<String>? datesWithEntries}) =>
      DiaryState(datesWithEntries: datesWithEntries ?? this.datesWithEntries);

  bool hasEntry(DateTime day) =>
      datesWithEntries.contains(day.toIso8601String().substring(0, 10));

  /// 今日を起点に連続記録日数を計算する
  /// 今日のエントリーがない場合は昨日を起点にする
  int get currentStreak {
    if (datesWithEntries.isEmpty) return 0;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = today.toIso8601String().substring(0, 10);

    // 今日のエントリーがあれば今日から、なければ昨日から遡る
    DateTime checkDate = datesWithEntries.contains(todayKey)
        ? today
        : today.subtract(const Duration(days: 1));

    int streak = 0;
    while (true) {
      final key = checkDate.toIso8601String().substring(0, 10);
      if (!datesWithEntries.contains(key)) break;
      streak++;
      checkDate = checkDate.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 今日のエントリーが存在するか
  bool get hasEntryToday {
    final todayKey = DateTime.now().toIso8601String().substring(0, 10);
    return datesWithEntries.contains(todayKey);
  }
}

class DiaryNotifier extends Notifier<DiaryState> {
  static const _datesKey = 'diary_dates';
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  DiaryState build() {
    _loadDates();
    return const DiaryState();
  }

  Future<void> _loadDates() async {
    final json = await _storage.read(key: _datesKey);
    if (json == null) return;
    final dates = Set<String>.from(jsonDecode(json) as List);
    state = state.copyWith(datesWithEntries: dates);
  }

  Future<void> saveEntry({required File photo, required String caption}) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final entry = DiaryEntry(photo: photo, caption: caption, date: today);
    await _storage.write(key: 'diary_$today', value: jsonEncode(entry.toJson()));
    final newDates = {...state.datesWithEntries, today};
    await _storage.write(key: _datesKey, value: jsonEncode(newDates.toList()));
    state = state.copyWith(datesWithEntries: newDates);
  }
}

final diaryProvider = NotifierProvider<DiaryNotifier, DiaryState>(
  () => DiaryNotifier(),
);

/// 指定日の日記エントリをFlutterSecureStorageから取得するProvider
final diaryEntryProvider =
    FutureProvider.autoDispose.family<DiaryEntry?, String>((ref, dateKey) async {
  // diaryProviderの状態変化（保存後）に追従する
  ref.watch(diaryProvider);
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final json = await storage.read(key: 'diary_$dateKey');
  if (json == null) return null;
  return DiaryEntry.fromJson(jsonDecode(json) as Map<String, dynamic>);
});

/// 全エントリを日付降順で返すProvider
final allDiaryEntriesProvider = FutureProvider<List<DiaryEntry>>((ref) async {
  final diaryState = ref.watch(diaryProvider);
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final sortedDates = diaryState.datesWithEntries.toList()
    ..sort((a, b) => b.compareTo(a));
  final entries = <DiaryEntry>[];
  for (final date in sortedDates) {
    final json = await storage.read(key: 'diary_$date');
    if (json == null) continue;
    entries.add(DiaryEntry.fromJson(jsonDecode(json) as Map<String, dynamic>));
  }
  return entries;
});

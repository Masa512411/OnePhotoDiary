import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}

class DiaryNotifier extends Notifier<DiaryState> {
  static const _datesKey = 'diary_dates';

  @override
  DiaryState build() {
    _loadDates();
    return const DiaryState();
  }

  Future<void> _loadDates() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_datesKey);
    if (json == null) return;
    final dates = Set<String>.from(jsonDecode(json) as List);
    state = state.copyWith(datesWithEntries: dates);
  }

  Future<void> saveEntry({required File photo, required String caption}) async {
    final prefs = await SharedPreferences.getInstance();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final entry = DiaryEntry(photo: photo, caption: caption, date: today);
    await prefs.setString('diary_$today', jsonEncode(entry.toJson()));
    final newDates = {...state.datesWithEntries, today};
    await prefs.setString(_datesKey, jsonEncode(newDates.toList()));
    state = state.copyWith(datesWithEntries: newDates);
  }
}

final diaryProvider = NotifierProvider<DiaryNotifier, DiaryState>(
  () => DiaryNotifier(),
);

/// 指定日の日記エントリをSharedPreferencesから取得するProvider
final diaryEntryProvider =
    FutureProvider.autoDispose.family<DiaryEntry?, String>((ref, dateKey) async {
  // diaryProviderの状態変化（保存後）に追従する
  ref.watch(diaryProvider);
  final prefs = await SharedPreferences.getInstance();
  final json = prefs.getString('diary_$dateKey');
  if (json == null) return null;
  return DiaryEntry.fromJson(jsonDecode(json) as Map<String, dynamic>);
});

import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/photo_storage.dart';

class DiaryEntry {
  final File photo;
  final String caption;
  final String date;

  const DiaryEntry({
    required this.photo,
    required this.caption,
    required this.date,
  });

  /// [documents]を渡すと、保存されたファイル名（旧データは絶対パス）を
  /// 現在のDocumentsディレクトリ上のパスに解決する
  factory DiaryEntry.fromJson(
    Map<String, dynamic> json, {
    Directory? documents,
  }) {
    final stored = json['photo'] as String;
    return DiaryEntry(
      photo: documents != null
          ? PhotoStorage.resolve(stored, documents)
          : File(stored),
      caption: json['caption'] as String,
      date: json['date'] as String,
    );
  }

  /// 写真はDocumentsディレクトリからのファイル名のみで保存する
  Map<String, dynamic> toJson() => {
        'photo': PhotoStorage.toStoredName(photo.path),
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
  final documents = await PhotoStorage.documentsDirectory();
  return DiaryEntry.fromJson(
    jsonDecode(json) as Map<String, dynamic>,
    documents: documents,
  );
});

/// 全エントリを日付降順で返すProvider
final allDiaryEntriesProvider = FutureProvider<List<DiaryEntry>>((ref) async {
  final diaryState = ref.watch(diaryProvider);
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final sortedDates = diaryState.datesWithEntries.toList()
    ..sort((a, b) => b.compareTo(a));
  final documents = await PhotoStorage.documentsDirectory();
  final entries = <DiaryEntry>[];
  for (final date in sortedDates) {
    final json = await storage.read(key: 'diary_$date');
    if (json == null) continue;
    entries.add(DiaryEntry.fromJson(
      jsonDecode(json) as Map<String, dynamic>,
      documents: documents,
    ));
  }
  return entries;
});

/// 保存済みの日記エントリが参照している写真のファイル名一覧を返す
/// （写真ファイル削除時に、保存済みエントリの写真を誤って消さないために使う）
Future<Set<String>> loadReferencedPhotoNames() async {
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final datesJson = await storage.read(key: DiaryNotifier._datesKey);
  if (datesJson == null) return {};
  final names = <String>{};
  for (final date in List<String>.from(jsonDecode(datesJson) as List)) {
    final json = await storage.read(key: 'diary_$date');
    if (json == null) continue;
    final entry = jsonDecode(json) as Map<String, dynamic>;
    names.add(PhotoStorage.toStoredName(entry['photo'] as String));
  }
  return names;
}

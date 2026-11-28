import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/photo_storage.dart';
import 'photo_provider.dart';

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

const _defaultDiaryStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(encryptedSharedPreferences: true),
);

/// 日記の保存に使うストレージ（テストで差し替えられるようProviderにしている）
final diaryStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => _defaultDiaryStorage,
);

const _diaryDatesKey = 'diary_dates';

/// 日付ごとのエントリのキー（diary_YYYY-MM-DD）
final _entryKeyPattern = RegExp(r'^diary_(\d{4}-\d{2}-\d{2})$');

/// ストレージから読んだ日付一覧
class _StoredDates {
  /// 一覧とdiary_YYYY-MM-DDのキーを合わせた日付
  final Set<String> dates;

  /// キーからの復元まで成功したか（失敗時は一覧の日付だけ）
  final bool recovered;

  /// 保存済みの一覧が壊れている、または一覧に無い日付があり、書き直すべきか
  final bool needsRepair;

  const _StoredDates(this.dates,
      {required this.recovered, required this.needsRepair});
}

/// ストレージから日付一覧を読む
/// 一覧に加えて、残っているdiary_YYYY-MM-DDのキーの日付も合わせて返す
/// （一覧の一部・全部が失われたデータでも過去の日記を扱えるようにするため）
///
/// - 一覧の読み込み自体が失敗した場合は例外を投げる（一時的な失敗の可能性があるため）
/// - 一覧の中身を解釈できない場合は壊れているとみなし、キーだけから作り直す
/// - キーの読み込み（readAll）に失敗した場合は一覧だけを返す。
///   ただし一覧も壊れていれば日付が分からないため例外を投げる
Future<_StoredDates> _readStoredDates(FlutterSecureStorage storage) async {
  final json = await storage.read(key: _diaryDatesKey);
  var listed = <String>{};
  var corrupt = false;
  if (json != null) {
    try {
      listed = Set<String>.from(jsonDecode(json) as List);
    } catch (e) {
      corrupt = true;
      debugPrint('日記の日付一覧が壊れているため作り直します: $e');
    }
  }

  final Iterable<String> keys;
  try {
    keys = (await storage.readAll()).keys;
  } catch (e) {
    if (corrupt) rethrow;
    debugPrint('日記の日付一覧の復元に失敗しました: $e');
    return _StoredDates(listed, recovered: false, needsRepair: false);
  }
  final dates = {
    ...listed,
    ...keys
        .map(_entryKeyPattern.firstMatch)
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!),
  };
  return _StoredDates(
    dates,
    recovered: true,
    needsRepair: corrupt || dates.length != listed.length,
  );
}

class DiaryNotifier extends Notifier<DiaryState> {
  FlutterSecureStorage get _storage => ref.read(diaryStorageProvider);

  /// 直近の日付一覧の読み込み（復元を含む）に失敗したか（次回の復帰時に再読み込みする）
  bool _loadFailed = false;

  /// 日付一覧の読み書きを直列に実行するためのキュー
  /// （読み込み時の書き戻しと保存が入れ違って、日付が減らないようにする）
  Future<void> _datesQueue = Future.value();

  static String _todayKey() =>
      DateTime.now().toIso8601String().substring(0, 10);

  @override
  DiaryState build() {
    // 読み込みに失敗していた場合、バックグラウンドから戻ったときに1回だけ再試行する
    final lifecycleListener = AppLifecycleListener(onResume: _onResume);
    ref.onDispose(lifecycleListener.dispose);
    _loadDates();
    return const DiaryState();
  }

  void _onResume() {
    if (_loadFailed) _loadDates();
  }

  Future<T> _withDatesLock<T>(Future<T> Function() action) {
    final result = _datesQueue.then((_) => action());
    _datesQueue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// 保存済みの日付一覧を読み込む
  /// 失敗しても例外は外に出さず、状態も消さない（次回の復帰時に再試行する）
  /// 一覧が壊れている・欠けている場合は、復元した一覧を書き戻す
  Future<void> _loadDates() async {
    _loadFailed = false;
    try {
      await _withDatesLock(() async {
        final stored = await _readStoredDates(_storage);
        _loadFailed = !stored.recovered;
        // 読み込み中に保存された日付を消さないよう、現在の状態と合わせる
        final dates = {...stored.dates, ...state.datesWithEntries};
        state = state.copyWith(datesWithEntries: dates);
        if (stored.needsRepair) {
          try {
            await _storage.write(
                key: _diaryDatesKey, value: jsonEncode(dates.toList()));
          } catch (e) {
            // 書き戻せなくても表示や保存には影響しないため無視する
            debugPrint('日記の日付一覧の書き戻しに失敗しました: $e');
          }
        }
      });
    } catch (e) {
      _loadFailed = true;
      debugPrint('日記の日付一覧の読み込みに失敗しました: $e');
    }
  }

  /// 指定日のエントリがストレージに保存済みか
  /// （読み込み前・失敗時のメモリ上の状態に頼らず、上書き確認に使う）
  Future<bool> hasEntryOn(String dateKey) async =>
      await _storage.read(key: 'diary_$dateKey') != null;

  /// 今日のエントリがストレージに保存済みか
  Future<bool> hasEntryToday() => hasEntryOn(_todayKey());

  /// エントリを保存する。[date]（yyyy-MM-dd）を省略した場合は今日の日付で保存する
  /// 同じ日のエントリがあれば上書きし、使われなくなった前の写真を削除する
  /// 未来の日付（今日より後）は記録できないため、何も書き込まずに[ArgumentError]を投げる
  Future<void> saveEntry({
    required File photo,
    required String caption,
    String? date,
  }) async {
    final dateKey = date ?? _todayKey();
    if (dateKey.compareTo(_todayKey()) > 0) {
      throw ArgumentError.value(date, 'date', '未来の日付には記録できません');
    }
    final entry = DiaryEntry(photo: photo, caption: caption, date: dateKey);
    final previous = await _withDatesLock(() async {
      // 日付一覧はメモリ上の状態ではなく保存済みの一覧に追加する
      // （読み込み前・失敗時に過去の日付を消さないため。読めなければ保存を中止する）
      final stored = await _readStoredDates(_storage);
      // 同じ日の記録を上書きする場合、前の写真を後で削除するため読んでおく
      final previous = await _storage.read(key: 'diary_$dateKey');
      await _storage.write(
          key: 'diary_$dateKey', value: jsonEncode(entry.toJson()));
      final newDates = {...stored.dates, dateKey};
      await _storage.write(
          key: _diaryDatesKey, value: jsonEncode(newDates.toList()));
      state = state.copyWith(
        datesWithEntries: {...newDates, ...state.datesWithEntries},
      );
      // 復元まで成功していれば状態は最新。失敗していれば復帰時に再試行する
      _loadFailed = !stored.recovered;
      return previous;
    });

    final previousName = _photoNameOf(previous);
    if (previousName != null &&
        previousName != PhotoStorage.toStoredName(photo.path)) {
      await _deleteReplacedPhoto(previousName);
    }
  }

  /// 指定日（yyyy-MM-dd）のエントリを削除する
  /// 使われなくなった写真も削除する（他のエントリ・撮影済み写真が参照していれば残す）
  Future<void> deleteEntry(String dateKey) async {
    final previous = await _withDatesLock(() async {
      // 日付一覧は保存済みの一覧から取り除く（読めなければ何も変更せず失敗する）
      final stored = await _readStoredDates(_storage);
      final previous = await _storage.read(key: 'diary_$dateKey');
      final newDates = {...stored.dates}..remove(dateKey);
      // 一覧を先に書き換える。キーの削除に失敗しても、キーが残っていれば
      // 次回の読み込みで一覧に復元されるため、一覧とキーが食い違ったままにならない
      await _storage.write(
          key: _diaryDatesKey, value: jsonEncode(newDates.toList()));
      await _storage.delete(key: 'diary_$dateKey');
      state = state.copyWith(
        datesWithEntries: {...newDates, ...state.datesWithEntries}
          ..remove(dateKey),
      );
      _loadFailed = !stored.recovered;
      return previous;
    });

    final previousName = _photoNameOf(previous);
    if (previousName != null) await _deleteReplacedPhoto(previousName);
  }

  /// 保存済みエントリのJSONから写真のファイル名を取り出す
  /// エントリが無い・壊れている場合はnull（写真の削除だけ諦める）
  static String? _photoNameOf(String? json) {
    if (json == null) return null;
    try {
      return PhotoStorage.toStoredName(
          (jsonDecode(json) as Map<String, dynamic>)['photo'] as String);
    } catch (_) {
      return null;
    }
  }

  /// 上書き・削除で使われなくなった写真を削除する
  /// 撮影済み写真として残っている場合や、他の日のエントリが参照している場合は削除しない
  Future<void> _deleteReplacedPhoto(String name) async {
    try {
      if ((await loadPendingPhotoNames()).contains(name)) return;
      final documents = await PhotoStorage.documentsDirectory();
      await deletePhotosIfUnreferenced(
        [PhotoStorage.resolve(name, documents)],
        storage: _storage,
      );
    } catch (_) {
      // 削除できなくても保存・削除自体は完了しているため無視する
    }
  }

  /// バックアップから復元したエントリをまとめて保存する
  /// 同じ日付のエントリは上書きし、使われなくなった写真は削除する
  /// 途中で失敗した場合は例外を投げ、日付一覧を読み直す
  /// （書き込み済みのエントリはキーから復元されるため一覧から漏れない）
  Future<void> importEntries(List<DiaryEntry> entries) async {
    final List<String> previousNames;
    try {
      previousNames = await _withDatesLock(() async {
        final stored = await _readStoredDates(_storage);
        final previous = <String>[];
        for (final entry in entries) {
          final key = 'diary_${entry.date}';
          // 前のエントリが壊れていても上書きは続ける（写真の削除だけ諦める）
          final previousName = _photoNameOf(await _storage.read(key: key));
          if (previousName != null) previous.add(previousName);
          await _storage.write(key: key, value: jsonEncode(entry.toJson()));
        }
        final newDates = {...stored.dates, ...entries.map((e) => e.date)};
        await _storage.write(
            key: _diaryDatesKey, value: jsonEncode(newDates.toList()));
        state = state.copyWith(
          datesWithEntries: {...newDates, ...state.datesWithEntries},
        );
        _loadFailed = !stored.recovered;
        return previous;
      });
    } catch (_) {
      await _loadDates();
      rethrow;
    }

    final newNames = {
      for (final entry in entries) PhotoStorage.toStoredName(entry.photo.path),
    };
    for (final name in previousNames) {
      if (!newNames.contains(name)) await _deleteReplacedPhoto(name);
    }
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
  final storage = ref.watch(diaryStorageProvider);
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
  final storage = ref.watch(diaryStorageProvider);
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
/// 一覧に無くてもdiary_YYYY-MM-DDのキーが残っているエントリも含める
/// キーからの復元に失敗した場合は参照漏れがありうるため例外を投げる
/// （呼び出し側で写真の削除やデータの消去を見送れるようにするため）
Future<Set<String>> loadReferencedPhotoNames({
  FlutterSecureStorage storage = _defaultDiaryStorage,
}) async {
  final stored = await _readStoredDates(storage);
  if (!stored.recovered) {
    throw StateError('日記のエントリ一覧を確認できないため、参照写真を確定できません');
  }
  final names = <String>{};
  for (final date in stored.dates) {
    final json = await storage.read(key: 'diary_$date');
    if (json == null) continue;
    final entry = jsonDecode(json) as Map<String, dynamic>;
    names.add(PhotoStorage.toStoredName(entry['photo'] as String));
  }
  return names;
}

/// 保存済みエントリから参照されていない写真ファイルだけを削除する
/// 参照の確認に失敗した場合は、誤削除を避けるため何も削除しない
Future<void> deletePhotosIfUnreferenced(
  List<File> files, {
  FlutterSecureStorage storage = _defaultDiaryStorage,
}) async {
  final Set<String> referenced;
  try {
    referenced = await loadReferencedPhotoNames(storage: storage);
  } catch (_) {
    return;
  }
  for (final file in files) {
    if (referenced.contains(PhotoStorage.toStoredName(file.path))) continue;
    await PhotoStorage.deleteQuietly(file);
  }
}

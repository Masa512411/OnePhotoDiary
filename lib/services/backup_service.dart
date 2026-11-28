import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';
import 'photo_storage.dart';

/// バックアップファイル（zip）の書き出しと復元
///
/// zipの中身は manifest.json と photos/ 以下の写真。
/// manifest.json: {format, version, exportedAt, entries: [{date, caption, photo}]}
/// zipの読み書き・写真の変換は重いため、すべて[compute]で別isolateで行う。
/// （別isolateではプラグインを使えないため、ディレクトリは呼び出し側で解決して渡す）
class BackupService {
  BackupService._();

  static const format = 'one_photo_diary_backup';
  static const version = 1;
  static const manifestName = 'manifest.json';
  static const photosDir = 'photos';

  /// 書き出したzipのファイル名の接頭辞（前回の一時ファイルの片付けに使う）
  static const fileNamePrefix = 'one_photo_diary_backup_';

  /// 共有時にshare_plusがファイルをコピーする一時ディレクトリ内のフォルダ（Android）
  static const _shareCacheDir = 'share_plus';

  /// 起動時・設定画面を開いた時に、この時間より前に書き出したzipを削除する
  /// （共有直後は受け取り側が読み込み中の可能性があるため、すぐには消さない）
  static const staleExportAge = Duration(hours: 1);

  /// zip内の写真1枚の展開後サイズの上限（細工したzipでメモリ不足にならないようにする）
  static const maxPhotoBytes = 50 * 1024 * 1024;

  /// 写真1枚の画素数（幅×高さ×フレーム数）の上限（デコード前にヘッダで確認する）
  static const maxPhotoPixels = 100000000;

  /// manifest.jsonの展開後サイズの上限
  static const maxManifestBytes = 10 * 1024 * 1024;

  static final _dateKeyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  static String _todayKey() =>
      DateTime.now().toIso8601String().substring(0, 10);

  /// 保存済みの全エントリを[outputDir]にzipで書き出す
  ///
  /// 日付一覧に加えて、一覧から漏れた diary_YYYY-MM-DD のキーの日記も含める。
  /// キーの確認に失敗した場合は一覧の日記だけを書き出し、結果の[complete]をfalseにする
  /// （一覧も読めない場合は例外を投げる）。
  /// 写真ファイルが見つからない・内容が壊れているエントリは書き出さず、件数を結果で返す。
  /// 書き出せる日記が無い場合はzipを作らない（前回のzipも消さない）。
  static Future<BackupExportResult> exportBackup({
    required FlutterSecureStorage storage,
    required Directory documents,
    required Directory outputDir,
    DateTime? now,
  }) async {
    final stored = await loadStoredDiaryDates(storage);
    final dates = stored.dates.toList()..sort();

    final manifestEntries = <Map<String, dynamic>>[];
    // zip内の名前 → 元ファイルのパス（同じ写真を複数回入れないようにする）
    final photos = <String, String>{};
    var skipped = 0;
    for (final date in dates) {
      final DiaryEntry entry;
      try {
        final json = await storage.read(key: 'diary_$date');
        // 一覧にだけ残っている日付は日記が無いため数えない
        if (json == null) continue;
        entry = DiaryEntry.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
          documents: documents,
        );
      } catch (_) {
        // 読めない・壊れたエントリがあっても他の日記は書き出せるようにする
        skipped++;
        continue;
      }
      if (!await entry.photo.exists()) {
        skipped++;
        continue;
      }
      final name = '$photosDir/${PhotoStorage.toStoredName(entry.photo.path)}';
      photos[name] = entry.photo.path;
      manifestEntries.add({
        'date': date,
        'caption': entry.caption,
        'photo': name,
      });
    }

    if (manifestEntries.isEmpty) {
      return BackupExportResult(
        file: null,
        entryCount: 0,
        skippedCount: skipped,
        complete: stored.complete,
      );
    }

    final exportedAt = now ?? DateTime.now();
    final manifest = jsonEncode({
      'format': format,
      'version': version,
      'exportedAt': exportedAt.toIso8601String(),
      'entries': manifestEntries,
    });

    await deleteOldExports(outputDir);
    final stamp = exportedAt
        .toIso8601String()
        .substring(0, 19)
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll('T', '_');
    final outputPath = path.join(outputDir.path, '$fileNamePrefix$stamp.zip');
    try {
      await compute(_writeZip, (
        outputPath: outputPath,
        manifest: manifest,
        photos: photos,
      ));
    } catch (_) {
      // 書きかけのzipを残さない
      await PhotoStorage.deleteQuietly(File(outputPath));
      rethrow;
    }
    return BackupExportResult(
      file: File(outputPath),
      entryCount: manifestEntries.length,
      skippedCount: skipped,
      complete: stored.complete,
    );
  }

  /// 以前に書き出したzipを削除する
  /// share_plusが共有のためにコピーしたファイル（Android）も対象にする
  /// [olderThan]を指定すると、それより前に作られたファイルだけを削除する
  static Future<void> deleteOldExports(
    Directory outputDir, {
    Duration? olderThan,
    DateTime? now,
  }) async {
    final threshold = olderThan == null
        ? null
        : (now ?? DateTime.now()).subtract(olderThan);
    for (final dir in [
      outputDir,
      Directory(path.join(outputDir.path, _shareCacheDir)),
    ]) {
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list()) {
          final name = path.basename(entity.path);
          if (entity is! File ||
              !name.startsWith(fileNamePrefix) ||
              !name.endsWith('.zip')) {
            continue;
          }
          if (threshold != null &&
              (await entity.lastModified()).isAfter(threshold)) {
            continue;
          }
          await PhotoStorage.deleteQuietly(entity);
        }
      } catch (_) {
        // 片付けられなくても動作には影響しないため無視する
      }
    }
  }

  /// zipを読み込んでmanifestを検証する（まだ何も保存しない）
  /// 内容が不正な場合は[BackupFormatException]を投げる
  /// 未来の日付（[today]より後）のエントリは復元できないため除き、件数を返す
  static Future<BackupContents> readBackup(
    String zipPath, {
    String? today,
    int maxPhotoBytes = maxPhotoBytes,
  }) async {
    final manifest = await compute(_readManifest, (
      zipPath: zipPath,
      maxPhotoBytes: maxPhotoBytes,
    ));
    return parseManifest(
      manifest.json,
      hasPhoto: manifest.photos.contains,
      zipPath: zipPath,
      today: today ?? _todayKey(),
    );
  }

  /// バックアップのうち、保存済みのエントリと日付が重なる件数
  /// （メモリ上の状態は読み込み前・失敗時に不完全なことがあるため、ストレージで確認する）
  static Future<int> countOverlapping(
    BackupContents contents,
    FlutterSecureStorage storage,
  ) async {
    var count = 0;
    for (final entry in contents.entries) {
      if (await storage.read(key: 'diary_${entry.date}') != null) count++;
    }
    return count;
  }

  /// バックアップを復元する
  ///
  /// 写真を新しいUUID名でDocumentsに保存してから、最後に[importEntries]でストレージへ書く。
  /// 失敗した場合は、今回保存した写真を削除する（ストレージは[importEntries]が元に戻す）。
  /// 元に戻すことにも失敗した場合（[DiaryImportRollbackException]）は、
  /// 残ったエントリが参照している写真を消さないよう、参照されていない写真だけを削除する
  static Future<void> restoreBackup(
    BackupContents contents, {
    required Directory documents,
    required FlutterSecureStorage storage,
    required Future<void> Function(List<DiaryEntry> entries) importEntries,
    int maxPhotoBytes = maxPhotoBytes,
    int maxPhotoPixels = maxPhotoPixels,
  }) async {
    const uuid = Uuid();
    // 保存先の名前はzip内の名前を使わず、ここで決める
    // （別isolateが途中で失敗しても、片付ける対象が分かるようにするため）
    final destinations = <String, String>{};
    for (final entry in contents.entries) {
      destinations[entry.photo] ??= path.join(
        documents.path,
        '${uuid.v4()}.jpg',
      );
    }
    final files = [for (final dest in destinations.values) File(dest)];

    try {
      await compute(_extractPhotos, (
        zipPath: contents.zipPath,
        destinations: destinations,
        maxPhotoBytes: maxPhotoBytes,
        maxPhotoPixels: maxPhotoPixels,
      ));
      await importEntries([
        for (final entry in contents.entries)
          DiaryEntry(
            photo: File(destinations[entry.photo]!),
            caption: entry.caption,
            date: entry.date,
          ),
      ]);
    } on DiaryImportRollbackException {
      await deletePhotosIfUnreferenced(files, storage: storage);
      rethrow;
    } catch (_) {
      // 今回保存した写真は新しい名前で、どこからも参照されていないため直接削除する
      // （参照の確認は壊れたエントリがあると失敗し、何も消せなくなるため使わない）
      for (final file in files) {
        await PhotoStorage.deleteQuietly(file);
      }
      rethrow;
    }
  }

  /// manifestの日付を検証する
  /// 日付はストレージのキー（`diary_<date>`）になるため、厳密に確認する
  /// （例えば "dates" を通すと diary_dates を上書きしてしまう）
  static bool isValidDate(Object? date) {
    if (date is! String || !_dateKeyPattern.hasMatch(date)) return false;
    final parsed = DateTime.tryParse(date);
    return parsed != null && parsed.toIso8601String().startsWith(date);
  }

  /// manifestの写真のパスを検証する（photos/<ファイル名> のみ許可）
  static bool isValidPhotoPath(Object? photo) {
    if (photo is! String) return false;
    final parts = photo.split('/');
    return parts.length == 2 &&
        parts[0] == photosDir &&
        parts[1].isNotEmpty &&
        parts[1] != '.' &&
        parts[1] != '..' &&
        !parts[1].contains('\\');
  }

  /// manifest.jsonの内容を検証してバックアップの内容を返す
  /// 未来の日付（[today]より後）のエントリは除き、件数を[BackupContents.skippedFutureCount]で返す
  /// （端末の時計やタイムゾーンの違いで、正しいバックアップでも起こりうるため全体は拒否しない）
  static BackupContents parseManifest(
    String json, {
    required bool Function(String photo) hasPhoto,
    required String zipPath,
    required String today,
  }) {
    final Object? manifest;
    try {
      manifest = jsonDecode(json);
    } catch (_) {
      throw const BackupFormatException('バックアップの情報を読み取れませんでした');
    }
    if (manifest is! Map || manifest['format'] != format) {
      throw const BackupFormatException('このアプリのバックアップファイルではありません');
    }
    final fileVersion = manifest['version'];
    if (fileVersion is int && fileVersion > version) {
      throw const BackupFormatException(
        '新しいバージョンのアプリで作られたバックアップです。アプリを更新してください',
      );
    }
    if (fileVersion != version) {
      throw const BackupFormatException('対応していないバックアップの形式です');
    }
    final rawEntries = manifest['entries'];
    if (rawEntries is! List) {
      throw const BackupFormatException('バックアップの情報が壊れています');
    }

    final entries = <BackupEntry>[];
    final dates = <String>{};
    var skippedFuture = 0;
    for (final raw in rawEntries) {
      if (raw is! Map) {
        throw const BackupFormatException('バックアップの情報が壊れています');
      }
      final date = raw['date'];
      final caption = raw['caption'];
      final photo = raw['photo'];
      if (!isValidDate(date) ||
          caption is! String ||
          !isValidPhotoPath(photo)) {
        throw const BackupFormatException('バックアップの情報が壊れています');
      }
      if (!dates.add(date as String)) {
        throw const BackupFormatException('バックアップに同じ日付の日記が重複しています');
      }
      if (!hasPhoto(photo as String)) {
        throw const BackupFormatException('バックアップに含まれる写真が見つかりません');
      }
      if (date.compareTo(today) > 0) {
        skippedFuture++;
        continue;
      }
      entries.add(BackupEntry(date: date, caption: caption, photo: photo));
    }
    return BackupContents(
      zipPath: zipPath,
      entries: entries,
      skippedFutureCount: skippedFuture,
    );
  }
}

/// 書き出しの結果
class BackupExportResult {
  /// 書き出したzip（書き出せる日記が無かった場合はnull）
  final File? file;

  /// 書き出したエントリ数
  final int entryCount;

  /// 写真ファイルが見つからない・内容が壊れているため書き出さなかったエントリ数
  final int skippedCount;

  /// 保存済みの日記をすべて確認できたか
  /// （falseの場合、日付一覧から漏れた日記が含まれていない可能性がある）
  final bool complete;

  const BackupExportResult({
    required this.file,
    required this.entryCount,
    required this.skippedCount,
    required this.complete,
  });
}

/// manifestの1エントリ
class BackupEntry {
  final String date;
  final String caption;

  /// zip内の写真のパス（photos/<ファイル名>）
  final String photo;

  const BackupEntry({
    required this.date,
    required this.caption,
    required this.photo,
  });
}

/// 検証済みのバックアップの内容
class BackupContents {
  final String zipPath;

  /// 復元するエントリ（未来の日付のエントリは含まない）
  final List<BackupEntry> entries;

  /// 未来の日付のため復元しないエントリ数
  final int skippedFutureCount;

  const BackupContents({
    required this.zipPath,
    required this.entries,
    this.skippedFutureCount = 0,
  });
}

/// バックアップファイルの内容が不正な場合の例外（messageはそのまま画面に表示できる）
class BackupFormatException implements Exception {
  final String message;

  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

const _tooLargePhotoMessage = 'バックアップに大きすぎる写真が含まれています';

/// zipを書き出す（[compute]で別isolateから呼ばれる）
/// 写真はJPEGで圧縮しても小さくならないため無圧縮で格納する
void _writeZip(
  ({String outputPath, String manifest, Map<String, String> photos}) args,
) {
  final encoder = ZipFileEncoder();
  encoder.create(args.outputPath, level: ZipFileEncoder.store);
  try {
    encoder.addArchiveFile(
      ArchiveFile.string(BackupService.manifestName, args.manifest),
    );
    for (final MapEntry(key: name, value: source) in args.photos.entries) {
      encoder.addFileSync(File(source), name);
    }
  } finally {
    encoder.closeSync();
  }
}

/// zipを開く（壊れている場合は[BackupFormatException]）
(InputFileStream, Archive) _openZip(String zipPath) {
  final input = InputFileStream(zipPath);
  try {
    return (input, ZipDecoder().decodeStream(input));
  } catch (_) {
    input.closeSync();
    throw const BackupFormatException('バックアップファイルを開けませんでした。ファイルが壊れている可能性があります');
  }
}

/// zip内の写真を探す。展開後サイズが上限を超える場合は[BackupFormatException]
/// （展開時はヘッダのサイズまでしか展開されないため、ヘッダで確認すれば足りる）
ArchiveFile? _findPhoto(Archive archive, String name, int maxBytes) {
  final file = archive.find(name);
  if (file == null || !file.isFile || file.size <= 0) return null;
  if (file.size > maxBytes) {
    throw const BackupFormatException(_tooLargePhotoMessage);
  }
  return file;
}

/// manifestを読み、写真の存在とサイズを確認する（[compute]で別isolateから呼ばれる）
/// 返す写真の一覧は、manifestから参照されていて存在する写真だけ
({String json, Set<String> photos}) _readManifest(
  ({String zipPath, int maxPhotoBytes}) args,
) {
  final (input, archive) = _openZip(args.zipPath);
  try {
    final manifestFile = archive.find(BackupService.manifestName);
    if (manifestFile == null || !manifestFile.isFile) {
      throw const BackupFormatException('このアプリのバックアップファイルではありません');
    }
    if (manifestFile.size > BackupService.maxManifestBytes) {
      throw const BackupFormatException('バックアップの情報が大きすぎます');
    }
    final String json;
    try {
      json = utf8.decode(manifestFile.readBytes() ?? const []);
    } catch (_) {
      throw const BackupFormatException('バックアップの情報を読み取れませんでした');
    }
    // manifestの写真のパスを取り出して確認する（形式の検証はparseManifestで行う）
    final photos = <String>{};
    try {
      final entries = (jsonDecode(json) as Map)['entries'] as List;
      for (final entry in entries) {
        final photo = (entry as Map)['photo'];
        if (photo is String &&
            BackupService.isValidPhotoPath(photo) &&
            _findPhoto(archive, photo, args.maxPhotoBytes) != null) {
          photos.add(photo);
        }
      }
    } on BackupFormatException {
      rethrow;
    } catch (_) {
      // 形式の誤りはparseManifestで分かりやすいメッセージにする
    }
    return (json: json, photos: photos);
  } finally {
    input.closeSync();
  }
}

/// zip内の写真を変換して保存する（[compute]で別isolateから呼ばれる）
/// 外部から持ち込む写真のため、撮影時と同じくEXIFを除去したJPEGに変換して保存する
/// （画像として読めない写真が含まれていればここで失敗する）
void _extractPhotos(
  ({
    String zipPath,
    Map<String, String> destinations,
    int maxPhotoBytes,
    int maxPhotoPixels,
  })
  args,
) {
  final (input, archive) = _openZip(args.zipPath);
  try {
    for (final MapEntry(key: name, value: dest) in args.destinations.entries) {
      final bytes = _findPhoto(archive, name, args.maxPhotoBytes)?.readBytes();
      if (bytes == null) {
        throw const BackupFormatException('バックアップに含まれる写真が見つかりません');
      }
      _checkPixels(bytes, args.maxPhotoPixels);
      final Uint8List clean;
      try {
        clean = processCapturedImage(bytes);
      } catch (_) {
        throw const BackupFormatException('バックアップに読み込めない写真が含まれています');
      }
      File(dest).writeAsBytesSync(clean, flush: true);
    }
  } finally {
    input.closeSync();
  }
}

/// デコードする前に、ヘッダから画像の画素数（幅×高さ×フレーム数）を確認する
/// （小さなファイルでも展開後の画素が巨大な画像で、メモリ不足にならないようにする）
void _checkPixels(Uint8List bytes, int maxPixels) {
  final img.DecodeInfo? info;
  try {
    info = img.findDecoderForData(bytes)?.startDecode(bytes);
  } catch (_) {
    throw const BackupFormatException('バックアップに読み込めない写真が含まれています');
  }
  if (info == null || info.width <= 0 || info.height <= 0) {
    throw const BackupFormatException('バックアップに読み込めない写真が含まれています');
  }
  final frames = info.numFrames < 1 ? 1 : info.numFrames;
  if (info.width * info.height * frames > maxPixels) {
    throw const BackupFormatException(_tooLargePhotoMessage);
  }
}

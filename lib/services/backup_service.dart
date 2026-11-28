import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  static final _dateKeyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static final _entryKeyPattern = RegExp(r'^diary_(\d{4}-\d{2}-\d{2})$');

  /// 保存済みの全エントリを[outputDir]にzipで書き出す
  ///
  /// エントリは diary_YYYY-MM-DD のキーから集める（日付一覧から漏れた日記も含めるため）。
  /// 一部だけのバックアップにならないよう、読み込みに失敗した場合は例外を投げる。
  /// 写真ファイルが見つからない・内容が壊れているエントリは書き出さず、件数を結果で返す。
  static Future<BackupExportResult> exportBackup({
    required FlutterSecureStorage storage,
    required Directory documents,
    required Directory outputDir,
    DateTime? now,
  }) async {
    final all = await storage.readAll();
    final dates = all.keys
        .map(_entryKeyPattern.firstMatch)
        .whereType<RegExpMatch>()
        .map((match) => match.group(1)!)
        .toList()
      ..sort();

    final manifestEntries = <Map<String, dynamic>>[];
    // zip内の名前 → 元ファイルのパス（同じ写真を複数回入れないようにする）
    final photos = <String, String>{};
    var skipped = 0;
    for (final date in dates) {
      final String name;
      final String caption;
      try {
        final json = jsonDecode(all['diary_$date']!) as Map<String, dynamic>;
        name = PhotoStorage.toStoredName(json['photo'] as String);
        caption = json['caption'] as String? ?? '';
      } catch (_) {
        // 壊れたエントリがあっても他の日記は書き出せるようにする
        skipped++;
        continue;
      }
      final photo = PhotoStorage.resolve(name, documents);
      if (!await photo.exists()) {
        skipped++;
        continue;
      }
      photos['$photosDir/$name'] = photo.path;
      manifestEntries.add({
        'date': date,
        'caption': caption,
        'photo': '$photosDir/$name',
      });
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
    );
  }

  /// 以前に書き出したzipを削除する
  /// （共有直後は受け取り側が読み込み中の可能性があるため、次回の書き出し時に片付ける）
  static Future<void> deleteOldExports(Directory outputDir) async {
    try {
      if (!await outputDir.exists()) return;
      await for (final entity in outputDir.list()) {
        final name = path.basename(entity.path);
        if (entity is File &&
            name.startsWith(fileNamePrefix) &&
            name.endsWith('.zip')) {
          await PhotoStorage.deleteQuietly(entity);
        }
      }
    } catch (_) {
      // 片付けられなくても書き出しには影響しないため無視する
    }
  }

  /// zipを読み込んでmanifestを検証する（まだ何も保存しない）
  /// 内容が不正な場合は[BackupFormatException]を投げる
  static Future<BackupContents> readBackup(String zipPath) async {
    final entries = await compute(_readManifest, zipPath);
    return BackupContents(zipPath: zipPath, entries: entries);
  }

  /// バックアップのうち、保存済みのエントリと日付が重なる件数
  /// （メモリ上の状態は読み込み前・失敗時に不完全なことがあるため、ストレージで確認する）
  static Future<int> countOverlapping(
    BackupContents contents,
    FlutterSecureStorage storage,
  ) async {
    final keys = (await storage.readAll()).keys.toSet();
    return contents.entries
        .where((entry) => keys.contains('diary_${entry.date}'))
        .length;
  }

  /// バックアップを復元する
  ///
  /// 写真を新しいUUID名でDocumentsに保存してから、最後に[importEntries]でストレージへ書く。
  /// - 写真の保存中に失敗した場合は、保存した写真をすべて削除する（ストレージは変更しない）
  /// - ストレージへの書き込み中に失敗した場合は、書き込み済みのエントリから
  ///   参照されていない写真だけを削除する
  static Future<void> restoreBackup(
    BackupContents contents, {
    required Directory documents,
    required FlutterSecureStorage storage,
    required Future<void> Function(List<DiaryEntry> entries) importEntries,
  }) async {
    const uuid = Uuid();
    // 保存先の名前はzip内の名前を使わず、ここで決める
    // （別isolateが途中で失敗しても、片付ける対象が分かるようにするため）
    final destinations = <String, String>{};
    for (final entry in contents.entries) {
      destinations[entry.photo] ??=
          path.join(documents.path, '${uuid.v4()}.jpg');
    }
    final files = [for (final dest in destinations.values) File(dest)];

    try {
      await compute(_extractPhotos, (
        zipPath: contents.zipPath,
        destinations: destinations,
      ));
    } catch (_) {
      for (final file in files) {
        await PhotoStorage.deleteQuietly(file);
      }
      rethrow;
    }

    final entries = [
      for (final entry in contents.entries)
        DiaryEntry(
          photo: File(destinations[entry.photo]!),
          caption: entry.caption,
          date: entry.date,
        ),
    ];
    try {
      await importEntries(entries);
    } catch (_) {
      await deletePhotosIfUnreferenced(files, storage: storage);
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

  /// manifest.jsonの内容を検証してエントリ一覧を返す
  static List<BackupEntry> parseManifest(
    String json,
    bool Function(String photo) hasPhoto,
  ) {
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
          '新しいバージョンのアプリで作られたバックアップです。アプリを更新してください');
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
      entries.add(BackupEntry(date: date, caption: caption, photo: photo));
    }
    return entries;
  }
}

/// 書き出しの結果
class BackupExportResult {
  final File file;

  /// 書き出したエントリ数
  final int entryCount;

  /// 写真ファイルが見つからない・内容が壊れているため書き出さなかったエントリ数
  final int skippedCount;

  const BackupExportResult({
    required this.file,
    required this.entryCount,
    required this.skippedCount,
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
  final List<BackupEntry> entries;

  const BackupContents({required this.zipPath, required this.entries});
}

/// バックアップファイルの内容が不正な場合の例外（messageはそのまま画面に表示できる）
class BackupFormatException implements Exception {
  final String message;

  const BackupFormatException(this.message);

  @override
  String toString() => message;
}

/// zipを書き出す（[compute]で別isolateから呼ばれる）
/// 写真はJPEGで圧縮しても小さくならないため無圧縮で格納する
void _writeZip(
  ({String outputPath, String manifest, Map<String, String> photos}) args,
) {
  final encoder = ZipFileEncoder();
  encoder.create(args.outputPath, level: ZipFileEncoder.store);
  try {
    encoder.addArchiveFile(
        ArchiveFile.string(BackupService.manifestName, args.manifest));
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

/// manifestを読んで検証する（[compute]で別isolateから呼ばれる）
List<BackupEntry> _readManifest(String zipPath) {
  final (input, archive) = _openZip(zipPath);
  try {
    final manifestFile = archive.find(BackupService.manifestName);
    if (manifestFile == null || !manifestFile.isFile) {
      throw const BackupFormatException('このアプリのバックアップファイルではありません');
    }
    final String json;
    try {
      json = utf8.decode(manifestFile.readBytes() ?? const []);
    } catch (_) {
      throw const BackupFormatException('バックアップの情報を読み取れませんでした');
    }
    return BackupService.parseManifest(json, (photo) {
      final file = archive.find(photo);
      return file != null && file.isFile;
    });
  } finally {
    input.closeSync();
  }
}

/// zip内の写真を変換して保存する（[compute]で別isolateから呼ばれる）
/// 外部から持ち込む写真のため、撮影時と同じくEXIFを除去したJPEGに変換して保存する
/// （画像として読めない写真が含まれていればここで失敗する）
void _extractPhotos(
  ({String zipPath, Map<String, String> destinations}) args,
) {
  final (input, archive) = _openZip(args.zipPath);
  try {
    for (final MapEntry(key: name, value: dest) in args.destinations.entries) {
      final bytes = archive.find(name)?.readBytes();
      if (bytes == null) {
        throw const BackupFormatException('バックアップに含まれる写真が見つかりません');
      }
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

import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// 写真ファイルの保存場所に関するユーティリティ
///
/// iOSではアップデートや再インストールでアプリコンテナのパスが変わるため、
/// 写真は絶対パスではなくDocumentsディレクトリからのファイル名で保存し、
/// 読み込み時に現在のDocumentsディレクトリと結合して解決する。
class PhotoStorage {
  PhotoStorage._();

  /// 写真を保存するDocumentsディレクトリ
  static Future<Directory> documentsDirectory() =>
      getApplicationDocumentsDirectory();

  /// 保存用の値（ファイル名のみ）に変換する
  /// 旧データの絶対パスもファイル名に変換される
  static String toStoredName(String pathOrName) => path.basename(pathOrName);

  /// 保存されている値（ファイル名、または旧データの絶対パス）を
  /// 現在のDocumentsディレクトリ上のファイルに解決する
  static File resolve(String stored, Directory documents) =>
      File(path.join(documents.path, toStoredName(stored)));

  /// ファイルを削除する（存在しない・削除失敗の場合は無視する）
  static Future<void> deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 削除できなくてもアプリの動作には影響しないため無視する
    }
  }
}

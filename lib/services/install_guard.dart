import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';
import 'photo_storage.dart';

/// 再インストール時にKeychainに残った古いデータを消去する
///
/// iOSではflutter_secure_storage（Keychain）のデータがアプリ削除後も残るため、
/// 再インストールすると写真が存在しない日記エントリが表示されてしまう。
/// アンインストールで消えるDocumentsディレクトリにマーカーファイルを置き、
/// マーカーがない初回起動時に、残ったデータの写真が1枚も存在しなければ消去する。
class InstallGuard {
  InstallGuard._();

  static const markerFileName = '.install_marker';

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 起動時に呼び出す。消去した場合はtrueを返す
  static Future<bool> run() async {
    try {
      final documents = await PhotoStorage.documentsDirectory();
      final marker = File(path.join(documents.path, markerFileName));
      if (await marker.exists()) return false;

      final isLeftover = await _isLeftoverFromPreviousInstall(documents);
      if (isLeftover) await _storage.deleteAll();
      await marker.create(recursive: true);
      return isLeftover;
    } catch (_) {
      // 判定できない場合はデータを消さない（次回起動時に再判定する）
      return false;
    }
  }

  /// マーカーがない状態で、SecureStorageのデータが前回インストールの残骸かを判定する
  ///
  /// マーカー導入前のバージョンからのアップデートでもマーカーはないため、
  /// 参照している写真がDocumentsに1枚でも残っていればアップデートとみなす。
  /// 写真を参照するデータがない場合も、消して得るものがないため消去しない。
  static Future<bool> _isLeftoverFromPreviousInstall(
    Directory documents,
  ) async {
    final names = {
      ...await loadReferencedPhotoNames(),
      ...await loadPendingPhotoNames(),
    };
    if (names.isEmpty) return false;
    for (final name in names) {
      if (await PhotoStorage.resolve(name, documents).exists()) return false;
    }
    return true;
  }
}

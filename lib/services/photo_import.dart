import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../providers/photo_provider.dart';
import 'photo_storage.dart';

/// 編集での写真の差し替え・過去日の記録用に、写真を1枚取り込む処理
///
/// 撮影済み写真（pending_photos）には加えず、Documentsに保存したファイルを返すだけにする。
/// 保存した写真がエントリに使われなかった場合は、呼び出し側で
/// deletePhotosIfUnreferenced により片付ける。
class PhotoImport {
  PhotoImport._();

  /// カメラまたはアルバムから画像を1枚選び、選んだ画像のパスを返す（キャンセル時はnull）
  static Future<String?> pick(ImageSource source) async {
    final XFile? photo = await ImagePicker().pickImage(
      source: source,
      // 保存時の変換処理を軽くするため、あらかじめ縮小する
      maxWidth: maxPhotoDimension.toDouble(),
      maxHeight: maxPhotoDimension.toDouble(),
      imageQuality: 90,
    );
    return photo?.path;
  }

  /// 画像をEXIFなし・縮小済みのJPEGに変換し、DocumentsにUUID.jpgで保存する
  static Future<File> save(String sourcePath) async {
    // ファイル名で写真を識別・削除するため、衝突しないUUIDで命名する
    final directory = await PhotoStorage.documentsDirectory();
    final fileName = '${const Uuid().v4()}.jpg';
    final destPath = PhotoStorage.resolve(fileName, directory).path;

    final rawBytes = await File(sourcePath).readAsBytes();
    // デコード・エンコードは重いため、UIを止めないよう別isolateで行う
    // 撮影時と同じ変換（EXIF除去・縮小）を使う
    final cleanBytes = await compute(processCapturedImage, rawBytes);
    return File(destPath).writeAsBytes(cleanBytes);
  }
}

import 'package:image_picker/image_picker.dart';

import '../providers/photo_provider.dart';

/// 編集での写真の差し替え・過去日の記録用に、写真を1枚選ぶ処理
///
/// 選んだ画像は[savePhotoToDocuments]でDocumentsに保存し、撮影済み写真（pending_photos）
/// には加えない。保存した写真がエントリに使われなかった場合は、呼び出し側で
/// deletePhotosIfUnreferenced により片付ける。
class PhotoImport {
  PhotoImport._();

  /// カメラまたはアルバムから画像を1枚選び、選んだ画像のパスを返す（キャンセル時はnull）
  /// [picker]はテストで差し替えられるよう、imagePickerProviderから渡す
  static Future<String?> pick(ImagePicker picker, ImageSource source) async {
    final size = maxPhotoDimension.toDouble();
    final XFile? photo = await picker.pickImage(
      source: source,
      // 保存時の変換処理を軽くするため、あらかじめ縮小する
      maxWidth: size,
      maxHeight: size,
      imageQuality: 90,
      // 写真ライブラリの権限を求めずに選べるよう、メタデータは要求しない
      requestFullMetadata: false,
    );
    return photo?.path;
  }
}

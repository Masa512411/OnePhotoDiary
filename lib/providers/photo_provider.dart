import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../services/photo_storage.dart';

/// 撮影済み写真（pending_photos）を管理するNotifier
class PhotoNotifier extends Notifier<List<File>> {
  static const String _storageKey = 'pending_photos';
  static const int maxPhotos = 3;

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  List<File> build() {
    _loadFromStorage();
    return [];
  }

  /// SecureStorageから写真を読み込む
  /// 保存値はファイル名（旧データは絶対パス）なので、現在のDocumentsディレクトリで解決する
  Future<void> _loadFromStorage() async {
    final json = await _storage.read(key: _storageKey);
    if (json != null) {
      final documents = await PhotoStorage.documentsDirectory();
      final names = List<String>.from(jsonDecode(json));
      state = names.map((n) => PhotoStorage.resolve(n, documents)).toList();
    }
  }

  /// SecureStorageに写真のファイル名を保存する
  Future<void> _saveToStorage() async {
    final names = state.map((f) => PhotoStorage.toStoredName(f.path)).toList();
    await _storage.write(key: _storageKey, value: jsonEncode(names));
  }

  /// SecureStorageから写真パスを再読み込みする（画面復帰時用）
  Future<void> reload() async {
    await _loadFromStorage();
  }

  /// カメラで写真を撮影して追加する（EXIFデータを除去して保存）
  Future<bool> takePhoto() async {
    if (state.length >= maxPhotos) return false;

    final picker = ImagePicker();
    try {
      final XFile? photo = await picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        // ファイル名で写真を識別・削除するため、衝突しないUUIDで命名する
        final directory = await PhotoStorage.documentsDirectory();
        final fileName = '${const Uuid().v4()}.jpg';
        final destPath = PhotoStorage.resolve(fileName, directory).path;

        final rawBytes = await File(photo.path).readAsBytes();
        final decoded = img.decodeImage(rawBytes);
        if (decoded == null) throw Exception('画像のデコードに失敗しました');

        // EXIFなしでJPEGとして再エンコード
        final cleanBytes = img.encodeJpg(decoded, quality: 95);
        final savedImage = await File(destPath).writeAsBytes(cleanBytes);

        state = [...state, savedImage];
        await _saveToStorage();
        return true;
      }
    } catch (e) {
      rethrow;
    }
    return false;
  }

  /// 保存完了後に写真をクリアする
  Future<void> clear() async {
    await _storage.delete(key: _storageKey);
    state = [];
  }
}

/// 撮影済み写真のProvider
final pendingPhotosProvider = NotifierProvider<PhotoNotifier, List<File>>(
  () => PhotoNotifier(),
);

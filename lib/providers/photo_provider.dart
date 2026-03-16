import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

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

  /// SecureStorageから写真パスを読み込む
  Future<void> _loadFromStorage() async {
    final json = await _storage.read(key: _storageKey);
    if (json != null) {
      final paths = List<String>.from(jsonDecode(json));
      state = paths.map((p) => File(p)).toList();
    }
  }

  /// SecureStorageに写真パスを保存する
  Future<void> _saveToStorage() async {
    final paths = state.map((f) => f.path).toList();
    await _storage.write(key: _storageKey, value: jsonEncode(paths));
  }

  /// SecureStorageから写真パスを再読み込みする（画面復帰時用）
  Future<void> reload() async {
    await _loadFromStorage();
  }

  /// カメラで写真を撮影して追加する
  Future<bool> takePhoto() async {
    if (state.length >= maxPhotos) return false;

    final picker = ImagePicker();
    try {
      final XFile? photo = await picker.pickImage(source: ImageSource.camera);
      if (photo != null) {
        final directory = await getApplicationDocumentsDirectory();
        final fileName = path.basename(photo.path);
        final savedImage =
            await File(photo.path).copy('${directory.path}/$fileName');

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

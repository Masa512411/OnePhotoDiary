import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

/// 撮影済み写真（pending_photos）を管理するNotifier
class PhotoNotifier extends Notifier<List<File>> {
  static const String _prefsKey = 'pending_photos';
  static const int maxPhotos = 3;

  @override
  List<File> build() {
    // 初期化時にSharedPreferencesから読み込む
    _loadFromPrefs();
    return [];
  }

  /// SharedPreferencesから写真パスを読み込む
  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? photoPaths = prefs.getStringList(_prefsKey);
    if (photoPaths != null && photoPaths.isNotEmpty) {
      state = photoPaths.map((p) => File(p)).toList();
    }
  }

  /// SharedPreferencesに写真パスを保存する
  Future<void> _saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final paths = state.map((f) => f.path).toList();
    await prefs.setStringList(_prefsKey, paths);
  }

  /// SharedPreferencesから写真パスを再読み込みする（画面復帰時用）
  Future<void> reload() async {
    await _loadFromPrefs();
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
        await _saveToPrefs();
        return true;
      }
    } catch (e) {
      // 呼び出し元でエラーハンドリング
      rethrow;
    }
    return false;
  }

  /// 保存完了後に写真をクリアする
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    state = [];
  }
}

/// 撮影済み写真のProvider
final pendingPhotosProvider = NotifierProvider<PhotoNotifier, List<File>>(
  () => PhotoNotifier(),
);

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../services/photo_storage.dart';
import 'diary_provider.dart';

/// 撮影済み写真（pending_photos）を管理するNotifier
class PhotoNotifier extends Notifier<List<File>> {
  static const String _storageKey = 'pending_photos';
  static const int maxPhotos = 3;

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 写真ファイル名 → 撮影日（yyyy-MM-dd）
  final Map<String, String> _captureDates = {};

  // 読み込みと変更を順番に実行するためのキュー
  // （読み込み中に撮影が完了すると、読み込み結果で新しい写真が上書きされるため）
  Future<void> _queue = Future.value();

  @override
  List<File> build() {
    // 前日以前の写真を破棄するのはアプリ起動時の読み込みだけ
    _serialized(() => _loadFromStorage(discardStale: true));
    return [];
  }

  String _todayKey() =>
      ref.read(clockProvider)().toIso8601String().substring(0, 10);

  /// 前の処理が終わってから[action]を実行する
  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// SecureStorageから写真を読み込む
  /// 保存値はファイル名（旧データは絶対パス）なので、現在のDocumentsディレクトリで解決する。
  /// [discardStale]がtrueなら、前日以前に撮影された写真は今日の候補ではないため、
  /// 一覧から外してファイルも削除する。
  Future<void> _loadFromStorage({required bool discardStale}) async {
    final json = await _storage.read(key: _storageKey);
    if (json == null) return;
    final documents = await PhotoStorage.documentsDirectory();
    final today = _todayKey();

    final kept = <String, String>{};
    final stale = <File>[];
    var changed = false;
    for (final item in jsonDecode(json) as List) {
      final String name;
      String? date;
      if (item is Map) {
        name = PhotoStorage.toStoredName(item['name'] as String);
        date = item['date'] as String?;
      } else {
        // 旧形式（絶対パスのみ・撮影日なし）はファイルの更新日時を撮影日とみなす
        name = PhotoStorage.toStoredName(item as String);
        changed = true;
      }
      final file = PhotoStorage.resolve(name, documents);
      if (!await file.exists()) {
        changed = true;
        continue;
      }
      date ??= (await file.lastModified()).toIso8601String().substring(0, 10);
      if (date == today || !discardStale) {
        kept[name] = date;
      } else {
        stale.add(file);
        changed = true;
      }
    }

    if (stale.isNotEmpty) {
      // 保存済みエントリが参照している写真は絶対に削除しない
      // （保存直後にpendingのクリア前でアプリが終了した場合など）
      await deletePhotosIfUnreferenced(stale);
    }

    _captureDates
      ..clear()
      ..addAll(kept);
    state = kept.keys.map((n) => PhotoStorage.resolve(n, documents)).toList();
    if (changed) await _saveToStorage();
  }

  /// SecureStorageに写真のファイル名と撮影日を保存する
  Future<void> _saveToStorage() async {
    final items = state.map((f) {
      final name = PhotoStorage.toStoredName(f.path);
      return {'name': name, 'date': _captureDates[name] ?? _todayKey()};
    }).toList();
    await _storage.write(key: _storageKey, value: jsonEncode(items));
  }

  /// SecureStorageから写真パスを再読み込みする（画面復帰時用）
  /// 撮影直後に日付が変わった写真を消さないよう、ここでは前日以前の写真も破棄しない
  Future<void> reload() =>
      _serialized(() => _loadFromStorage(discardStale: false));

  /// カメラで撮影、またはアルバムから選んだ画像のパスを返す
  /// アルバムからは残り枠ぶんまで複数選べる。残り枠を超えて選ばれた分（[limit]を
  /// 無視する端末がある）は取り込まず、その枚数を`skipped`で返す。
  /// 保存は時間がかかるため、呼び出し側で保存中の表示をしてから[addPhoto]を呼ぶ
  Future<({List<String> paths, int skipped})> pickPhoto({
    ImageSource source = ImageSource.camera,
  }) async {
    final remaining = maxPhotos - state.length;
    if (remaining <= 0) return (paths: <String>[], skipped: 0);

    final picker = ref.read(imagePickerProvider);
    // 保存時の変換処理を軽くするため、取得時にあらかじめ縮小する
    final size = maxPhotoDimension.toDouble();
    final List<XFile> photos;
    if (source == ImageSource.gallery && remaining >= 2) {
      // pickMultiImageのlimitは2以上でないと指定できない
      photos = await picker.pickMultiImage(
        maxWidth: size,
        maxHeight: size,
        imageQuality: 90,
        limit: remaining,
        // 写真ライブラリの権限を求めずに選べるよう、メタデータは要求しない
        requestFullMetadata: false,
      );
    } else {
      final photo = await picker.pickImage(
        source: source,
        maxWidth: size,
        maxHeight: size,
        imageQuality: 90,
        requestFullMetadata: false,
      );
      photos = [?photo];
    }

    final paths = photos.map((p) => p.path).toList();
    if (paths.length <= remaining) return (paths: paths, skipped: 0);
    return (
      paths: paths.sublist(0, remaining),
      skipped: paths.length - remaining,
    );
  }

  /// 撮影した画像をEXIFなしでDocumentsに保存し、撮影済み写真に追加する
  /// 上限に達している場合はnullを返す
  Future<File?> addPhoto(String sourcePath) => _serialized(() async {
    if (state.length >= maxPhotos) return null;

    // ファイル名で写真を識別・削除するため、衝突しないUUIDで命名する
    final directory = await PhotoStorage.documentsDirectory();
    final fileName = '${const Uuid().v4()}.jpg';
    final destPath = PhotoStorage.resolve(fileName, directory).path;

    final rawBytes = await File(sourcePath).readAsBytes();
    // デコード・エンコードは重いため、UIを止めないよう別isolateで行う
    final cleanBytes = await compute(processCapturedImage, rawBytes);
    final savedImage = await File(destPath).writeAsBytes(cleanBytes);

    _captureDates[fileName] = _todayKey();
    state = [...state, savedImage];
    await _saveToStorage();
    return savedImage;
  });

  /// 保存完了後に写真をクリアする
  /// 選ばれなかった写真のファイルも削除する。日記エントリの保存後に呼ばれるため、
  /// 選ばれた写真は保存済みエントリから参照されており削除対象にならない。
  Future<void> clear() => _serialized(() async {
    final documents = await PhotoStorage.documentsDirectory();
    final photos = [
      ...state,
      for (final name in await loadPendingPhotoNames())
        PhotoStorage.resolve(name, documents),
    ];

    await _storage.delete(key: _storageKey);
    _captureDates.clear();
    state = [];

    await deletePhotosIfUnreferenced(photos);
  });
}

/// 保存する写真の長辺の最大ピクセル数
const int maxPhotoDimension = 2048;

/// 撮影画像を保存用のJPEGに変換する（[compute]で別isolateから呼ばれる）
/// 向き（EXIF Orientation）を画素に焼き込んでから、位置情報などのEXIFをすべて除去する。
/// 長辺が[maxPhotoDimension]を超える場合は縮小する。
Uint8List processCapturedImage(Uint8List rawBytes) {
  final decoded = img.decodeImage(rawBytes);
  if (decoded == null) throw Exception('画像のデコードに失敗しました');

  var image = img.bakeOrientation(decoded);
  if (max(image.width, image.height) > maxPhotoDimension) {
    image = image.width >= image.height
        ? img.copyResize(image, width: maxPhotoDimension)
        : img.copyResize(image, height: maxPhotoDimension);
  }

  // encodeJpgは画像が持つEXIFをそのまま書き出すため、空にしてから保存する
  image.exif = img.ExifData();
  return img.encodeJpg(image, quality: 90);
}

/// 写真の取得に使うImagePickerのProvider（テストで差し替え可能にする）
final imagePickerProvider = Provider<ImagePicker>((ref) => ImagePicker());

/// 現在時刻のProvider（テストで日付の変わり目を再現できるよう差し替え可能にする）
final clockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// SecureStorageに保存されている撮影済み写真のファイル名一覧を返す
/// （新旧どちらの保存形式にも対応する）
Future<List<String>> loadPendingPhotoNames() async {
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  final json = await storage.read(key: PhotoNotifier._storageKey);
  if (json == null) return [];
  return [
    for (final item in jsonDecode(json) as List)
      PhotoStorage.toStoredName(
        item is Map ? item['name'] as String : item as String,
      ),
  ];
}

/// 撮影済み写真のProvider
final pendingPhotosProvider = NotifierProvider<PhotoNotifier, List<File>>(
  () => PhotoNotifier(),
);

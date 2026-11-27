import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';

import 'helpers/fake_documents.dart';

String _dateKey(DateTime d) => d.toIso8601String().substring(0, 10);

void main() {
  final today = _dateKey(DateTime.now());
  final yesterday = _dateKey(DateTime.now().subtract(const Duration(days: 1)));
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  /// PhotoNotifierを生成して読み込み完了まで待つ
  Future<PhotoNotifier> loadNotifier() async {
    final notifier = container.read(pendingPhotosProvider.notifier);
    await notifier.reload();
    return notifier;
  }

  Future<List<dynamic>> storedPending() async =>
      jsonDecode((await storage.read(key: 'pending_photos'))!) as List;

  group('PhotoNotifier 読み込み', () {
    test('今日撮った写真はファイル名で解決されて読み込まれる', () async {
      final documents = setUpFakeDocumentsDirectory();
      createPhoto(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'a.jpg', 'date': today},
        ]),
      });

      await loadNotifier();

      expect(container.read(pendingPhotosProvider).map((f) => f.path), [
        '${documents.path}/a.jpg',
      ]);
    });

    test('前日以前の写真は一覧から外れファイルも削除される', () async {
      final documents = setUpFakeDocumentsDirectory();
      final old = createPhoto(documents, 'old.jpg');
      createPhoto(documents, 'new.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'old.jpg', 'date': yesterday},
          {'name': 'new.jpg', 'date': today},
        ]),
      });

      await loadNotifier();

      expect(container.read(pendingPhotosProvider).map((f) => f.path), [
        '${documents.path}/new.jpg',
      ]);
      expect(old.existsSync(), isFalse);
      expect(await storedPending(), [
        {'name': 'new.jpg', 'date': today},
      ]);
    });

    test('前日以前の写真でも保存済みエントリが参照していれば削除しない', () async {
      final documents = setUpFakeDocumentsDirectory();
      final chosen = createPhoto(documents, 'chosen.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'chosen.jpg', 'date': yesterday},
        ]),
        'diary_dates': jsonEncode([yesterday]),
        'diary_$yesterday': jsonEncode({
          'photo': 'chosen.jpg',
          'caption': '',
          'date': yesterday,
        }),
      });

      await loadNotifier();

      expect(container.read(pendingPhotosProvider), isEmpty);
      expect(chosen.existsSync(), isTrue);
    });

    test('旧形式（絶対パスのみ）は更新日時を撮影日とみなして移行する', () async {
      final documents = setUpFakeDocumentsDirectory();
      createPhoto(documents, 'legacy_today.jpg');
      final legacyOld = createPhoto(documents, 'legacy_old.jpg')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          '/var/mobile/Containers/Data/Application/OLD/Documents/legacy_today.jpg',
          '/var/mobile/Containers/Data/Application/OLD/Documents/legacy_old.jpg',
          '/var/mobile/Containers/Data/Application/OLD/Documents/missing.jpg',
        ]),
      });

      await loadNotifier();

      expect(container.read(pendingPhotosProvider).map((f) => f.path), [
        '${documents.path}/legacy_today.jpg',
      ]);
      expect(legacyOld.existsSync(), isFalse);
      expect(await storedPending(), [
        {'name': 'legacy_today.jpg', 'date': today},
      ]);
    });
  });

  group('PhotoNotifier.clear', () {
    test('保存後のクリアで未選択の写真だけが削除される', () async {
      final documents = setUpFakeDocumentsDirectory();
      final chosen = createPhoto(documents, 'chosen.jpg');
      final other1 = createPhoto(documents, 'other1.jpg');
      final other2 = createPhoto(documents, 'other2.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'chosen.jpg', 'date': today},
          {'name': 'other1.jpg', 'date': today},
          {'name': 'other2.jpg', 'date': today},
        ]),
      });
      final notifier = await loadNotifier();
      container.read(diaryProvider);
      await pumpEventQueue();

      // エディタ画面と同じ順序: エントリ保存 → pendingクリア
      await container
          .read(diaryProvider.notifier)
          .saveEntry(
            photo: container.read(pendingPhotosProvider).first,
            caption: '',
          );
      await notifier.clear();

      expect(container.read(pendingPhotosProvider), isEmpty);
      expect(await storage.read(key: 'pending_photos'), isNull);
      expect(chosen.existsSync(), isTrue);
      expect(other1.existsSync(), isFalse);
      expect(other2.existsSync(), isFalse);
    });

    test('過去の保存済みエントリが参照する写真は削除しない', () async {
      final documents = setUpFakeDocumentsDirectory();
      final saved = createPhoto(documents, 'saved.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'saved.jpg', 'date': today},
        ]),
        'diary_dates': jsonEncode([yesterday]),
        'diary_$yesterday': jsonEncode({
          'photo': '/old/path/saved.jpg',
          'caption': '',
          'date': yesterday,
        }),
      });
      final notifier = await loadNotifier();

      await notifier.clear();

      expect(saved.existsSync(), isTrue);
    });
  });
}

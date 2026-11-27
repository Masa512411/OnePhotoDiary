import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';

import 'helpers/fake_documents.dart';

void main() {
  late ProviderContainer container;
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  group('DiaryEntry', () {
    test('toJsonは写真をファイル名のみで保存する', () {
      final documents = setUpFakeDocumentsDirectory();
      final entry = DiaryEntry(
        photo: createPhoto(documents, 'a.jpg'),
        caption: 'test',
        date: '2026-11-28',
      );

      expect(entry.toJson()['photo'], 'a.jpg');
    });

    test('旧データの絶対パスは現在のDocumentsディレクトリで解決される', () async {
      final documents = setUpFakeDocumentsDirectory();
      createPhoto(documents, 'old.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-27']),
        'diary_2026-11-27': jsonEncode({
          'photo':
              '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/old.jpg',
          'caption': '昔のエントリ',
          'date': '2026-11-27',
        }),
      });

      // autoDisposeのため、読み込み中に破棄されないようlistenしておく
      final sub = container.listen(diaryEntryProvider('2026-11-27'), (_, _) {});
      addTearDown(sub.close);
      final entry = await container.read(
        diaryEntryProvider('2026-11-27').future,
      );

      expect(entry!.photo.path, '${documents.path}/old.jpg');
      expect(entry.photo.existsSync(), isTrue);
    });

    test('全エントリ取得でもファイル名がDocumentsディレクトリで解決される', () async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26', '2026-11-27']),
        'diary_2026-11-26': jsonEncode({
          'photo': '/old/path/a.jpg',
          'caption': '',
          'date': '2026-11-26',
        }),
        'diary_2026-11-27': jsonEncode({
          'photo': 'b.jpg',
          'caption': '',
          'date': '2026-11-27',
        }),
      });
      // diaryProviderの読み込み完了を待つ
      container.read(diaryProvider);
      await pumpEventQueue();

      final entries = await container.read(allDiaryEntriesProvider.future);

      expect(entries.map((e) => e.photo.path), [
        '${documents.path}/b.jpg',
        '${documents.path}/a.jpg',
      ]);
    });

    test('loadReferencedPhotoNamesは保存済みエントリの写真ファイル名を返す', () async {
      setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26', '2026-11-27']),
        'diary_2026-11-26': jsonEncode({
          'photo': '/old/path/a.jpg',
          'caption': '',
          'date': '2026-11-26',
        }),
        'diary_2026-11-27': jsonEncode({
          'photo': 'b.jpg',
          'caption': '',
          'date': '2026-11-27',
        }),
      });

      expect(await loadReferencedPhotoNames(), {'a.jpg', 'b.jpg'});
    });
  });

  group('DiaryNotifier.saveEntry（同じ日の上書き）', () {
    final today = DateTime.now().toIso8601String().substring(0, 10);

    Future<void> saveOver(Map<String, String> initial) async {
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode([today]),
        'diary_$today': jsonEncode({
          'photo': 'old.jpg',
          'caption': '',
          'date': today,
        }),
        ...initial,
      });
      container.read(diaryProvider);
      await pumpEventQueue();
    }

    test('写真を変えて上書きすると前の写真ファイルが削除される', () async {
      final documents = setUpFakeDocumentsDirectory();
      final old = createPhoto(documents, 'old.jpg');
      final next = createPhoto(documents, 'new.jpg');
      await saveOver({});

      await container
          .read(diaryProvider.notifier)
          .saveEntry(photo: next, caption: '2回目');

      expect(old.existsSync(), isFalse);
      expect(next.existsSync(), isTrue);
      expect(await loadReferencedPhotoNames(), {'new.jpg'});
    });

    test('同じ写真のまま上書きしても写真は削除されない', () async {
      final documents = setUpFakeDocumentsDirectory();
      final old = createPhoto(documents, 'old.jpg');
      await saveOver({});

      await container
          .read(diaryProvider.notifier)
          .saveEntry(photo: old, caption: '書き直し');

      expect(old.existsSync(), isTrue);
    });

    test('前の写真を他の日のエントリや撮影済み写真が参照していれば削除しない', () async {
      final documents = setUpFakeDocumentsDirectory();
      final old = createPhoto(documents, 'old.jpg');
      final next = createPhoto(documents, 'new.jpg');
      await saveOver({
        'diary_dates': jsonEncode(['2026-01-01', today]),
        'diary_2026-01-01': jsonEncode({
          'photo': 'old.jpg',
          'caption': '',
          'date': '2026-01-01',
        }),
      });

      await container
          .read(diaryProvider.notifier)
          .saveEntry(photo: next, caption: '');
      expect(old.existsSync(), isTrue);

      // 撮影済み写真として残っている場合
      final other = createPhoto(documents, 'other.jpg');
      await storage.write(
        key: 'pending_photos',
        value: jsonEncode([
          {'name': 'new.jpg', 'date': today},
        ]),
      );
      await container
          .read(diaryProvider.notifier)
          .saveEntry(photo: other, caption: '');
      expect(next.existsSync(), isTrue);
    });
  });
}

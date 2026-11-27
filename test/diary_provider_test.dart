import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';

import 'helpers/fake_documents.dart';

void main() {
  late ProviderContainer container;

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
          'photo': '/var/mobile/Containers/Data/Application/OLD-UUID/Documents/old.jpg',
          'caption': '昔のエントリ',
          'date': '2026-11-27',
        }),
      });

      // autoDisposeのため、読み込み中に破棄されないようlistenしておく
      final sub = container.listen(diaryEntryProvider('2026-11-27'), (_, _) {});
      addTearDown(sub.close);
      final entry =
          await container.read(diaryEntryProvider('2026-11-27').future);

      expect(entry!.photo.path, '${documents.path}/old.jpg');
      expect(entry.photo.existsSync(), isTrue);
    });

    test('全エントリ取得でもファイル名がDocumentsディレクトリで解決される', () async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26', '2026-11-27']),
        'diary_2026-11-26': jsonEncode(
            {'photo': '/old/path/a.jpg', 'caption': '', 'date': '2026-11-26'}),
        'diary_2026-11-27': jsonEncode(
            {'photo': 'b.jpg', 'caption': '', 'date': '2026-11-27'}),
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
        'diary_2026-11-26': jsonEncode(
            {'photo': '/old/path/a.jpg', 'caption': '', 'date': '2026-11-26'}),
        'diary_2026-11-27': jsonEncode(
            {'photo': 'b.jpg', 'caption': '', 'date': '2026-11-27'}),
      });

      expect(await loadReferencedPhotoNames(), {'a.jpg', 'b.jpg'});
    });
  });
}

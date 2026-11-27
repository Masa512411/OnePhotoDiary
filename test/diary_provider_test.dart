import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';

import 'helpers/fake_documents.dart';
import 'helpers/fake_secure_storage.dart';

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

  group('DiaryNotifier（日付一覧の読み込み・保存）', () {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    late FakeSecureStorage fakeStorage;

    Map<String, String> entryOf(String date, String photo) => {
          'diary_$date': jsonEncode({
            'photo': photo,
            'caption': '',
            'date': date,
          }),
        };

    Future<Set<String>> storedDates() async => Set<String>.from(
          jsonDecode((await storage.read(key: 'diary_dates'))!) as List,
        );

    /// FakeSecureStorageを使うコンテナを作り直す
    void useFakeStorage(Map<String, String> initial) {
      FlutterSecureStorage.setMockInitialValues(initial);
      fakeStorage = FakeSecureStorage();
      container = ProviderContainer(
        overrides: [diaryStorageProvider.overrideWithValue(fakeStorage)],
      );
      addTearDown(container.dispose);
    }

    void simulateResume() {
      final binding = TestWidgetsFlutterBinding.instance;
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
    }

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    test('読み込み完了前に保存しても保存済みの日付を消さない', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        'diary_dates': jsonEncode(['2026-01-01', '2026-01-02']),
        ...entryOf('2026-01-01', 'a.jpg'),
        ...entryOf('2026-01-02', 'b.jpg'),
      });

      // 読み込みを待たずに保存する（メモリ上の状態は空）
      expect(container.read(diaryProvider).datesWithEntries, isEmpty);
      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'c.jpg'),
            caption: '',
          );

      final expected = {'2026-01-01', '2026-01-02', today};
      expect(await storedDates(), expected);
      expect(container.read(diaryProvider).datesWithEntries, expected);
      // 遅れて完了した読み込みでも今日の日付は消えない
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, expected);
    });

    test('読み込みに失敗した後に保存しても保存済みの日付を消さない', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        'diary_dates': jsonEncode(['2026-01-01']),
        ...entryOf('2026-01-01', 'a.jpg'),
      });
      fakeStorage.failRead('diary_dates', times: 1);

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, isEmpty);

      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'b.jpg'),
            caption: '',
          );

      expect(await storedDates(), {'2026-01-01', today});
      expect(
        container.read(diaryProvider).datesWithEntries,
        {'2026-01-01', today},
      );
    });

    test('保存時に日付一覧を読めなければ何も書き込まずに失敗する', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        'diary_dates': jsonEncode(['2026-01-01']),
        ...entryOf('2026-01-01', 'a.jpg'),
      });
      fakeStorage.failRead('diary_dates');

      container.read(diaryProvider);
      await pumpEventQueue();

      await expectLater(
        container.read(diaryProvider.notifier).saveEntry(
              photo: createPhoto(documents, 'b.jpg'),
              caption: '',
            ),
        throwsException,
      );
      expect(fakeStorage.writtenKeys, isEmpty);
      expect(await storage.read(key: 'diary_$today'), isNull);
      expect(await storedDates(), {'2026-01-01'});
    });

    test('読み込みに失敗しても例外を出さず、復帰時に再読み込みする', () async {
      useFakeStorage({
        'diary_dates': jsonEncode(['2026-01-01']),
        ...entryOf('2026-01-01', 'a.jpg'),
      });
      fakeStorage.failRead('diary_dates', times: 1);

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, isEmpty);

      simulateResume();
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, {'2026-01-01'});
    });

    test('読み込みに成功していれば復帰時に再読み込みしない', () async {
      useFakeStorage({'diary_dates': jsonEncode(['2026-01-01'])});

      container.read(diaryProvider);
      await pumpEventQueue();
      await storage.write(
        key: 'diary_dates',
        value: jsonEncode(['2026-01-01', '2026-01-02']),
      );

      simulateResume();
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, {'2026-01-01'});
    });

    test('hasEntryTodayはメモリ上の状態ではなくストレージを確認する', () async {
      useFakeStorage(entryOf(today, 'a.jpg'));
      fakeStorage.failRead('diary_dates');

      container.read(diaryProvider);
      await pumpEventQueue();

      expect(container.read(diaryProvider).hasEntryToday, isFalse);
      expect(
        await container.read(diaryProvider.notifier).hasEntryToday(),
        isTrue,
      );
    });

    test('日付一覧が無ければ残っているエントリのキーから復元する', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        ...entryOf('2026-01-01', 'a.jpg'),
        ...entryOf('2026-01-02', 'b.jpg'),
        'pending_photos': jsonEncode([]),
        'reminder_enabled': 'true',
        'diary_invalid': 'x',
      });

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(
        container.read(diaryProvider).datesWithEntries,
        {'2026-01-01', '2026-01-02'},
      );

      // 保存時も復元した日付を一覧に含める
      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'c.jpg'),
            caption: '',
          );
      expect(await storedDates(), {'2026-01-01', '2026-01-02', today});
    });

    test('日付一覧が空でも残っているエントリのキーから復元する', () async {
      useFakeStorage({
        'diary_dates': jsonEncode([]),
        ...entryOf('2026-01-01', 'a.jpg'),
      });

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, {'2026-01-01'});
    });

    test('復元に失敗しても日付一覧が無ければ保存できる', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({});
      fakeStorage.failReadAll = true;

      container.read(diaryProvider);
      await pumpEventQueue();
      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'a.jpg'),
            caption: '',
          );

      expect(await storedDates(), {today});
      expect(container.read(diaryProvider).datesWithEntries, {today});
    });

    test('一覧が1日分しかなくても残っているエントリのキーから全て復元する', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        // このバグで一覧が保存した日だけに上書きされた状態
        'diary_dates': jsonEncode(['2026-01-03']),
        ...entryOf('2026-01-01', 'a.jpg'),
        ...entryOf('2026-01-02', 'b.jpg'),
        ...entryOf('2026-01-03', 'c.jpg'),
        'pending_photos': jsonEncode([]),
        'reminder_enabled': 'true',
      });

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(
        container.read(diaryProvider).datesWithEntries,
        {'2026-01-01', '2026-01-02', '2026-01-03'},
      );

      // 保存時に修復した一覧が書き込まれる
      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'd.jpg'),
            caption: '',
          );
      expect(
        await storedDates(),
        {'2026-01-01', '2026-01-02', '2026-01-03', today},
      );
    });

    test('復元に失敗しても保存済みの一覧は読み込み・保存に使われる', () async {
      final documents = setUpFakeDocumentsDirectory();
      useFakeStorage({
        'diary_dates': jsonEncode(['2026-01-01']),
        ...entryOf('2026-01-01', 'a.jpg'),
      });
      fakeStorage.failReadAll = true;

      container.read(diaryProvider);
      await pumpEventQueue();
      expect(container.read(diaryProvider).datesWithEntries, {'2026-01-01'});

      await container.read(diaryProvider.notifier).saveEntry(
            photo: createPhoto(documents, 'b.jpg'),
            caption: '',
          );
      expect(await storedDates(), {'2026-01-01', today});
    });
  });
}

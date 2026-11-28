import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:one_photo_diary/providers/diary_provider.dart';
import 'package:one_photo_diary/services/backup_service.dart';

import 'helpers/fake_documents.dart';
import 'helpers/fake_secure_storage.dart';

/// 画像として読めるJPEGのバイト列
List<int> _jpeg() => img.encodeJpg(img.Image(width: 4, height: 4));

/// Documentsディレクトリに読める写真を作成する
File _createJpeg(Directory documents, String name) =>
    File('${documents.path}/$name')..writeAsBytesSync(_jpeg());

String _entryJson(String date, String photo, String caption) =>
    jsonEncode({'photo': photo, 'caption': caption, 'date': date});

String _dateKey(DateTime d) => d.toIso8601String().substring(0, 10);

/// 削除の失敗も再現できるストレージ（復元の取り消しの失敗を再現するため）
class _FailingDeleteStorage extends FakeSecureStorage {
  final Set<String> deleteFailures = {};

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (deleteFailures.contains(key)) throw Exception('削除失敗: $key');
    return super.delete(key: key);
  }
}

void main() {
  late Directory documents;
  late Directory outputDir;
  late _FailingDeleteStorage storage;
  late ProviderContainer container;

  setUp(() {
    documents = setUpFakeDocumentsDirectory();
    outputDir = Directory.systemTemp.createTempSync('backup_output_');
    addTearDown(() {
      if (outputDir.existsSync()) outputDir.deleteSync(recursive: true);
    });
    storage = _FailingDeleteStorage();
    container = ProviderContainer(
      overrides: [diaryStorageProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
  });

  /// DiaryNotifierを生成して読み込み完了まで待つ
  Future<DiaryNotifier> loadNotifier() async {
    final notifier = container.read(diaryProvider.notifier);
    await pumpEventQueue();
    return notifier;
  }

  /// 任意のmanifestと写真でzipを作る
  File writeZip(Object? manifest, {Map<String, List<int>> photos = const {}}) {
    final archive = Archive();
    if (manifest != null) {
      archive.add(ArchiveFile.string(
        'manifest.json',
        manifest is String ? manifest : jsonEncode(manifest),
      ));
    }
    for (final MapEntry(:key, :value) in photos.entries) {
      archive.add(ArchiveFile.bytes(key, value));
    }
    final file = File('${outputDir.path}/test.zip');
    file.writeAsBytesSync(ZipEncoder().encode(archive));
    return file;
  }

  Map<String, dynamic> manifestOf(List<Map<String, dynamic>> entries) => {
        'format': 'one_photo_diary_backup',
        'version': 1,
        'exportedAt': '2026-11-28T10:00:00.000',
        'entries': entries,
      };

  Future<void> restore(BackupContents contents, DiaryNotifier notifier) =>
      BackupService.restoreBackup(
        contents,
        documents: documents,
        storage: storage,
        importEntries: notifier.importEntries,
      );

  /// 2件（11/26: photos/a.jpg、11/27: photos/b.jpg）のバックアップを読み込む
  Future<BackupContents> readTwoEntries() async =>
      BackupService.readBackup(writeZip(
        manifestOf([
          {'date': '2026-11-26', 'caption': '一件目', 'photo': 'photos/a.jpg'},
          {'date': '2026-11-27', 'caption': '二件目', 'photo': 'photos/b.jpg'},
        ]),
        photos: {'photos/a.jpg': _jpeg(), 'photos/b.jpg': _jpeg()},
      ).path);

  Set<String> documentNames() => {
        for (final f in documents.listSync().whereType<File>())
          f.uri.pathSegments.last,
      };

  group('書き出し', () {
    test('全エントリと写真をmanifest付きのzipに書き出す', () async {
      _createJpeg(documents, 'a.jpg');
      _createJpeg(documents, 'b.jpg');
      FlutterSecureStorage.setMockInitialValues({
        // 一覧から漏れた日付（キーだけ残っている）も書き出す
        'diary_dates': jsonEncode(['2026-11-26']),
        'diary_2026-11-26': _entryJson('2026-11-26', 'a.jpg', '一日目'),
        'diary_2026-11-27': _entryJson('2026-11-27', '/old/path/b.jpg', '二日目'),
        'pending_photos': jsonEncode([]),
      });

      final result = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
        now: DateTime(2026, 11, 28, 10),
      );

      expect(result.entryCount, 2);
      expect(result.skippedCount, 0);
      expect(result.complete, isTrue);
      final archive = ZipDecoder().decodeBytes(result.file!.readAsBytesSync());
      final manifest = jsonDecode(
              utf8.decode(archive.find('manifest.json')!.readBytes()!))
          as Map<String, dynamic>;
      expect(manifest['format'], 'one_photo_diary_backup');
      expect(manifest['version'], 1);
      expect(manifest['exportedAt'], '2026-11-28T10:00:00.000');
      expect(manifest['entries'], [
        {'date': '2026-11-26', 'caption': '一日目', 'photo': 'photos/a.jpg'},
        {'date': '2026-11-27', 'caption': '二日目', 'photo': 'photos/b.jpg'},
      ]);
      expect(archive.find('photos/a.jpg')!.readBytes(), _jpeg());
      expect(archive.find('photos/b.jpg'), isNotNull);
    });

    test('写真ファイルが無い・壊れたエントリは書き出さず件数を返す', () async {
      _createJpeg(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_2026-11-26': _entryJson('2026-11-26', 'a.jpg', ''),
        'diary_2026-11-27': _entryJson('2026-11-27', 'missing.jpg', ''),
        'diary_2026-11-28': 'not json',
      });

      final result = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
      );

      expect(result.entryCount, 1);
      expect(result.skippedCount, 2);
    });

    test('キーを確認できなくても、日付一覧の日記は書き出して不完全と示す', () async {
      _createJpeg(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26']),
        'diary_2026-11-26': _entryJson('2026-11-26', 'a.jpg', ''),
      });
      storage.failReadAll = true;

      final result = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
      );

      expect(result.entryCount, 1);
      expect(result.complete, isFalse);
      expect(result.file!.existsSync(), isTrue);
    });

    test('日付一覧も壊れていて日記が分からない場合は失敗し、zipを作らない', () async {
      FlutterSecureStorage.setMockInitialValues({'diary_dates': 'broken'});
      storage.failReadAll = true;

      await expectLater(
        BackupService.exportBackup(
          storage: storage,
          documents: documents,
          outputDir: outputDir,
        ),
        throwsException,
      );
      expect(outputDir.listSync(), isEmpty);
    });

    test('書き出せる日記が無ければzipを作らず、前回のzipも消さない', () async {
      final old = File(
          '${outputDir.path}/${BackupService.fileNamePrefix}20260101_000000.zip')
        ..writeAsStringSync('old');
      FlutterSecureStorage.setMockInitialValues({});

      final result = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
      );

      expect(result.file, isNull);
      expect(result.entryCount, 0);
      expect(outputDir.listSync().map((e) => e.path), [old.path]);
    });

    test('前回書き出したzipは次の書き出し時に片付ける', () async {
      final old = File(
          '${outputDir.path}/${BackupService.fileNamePrefix}20260101_000000.zip')
        ..writeAsStringSync('old');
      final other = File('${outputDir.path}/other.zip')
        ..writeAsStringSync('keep');
      _createJpeg(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_2026-11-26': _entryJson('2026-11-26', 'a.jpg', ''),
      });

      final result = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
        now: DateTime(2026, 11, 28),
      );

      expect(old.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(result.file!.existsSync(), isTrue);
    });

    test('起動時などの片付けでは、一定時間より前の書き出しだけを消す', () async {
      final now = DateTime(2026, 11, 28, 12);
      final shareDir = Directory('${outputDir.path}/share_plus')..createSync();
      File makeZip(Directory dir, String name, DateTime modified) =>
          File('${dir.path}/${BackupService.fileNamePrefix}$name.zip')
            ..writeAsStringSync('zip')
            ..setLastModifiedSync(modified);
      final stale = makeZip(outputDir, 'stale', DateTime(2026, 11, 28, 10));
      final staleCopy = makeZip(shareDir, 'stale', DateTime(2026, 11, 28, 10));
      final recent = makeZip(outputDir, 'recent', DateTime(2026, 11, 28, 11, 30));
      final unrelated = File('${outputDir.path}/other.zip')
        ..writeAsStringSync('keep')
        ..setLastModifiedSync(DateTime(2026, 1, 1));

      await BackupService.deleteOldExports(
        outputDir,
        olderThan: const Duration(hours: 1),
        now: now,
      );

      expect(stale.existsSync(), isFalse);
      expect(staleCopy.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      expect(unrelated.existsSync(), isTrue);
    });
  });

  group('読み込み・検証', () {
    Future<Object?> readError(File zip, {int? maxPhotoBytes}) async {
      try {
        await BackupService.readBackup(
          zip.path,
          maxPhotoBytes: maxPhotoBytes ?? BackupService.maxPhotoBytes,
        );
        return null;
      } catch (e) {
        return e;
      }
    }

    test('zipではないファイルは壊れているものとして扱う', () async {
      final file = File('${outputDir.path}/broken.zip')
        ..writeAsBytesSync(List.generate(256, (i) => i));

      expect(await readError(file), isA<BackupFormatException>());
    });

    test('manifestが無い・形式が違うzipは受け付けない', () async {
      expect(await readError(writeZip(null)), isA<BackupFormatException>());
      expect(await readError(writeZip('not json')),
          isA<BackupFormatException>());
      expect(
        await readError(writeZip({...manifestOf([]), 'format': 'other'})),
        isA<BackupFormatException>(),
      );
    });

    test('新しいバージョンのバックアップは更新を促す', () async {
      final error =
          await readError(writeZip({...manifestOf([]), 'version': 2}));

      expect(error, isA<BackupFormatException>());
      expect((error as BackupFormatException).message, contains('更新'));
    });

    test('写真がzipに含まれていなければ受け付けない', () async {
      final zip = writeZip(manifestOf([
        {'date': '2026-11-26', 'caption': '', 'photo': 'photos/a.jpg'},
      ]));

      expect(await readError(zip), isA<BackupFormatException>());
    });

    test('展開後サイズが上限を超える写真は受け付けない', () async {
      final zip = writeZip(
        manifestOf([
          {'date': '2026-11-26', 'caption': '', 'photo': 'photos/a.jpg'},
        ]),
        photos: {'photos/a.jpg': _jpeg()},
      );

      final error = await readError(zip, maxPhotoBytes: 10);

      expect(error, isA<BackupFormatException>());
      expect((error as BackupFormatException).message, contains('大きすぎる'));
    });

    test('不正な日付・写真のパス・重複した日付は受け付けない', () async {
      Future<Object?> errorFor(List<Map<String, dynamic>> entries) =>
          readError(writeZip(manifestOf(entries), photos: {
            'photos/a.jpg': _jpeg(),
            'a.jpg': _jpeg(),
          }));

      for (final date in ['dates', '2026-13-01', '2026-02-30', '2026-1-01']) {
        expect(
          await errorFor([
            {'date': date, 'caption': '', 'photo': 'photos/a.jpg'},
          ]),
          isA<BackupFormatException>(),
          reason: date,
        );
      }
      for (final photo in ['a.jpg', 'photos/../a.jpg', 'photos/', 'x/a.jpg']) {
        expect(
          await errorFor([
            {'date': '2026-11-26', 'caption': '', 'photo': photo},
          ]),
          isA<BackupFormatException>(),
          reason: photo,
        );
      }
      expect(
        await errorFor([
          {'date': '2026-11-26', 'caption': '', 'photo': 'photos/a.jpg'},
          {'date': '2026-11-26', 'caption': '', 'photo': 'photos/a.jpg'},
        ]),
        isA<BackupFormatException>(),
      );
    });

    test('未来の日付のエントリは除き、件数を返す', () async {
      final today = _dateKey(DateTime.now());
      final tomorrow = _dateKey(DateTime.now().add(const Duration(days: 1)));
      final contents = await BackupService.readBackup(writeZip(
        manifestOf([
          {'date': today, 'caption': '', 'photo': 'photos/a.jpg'},
          {'date': tomorrow, 'caption': '', 'photo': 'photos/a.jpg'},
        ]),
        photos: {'photos/a.jpg': _jpeg()},
      ).path);

      expect(contents.entries.map((e) => e.date), [today]);
      expect(contents.skippedFutureCount, 1);
    });

    test('保存済みと日付が重なる件数を数える', () async {
      FlutterSecureStorage.setMockInitialValues({
        'diary_2026-11-26': _entryJson('2026-11-26', 'x.jpg', ''),
      });
      final contents = await readTwoEntries();

      expect(contents.entries.length, 2);
      expect(await BackupService.countOverlapping(contents, storage), 1);
    });
  });

  group('復元', () {
    test('書き出したバックアップを別端末で復元できる', () async {
      _createJpeg(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26']),
        'diary_2026-11-26': _entryJson('2026-11-26', 'a.jpg', '書き出し元'),
      });
      final exported = await BackupService.exportBackup(
        storage: storage,
        documents: documents,
        outputDir: outputDir,
      );
      // 別端末（空の状態）を再現する
      File('${documents.path}/a.jpg').deleteSync();
      FlutterSecureStorage.setMockInitialValues({});
      final notifier = await loadNotifier();

      await restore(
          await BackupService.readBackup(exported.file!.path), notifier);

      expect(container.read(diaryProvider).datesWithEntries, {'2026-11-26'});
      final sub = container.listen(diaryEntryProvider('2026-11-26'), (_, _) {});
      addTearDown(sub.close);
      final entry =
          await container.read(diaryEntryProvider('2026-11-26').future);
      expect(entry!.caption, '書き出し元');
      // 写真は新しい名前でDocumentsに保存される
      expect(entry.photo.existsSync(), isTrue);
      expect(entry.photo.path, isNot(endsWith('/a.jpg')));
      expect(jsonDecode((await storage.read(key: 'diary_dates'))!),
          ['2026-11-26']);
    });

    test('同じ日付は上書きし、それ以外は追加・既存は残す', () async {
      _createJpeg(documents, 'old.jpg');
      _createJpeg(documents, 'keep.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-25', '2026-11-26']),
        'diary_2026-11-25': _entryJson('2026-11-25', 'keep.jpg', '既存'),
        'diary_2026-11-26': _entryJson('2026-11-26', 'old.jpg', '上書き前'),
      });
      final notifier = await loadNotifier();
      // 上書き前の表示を読み込んでおく（復元後に更新されることを確認する）
      final sub = container.listen(diaryEntryProvider('2026-11-26'), (_, _) {});
      addTearDown(sub.close);
      expect(
          (await container.read(diaryEntryProvider('2026-11-26').future))!
              .caption,
          '上書き前');

      await restore(await readTwoEntries(), notifier);

      expect(container.read(diaryProvider).datesWithEntries,
          {'2026-11-25', '2026-11-26', '2026-11-27'});
      expect(
          (await container.read(diaryEntryProvider('2026-11-26').future))!
              .caption,
          '一件目');
      // 上書きで使われなくなった写真は削除し、既存のエントリの写真は残す
      expect(File('${documents.path}/old.jpg').existsSync(), isFalse);
      expect(File('${documents.path}/keep.jpg').existsSync(), isTrue);
      expect(
          jsonDecode((await storage.read(key: 'diary_2026-11-25'))!)['caption'],
          '既存');
    });

    test('上書き前の写真が撮影済み写真として残っていれば削除しない', () async {
      _createJpeg(documents, 'old.jpg');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26']),
        'diary_2026-11-26': _entryJson('2026-11-26', 'old.jpg', ''),
        'pending_photos': jsonEncode(['old.jpg']),
      });
      final notifier = await loadNotifier();

      await restore(await readTwoEntries(), notifier);

      expect(File('${documents.path}/old.jpg').existsSync(), isTrue);
    });

    test('未来の日付は何も書き込まずに拒否する', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final notifier = await loadNotifier();
      final tomorrow = _dateKey(DateTime.now().add(const Duration(days: 1)));

      await expectLater(
        notifier.importEntries([
          DiaryEntry(
              photo: File('${documents.path}/a.jpg'),
              caption: '',
              date: tomorrow),
        ]),
        throwsArgumentError,
      );
      expect(storage.writtenKeys, isEmpty);
    });

    test('読めない写真が含まれていれば何も保存せず、保存した写真も片付ける', () async {
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-25']),
        'diary_2026-11-25': _entryJson('2026-11-25', 'keep.jpg', '既存'),
      });
      _createJpeg(documents, 'keep.jpg');
      final notifier = await loadNotifier();
      final contents = await BackupService.readBackup(writeZip(
        manifestOf([
          {'date': '2026-11-26', 'caption': '', 'photo': 'photos/a.jpg'},
          {'date': '2026-11-27', 'caption': '', 'photo': 'photos/b.jpg'},
        ]),
        photos: {'photos/a.jpg': _jpeg(), 'photos/b.jpg': [1, 2, 3]},
      ).path);

      await expectLater(
          restore(contents, notifier), throwsA(isA<BackupFormatException>()));

      expect(documentNames(), {'keep.jpg'});
      expect(storage.writtenKeys, isEmpty);
      expect(container.read(diaryProvider).datesWithEntries, {'2026-11-25'});
    });

    test('画素数が上限を超える写真はデコードせずに拒否する', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final notifier = await loadNotifier();
      final contents = await readTwoEntries();

      // テスト用の写真は4×4=16画素
      final future = BackupService.restoreBackup(
        contents,
        documents: documents,
        storage: storage,
        importEntries: notifier.importEntries,
        maxPhotoPixels: 15,
      );

      await expectLater(
        future,
        throwsA(isA<BackupFormatException>().having(
            (e) => e.message, 'message', contains('大きすぎる'))),
      );
      expect(documentNames(), isEmpty);
      expect(storage.writtenKeys, isEmpty);
    });

    test('書き込みが途中で失敗したら、書き込んだ分を元に戻し写真も片付ける', () async {
      _createJpeg(documents, 'keep.jpg');
      final originalDates = jsonEncode(['2026-11-25']);
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': originalDates,
        'diary_2026-11-25': _entryJson('2026-11-25', 'keep.jpg', '既存'),
      });
      final notifier = await loadNotifier();
      storage.writeFailures.add('diary_2026-11-27');

      await expectLater(
          restore(await readTwoEntries(), notifier), throwsException);
      await pumpEventQueue();

      // 書き込み済みだった1件目も取り消され、復元した写真はすべて削除される
      expect(await storage.read(key: 'diary_2026-11-26'), isNull);
      expect(await storage.read(key: 'diary_dates'), originalDates);
      expect(documentNames(), {'keep.jpg'});
      expect(container.read(diaryProvider).datesWithEntries, {'2026-11-25'});
    });

    test('上書きした既存の日記も、失敗時は元の内容に戻る', () async {
      _createJpeg(documents, 'old.jpg');
      final original = _entryJson('2026-11-26', 'old.jpg', '上書き前');
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-26']),
        'diary_2026-11-26': original,
      });
      final notifier = await loadNotifier();
      storage.writeFailures.add('diary_dates');

      await expectLater(
          restore(await readTwoEntries(), notifier), throwsException);
      await pumpEventQueue();

      expect(await storage.read(key: 'diary_2026-11-26'), original);
      expect(await storage.read(key: 'diary_2026-11-27'), isNull);
      // 元のエントリが参照する写真は残り、復元した写真は削除される
      expect(documentNames(), {'old.jpg'});
    });

    test('無関係な壊れたエントリがあっても、失敗時に復元した写真を片付ける', () async {
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-11-20']),
        'diary_2026-11-20': 'broken',
      });
      final notifier = await loadNotifier();
      storage.writeFailures.add('diary_2026-11-27');

      await expectLater(
          restore(await readTwoEntries(), notifier), throwsException);

      expect(documentNames(), isEmpty);
    });

    test('元に戻すことにも失敗したら、残ったエントリの写真は消さない', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final notifier = await loadNotifier();
      storage.writeFailures.add('diary_2026-11-27');
      storage.deleteFailures.add('diary_2026-11-26');

      await expectLater(restore(await readTwoEntries(), notifier),
          throwsA(isA<DiaryImportRollbackException>()));
      await pumpEventQueue();

      // 取り消せなかった1件目は残り、その写真も残る。2件目の写真は削除される
      final first =
          jsonDecode((await storage.read(key: 'diary_2026-11-26'))!)['photo'];
      expect(documentNames(), {first});
      expect(container.read(diaryProvider).datesWithEntries, {'2026-11-26'});
    });
  });
}

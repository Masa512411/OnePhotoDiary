import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/services/install_guard.dart';

import 'helpers/fake_documents.dart';

void main() {
  const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final savedData = {
    'diary_dates': jsonEncode(['2026-11-27']),
    'diary_2026-11-27': jsonEncode({
      'photo': '/var/mobile/Containers/Data/Application/OLD/Documents/a.jpg',
      'caption': 'test',
      'date': '2026-11-27',
    }),
    'reminder_enabled': 'true',
  };

  File markerOf(Directory documents) =>
      File('${documents.path}/${InstallGuard.markerFileName}');

  group('InstallGuard.run', () {
    test('マーカーがあれば何も消さない（通常起動）', () async {
      final documents = setUpFakeDocumentsDirectory();
      markerOf(documents).createSync();
      // 写真が存在しなくても、マーカーがあれば消去しない
      FlutterSecureStorage.setMockInitialValues(Map.of(savedData));

      expect(await InstallGuard.run(), isFalse);
      expect(await storage.readAll(), savedData);
    });

    test('マーカーがなくても写真が残っていればアップデートとみなし消さない', () async {
      final documents = setUpFakeDocumentsDirectory();
      createPhoto(documents, 'a.jpg');
      FlutterSecureStorage.setMockInitialValues(Map.of(savedData));

      expect(await InstallGuard.run(), isFalse);
      expect(await storage.readAll(), savedData);
      expect(markerOf(documents).existsSync(), isTrue);
    });

    test('マーカーがなく写真が1枚も残っていなければ再インストールとみなし消去する', () async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues(Map.of(savedData));

      expect(await InstallGuard.run(), isTrue);
      expect(await storage.readAll(), isEmpty);
      expect(markerOf(documents).existsSync(), isTrue);

      // 2回目以降の起動ではマーカーがあるため消去しない
      await storage.write(key: 'diary_dates', value: jsonEncode([]));
      expect(await InstallGuard.run(), isFalse);
      expect(await storage.read(key: 'diary_dates'), '[]');
    });

    test('撮影済み写真のみが残っている場合も写真がなければ消去する', () async {
      setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({
        'pending_photos': jsonEncode([
          {'name': 'p.jpg', 'date': '2026-11-27'},
        ]),
      });

      expect(await InstallGuard.run(), isTrue);
      expect(await storage.readAll(), isEmpty);
    });

    test('写真を参照するデータがなければ設定は消さない', () async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({'reminder_enabled': 'true'});

      expect(await InstallGuard.run(), isFalse);
      expect(await storage.readAll(), {'reminder_enabled': 'true'});
      expect(markerOf(documents).existsSync(), isTrue);
    });
  });
}

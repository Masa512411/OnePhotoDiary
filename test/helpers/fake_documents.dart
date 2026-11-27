import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// path_providerのDocumentsディレクトリを一時ディレクトリに差し替える
/// テスト終了時にディレクトリとモックを片付ける
Directory setUpFakeDocumentsDirectory() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('one_photo_diary_test_');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_pathProviderChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') return dir.path;
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  return dir;
}

/// Documentsディレクトリに写真ファイルを作成する
File createPhoto(Directory documents, String name) =>
    File('${documents.path}/$name')..writeAsBytesSync([0xFF, 0xD8, 0xFF]);

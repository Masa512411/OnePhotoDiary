import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';
import 'package:one_photo_diary/screens/entry_actions.dart';
import 'package:one_photo_diary/services/photo_import.dart';

import 'helpers/fake_documents.dart';

/// 選択結果を差し替えられるImagePicker
class FakeImagePicker extends ImagePicker {
  FakeImagePicker([this.result]);

  /// 返す画像のパス（nullならキャンセル扱い）
  final String? result;

  ImageSource? lastSource;
  double? lastMaxWidth;
  bool? lastRequestFullMetadata;

  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    lastSource = source;
    lastMaxWidth = maxWidth;
    lastRequestFullMetadata = requestFullMetadata;
    return result == null ? null : XFile(result!);
  }
}

void main() {
  test('取り込んだ画像はEXIFを除去してDocumentsにUUID.jpgで保存される', () async {
    final documents = setUpFakeDocumentsDirectory();
    final image = img.Image(width: 40, height: 20);
    image.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(35, 1);
    final source = File('${documents.path}/picked.jpg')
      ..writeAsBytesSync(img.encodeJpg(image));

    final saved = await savePhotoToDocuments(source.path);

    expect(saved.parent.path, documents.path);
    expect(
      saved.uri.pathSegments.last,
      matches(RegExp(r'^[0-9a-f-]{36}\.jpg$')),
    );
    final decoded = img.decodeJpg(saved.readAsBytesSync())!;
    expect(decoded.exif.gpsIfd.isEmpty, isTrue);
    expect(decoded.width, 40);
    // 元の画像はそのまま残す（image_pickerの一時ファイルのため）
    expect(source.existsSync(), isTrue);
  });

  test('pickは渡されたImagePickerで縮小・メタデータなしの1枚を選ぶ', () async {
    final picker = FakeImagePicker('/tmp/picked.jpg');

    final path = await PhotoImport.pick(picker, ImageSource.gallery);

    expect(path, '/tmp/picked.jpg');
    expect(picker.lastSource, ImageSource.gallery);
    expect(picker.lastMaxWidth, maxPhotoDimension.toDouble());
    expect(picker.lastRequestFullMetadata, isFalse);
  });

  group('pickEntryPhoto', () {
    late FakeImagePicker picker;
    File? result;

    Future<void> pumpPicker(WidgetTester tester) async {
      result = null;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [imagePickerProvider.overrideWithValue(picker)],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async =>
                      result = await pickEntryPhoto(context, ref),
                  child: const Text('写真を選ぶ'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('写真を選ぶ'));
      await tester.pumpAndSettle();
    }

    testWidgets('「アルバムから選ぶ」でimagePickerProviderのピッカーを使う', (tester) async {
      picker = FakeImagePicker();
      await pumpPicker(tester);

      expect(find.text('カメラで撮る'), findsOneWidget);
      await tester.tap(find.text('アルバムから選ぶ'));
      await tester.pumpAndSettle();

      expect(picker.lastSource, ImageSource.gallery);
      // キャンセルされたら何も保存しない
      expect(result, isNull);
      expect(find.text('写真を保存しています…'), findsNothing);
    });

    testWidgets('「カメラで撮る」はカメラから選ぶ', (tester) async {
      picker = FakeImagePicker();
      await pumpPicker(tester);

      await tester.tap(find.text('カメラで撮る'));
      await tester.pumpAndSettle();

      expect(picker.lastSource, ImageSource.camera);
    });
  });
}

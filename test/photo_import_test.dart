import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:one_photo_diary/services/photo_import.dart';

import 'helpers/fake_documents.dart';

void main() {
  test('取り込んだ画像はEXIFを除去してDocumentsにUUID.jpgで保存される', () async {
    final documents = setUpFakeDocumentsDirectory();
    final image = img.Image(width: 40, height: 20);
    image.exif.gpsIfd['GPSLatitudeRef'] = img.IfdValueAscii('N');
    image.exif.gpsIfd['GPSLatitude'] = img.IfdValueRational(35, 1);
    final source = File('${documents.path}/picked.jpg')
      ..writeAsBytesSync(img.encodeJpg(image));

    final saved = await PhotoImport.save(source.path);

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
}

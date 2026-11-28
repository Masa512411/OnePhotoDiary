import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';
import 'package:one_photo_diary/screens/camera_screen.dart';

/// ストレージ・ファイルに触れず、取得と保存の呼び出しを記録するPhotoNotifier
class FakePhotoNotifier extends PhotoNotifier {
  FakePhotoNotifier({this.initial = const [], this.pickResult});

  final List<File> initial;

  /// pickPhotoが返す結果
  final ({List<String> paths, int skipped})? pickResult;

  final pickedSources = <ImageSource>[];
  final addedPaths = <String>[];

  @override
  List<File> build() => initial;

  @override
  Future<({List<String> paths, int skipped})> pickPhoto({
    ImageSource source = ImageSource.camera,
  }) async {
    pickedSources.add(source);
    return pickResult ?? (paths: <String>[], skipped: 0);
  }

  @override
  Future<File?> addPhoto(String sourcePath) async {
    if (state.length >= PhotoNotifier.maxPhotos) return null;
    addedPaths.add(sourcePath);
    final file = File(sourcePath);
    state = [...state, file];
    return file;
  }
}

void main() {
  late FakePhotoNotifier photos;

  Future<void> pumpCamera(
    WidgetTester tester, {
    List<File> initial = const [],
    ({List<String> paths, int skipped})? pickResult,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    photos = FakePhotoNotifier(initial: initial, pickResult: pickResult);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [pendingPhotosProvider.overrideWith(() => photos)],
        child: const MaterialApp(home: CameraScreen()),
      ),
    );
  }

  List<File> dummyPhotos(int count) => [
    for (var i = 0; i < count; i++) File('dummy$i.jpg'),
  ];

  testWidgets('1枚もないときは案内と撮影・アルバムの両ボタンを表示する', (tester) async {
    await pumpCamera(tester);

    expect(find.text('撮影するか、アルバムから選んでください'), findsOneWidget);
    expect(find.text('撮影する'), findsOneWidget);
    expect(find.text('アルバムから選ぶ'), findsOneWidget);
    expect(find.text('今日の一枚を選ぶ'), findsNothing);
  });

  testWidgets('上限に達すると撮影・アルバムの両ボタンを隠す', (tester) async {
    await pumpCamera(tester, initial: dummyPhotos(PhotoNotifier.maxPhotos));

    expect(find.text('撮影する'), findsNothing);
    expect(find.text('アルバムから選ぶ'), findsNothing);
    expect(find.text('今日の一枚を選ぶ'), findsOneWidget);
  });

  testWidgets('アルバムから選んだ写真を撮影済み写真として保存する', (tester) async {
    await pumpCamera(
      tester,
      pickResult: (paths: ['a.jpg', 'b.jpg'], skipped: 0),
    );

    await tester.tap(find.text('アルバムから選ぶ'));
    await tester.pump();
    await tester.pump();

    expect(photos.pickedSources, [ImageSource.gallery]);
    expect(photos.addedPaths, ['a.jpg', 'b.jpg']);
    expect(find.text('2 / ${PhotoNotifier.maxPhotos}'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('撮影するボタンはカメラを取得元にする', (tester) async {
    await pumpCamera(tester, pickResult: (paths: ['c.jpg'], skipped: 0));

    await tester.tap(find.text('撮影する'));
    await tester.pump();

    expect(photos.pickedSources, [ImageSource.camera]);
    expect(photos.addedPaths, ['c.jpg']);
  });

  testWidgets('上限を超えた分は取り込まない旨を表示する', (tester) async {
    await pumpCamera(
      tester,
      initial: dummyPhotos(1),
      pickResult: (paths: ['a.jpg', 'b.jpg'], skipped: 2),
    );

    await tester.tap(find.text('アルバムから選ぶ'));
    await tester.pump();
    await tester.pump();

    expect(photos.addedPaths, ['a.jpg', 'b.jpg']);
    expect(
      find.text('撮影済み写真は${PhotoNotifier.maxPhotos}枚までのため、2枚は取り込みませんでした'),
      findsOneWidget,
    );
    expect(find.text('アルバムから選ぶ'), findsNothing);
  });
}

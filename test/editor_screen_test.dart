import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';
import 'package:one_photo_diary/screens/editor_screen.dart';

/// ストレージに触れず、保存呼び出し回数を記録するDiaryNotifier
class FakeDiaryNotifier extends DiaryNotifier {
  FakeDiaryNotifier({required this.hasTodayEntry});

  final bool hasTodayEntry;
  int saveCount = 0;

  /// 設定されている間は保存処理をこのCompleterの完了まで止める
  Completer<void>? saveGate;

  /// trueなら保存処理で例外を投げる
  bool failSave = false;

  @override
  DiaryState build() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return DiaryState(datesWithEntries: hasTodayEntry ? {today} : {});
  }

  @override
  Future<void> saveEntry({required File photo, required String caption}) async {
    saveCount++;
    if (saveGate != null) await saveGate!.future;
    if (failSave) throw Exception('保存失敗');
  }
}

/// ストレージに触れないPhotoNotifier
class FakePhotoNotifier extends PhotoNotifier {
  @override
  List<File> build() => [];

  @override
  Future<void> clear() async {
    state = [];
  }
}

void main() {
  late FakeDiaryNotifier diary;

  Future<void> pumpEditor(
    WidgetTester tester, {
    bool hasTodayEntry = false,
  }) async {
    // 保存ボタンまで画面内に収まるよう縦長の画面サイズにする
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    diary = FakeDiaryNotifier(hasTodayEntry: hasTodayEntry);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          diaryProvider.overrideWith(() => diary),
          pendingPhotosProvider.overrideWith(() => FakePhotoNotifier()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        EditorScreen(selectedPhoto: File('dummy.jpg')),
                  ),
                ),
                child: const Text('ホーム'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();
  }

  Finder saveButton() => find.widgetWithText(ElevatedButton, '保存する');

  testWidgets('今日の日記がなければ確認なしで保存してホームに戻る', (tester) async {
    await pumpEditor(tester);

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(diary.saveCount, 1);
    expect(find.text('ホーム'), findsOneWidget);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('今日の日記があれば上書き確認ダイアログを表示する', (tester) async {
    await pumpEditor(tester, hasTodayEntry: true);

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('今日の日記は保存済みです。上書きしますか？'), findsOneWidget);
    expect(diary.saveCount, 0);
  });

  testWidgets('確認ダイアログでキャンセルすると保存せず編集画面に留まる', (tester) async {
    await pumpEditor(tester, hasTodayEntry: true);

    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(diary.saveCount, 0);
    expect(find.byType(EditorScreen), findsOneWidget);
    // 再度保存ボタンを押せる状態に戻っている
    expect(tester.widget<ElevatedButton>(saveButton()).onPressed, isNotNull);
  });

  testWidgets('確認ダイアログで上書きすると保存する', (tester) async {
    await pumpEditor(tester, hasTodayEntry: true);

    await tester.tap(saveButton());
    await tester.pumpAndSettle();
    await tester.tap(find.text('上書きする'));
    await tester.pumpAndSettle();

    expect(diary.saveCount, 1);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('保存中は再タップしても保存を2回呼ばない', (tester) async {
    await pumpEditor(tester);
    diary.saveGate = Completer<void>();

    final button = find.byType(ElevatedButton).last;
    await tester.tap(button);
    await tester.pump();

    // 保存中はボタンが無効化され、インジケーターが表示される
    expect(tester.widget<ElevatedButton>(button).onPressed, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(button, warnIfMissed: false);
    await tester.pump();
    expect(diary.saveCount, 1);

    diary.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(diary.saveCount, 1);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('保存に失敗したらボタンを再度有効にする', (tester) async {
    await pumpEditor(tester);
    diary.failSave = true;

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.text('日記の保存に失敗しました'), findsOneWidget);
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.widget<ElevatedButton>(saveButton()).onPressed, isNotNull);
  });
}

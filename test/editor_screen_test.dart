import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:one_photo_diary/providers/diary_provider.dart';
import 'package:one_photo_diary/providers/photo_provider.dart';
import 'package:one_photo_diary/screens/editor_screen.dart';

import 'helpers/fake_documents.dart';
import 'helpers/fake_secure_storage.dart';

/// ストレージに触れず、保存呼び出し回数を記録するDiaryNotifier
class FakeDiaryNotifier extends DiaryNotifier {
  FakeDiaryNotifier({
    required this.hasTodayEntry,
    this.datesWithEntry = const {},
  });

  final bool hasTodayEntry;

  /// 保存済みとして扱う日付（今日以外）
  final Set<String> datesWithEntry;

  int saveCount = 0;

  /// 直近の保存で渡された日付・一言
  String? savedDate;
  String? savedCaption;

  /// 設定されている間は保存処理をこのCompleterの完了まで止める
  Completer<void>? saveGate;

  /// trueなら保存処理で例外を投げる
  bool failSave = false;

  /// trueなら保存済みかの確認で例外を投げる
  bool failCheck = false;

  @override
  DiaryState build() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    return DiaryState(datesWithEntries: hasTodayEntry ? {today} : {});
  }

  @override
  Future<bool> hasEntryToday() async {
    if (failCheck) throw Exception('確認失敗');
    return hasTodayEntry;
  }

  @override
  Future<bool> hasEntryOn(String dateKey) async {
    if (failCheck) throw Exception('確認失敗');
    return datesWithEntry.contains(dateKey);
  }

  @override
  Future<void> saveEntry({
    required File photo,
    required String caption,
    String? date,
  }) async {
    saveCount++;
    savedDate = date;
    savedCaption = caption;
    if (saveGate != null) await saveGate!.future;
    if (failSave) throw Exception('保存失敗');
  }
}

/// ストレージに触れないPhotoNotifier
class FakePhotoNotifier extends PhotoNotifier {
  /// trueならクリア処理で例外を投げる
  bool failClear = false;

  int clearCount = 0;

  @override
  List<File> build() => [];

  @override
  Future<void> clear() async {
    clearCount++;
    if (failClear) throw Exception('クリア失敗');
    state = [];
  }
}

void main() {
  late FakeDiaryNotifier diary;
  late FakePhotoNotifier photos;

  setUpAll(() => initializeDateFormatting('ja_JP'));

  Future<void> pumpEditor(
    WidgetTester tester, {
    bool hasTodayEntry = false,
    Set<String> datesWithEntry = const {},
    List<Override>? diaryOverrides,
    Widget Function()? editor,
  }) async {
    // 保存ボタンまで画面内に収まるよう縦長の画面サイズにする
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    diary = FakeDiaryNotifier(
      hasTodayEntry: hasTodayEntry,
      datesWithEntry: datesWithEntry,
    );
    photos = FakePhotoNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...diaryOverrides ?? [diaryProvider.overrideWith(() => diary)],
          pendingPhotosProvider.overrideWith(() => photos),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        editor?.call() ??
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

  testWidgets('同一フレーム内の連続タップでも保存を2回呼ばない', (tester) async {
    await pumpEditor(tester);
    diary.saveGate = Completer<void>();

    // 再描画（ボタン無効化）前に2回タップする
    await tester.tap(saveButton());
    await tester.tap(saveButton());
    await tester.pump();
    expect(diary.saveCount, 1);

    diary.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(diary.saveCount, 1);
  });

  testWidgets('同一フレーム内の連続タップでも確認ダイアログは1つだけ', (tester) async {
    await pumpEditor(tester, hasTodayEntry: true);

    await tester.tap(saveButton());
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
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

  testWidgets('保存中は戻る操作で編集画面を閉じられない', (tester) async {
    await pumpEditor(tester);
    diary.saveGate = Completer<void>();

    await tester.tap(saveButton());
    await tester.pump();

    // AppBarの戻るボタンは無効化される
    final backButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(IconButton),
      ),
    );
    expect(backButton.onPressed, isNull);

    // システムの戻る操作（Android の戻る・iOS のスワイプ相当）も無視される
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(EditorScreen), findsOneWidget);

    // 保存が終われば通常どおり完了表示してホームに戻る
    diary.saveGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('日記を保存しました！'), findsOneWidget);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('保存前は戻る操作で編集画面を閉じられる', (tester) async {
    await pumpEditor(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('写真のクリアに失敗しても保存成功として扱う', (tester) async {
    await pumpEditor(tester);
    photos.failClear = true;

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(diary.saveCount, 1);
    expect(find.text('日記の保存に失敗しました'), findsNothing);
    expect(find.text('日記を保存しました！'), findsOneWidget);
    expect(find.byType(EditorScreen), findsNothing);
  });

  testWidgets('保存済みかの確認に失敗したら保存せずボタンを再度有効にする', (tester) async {
    await pumpEditor(tester);
    diary.failCheck = true;

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(diary.saveCount, 0);
    expect(find.text('日記の保存に失敗しました'), findsOneWidget);
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.widget<ElevatedButton>(saveButton()).onPressed, isNotNull);
  });

  testWidgets('日付一覧を読めなくてもストレージに今日の日記があれば上書き確認する', (tester) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    FlutterSecureStorage.setMockInitialValues({
      'diary_$today': jsonEncode({
        'photo': 'old.jpg',
        'caption': '',
        'date': today,
      }),
    });
    final storage = FakeSecureStorage()..failRead('diary_dates');
    await pumpEditor(
      tester,
      diaryOverrides: [diaryStorageProvider.overrideWithValue(storage)],
    );

    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('キャンセル'));
    await tester.pumpAndSettle();
    expect(storage.writtenKeys, isEmpty);
    expect(find.byType(EditorScreen), findsOneWidget);
  });

  group('過去日の記録', () {
    Widget pastEditor() =>
        EditorScreen(selectedPhoto: File('dummy.jpg'), date: '2026-01-01');

    testWidgets('指定した日付で保存し、撮影済み写真はクリアしない', (tester) async {
      await pumpEditor(tester, editor: pastEditor);

      expect(find.text('2026年01月01日 (木)'), findsOneWidget);
      expect(find.text('この日の一言'), findsOneWidget);
      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(diary.saveCount, 1);
      expect(diary.savedDate, '2026-01-01');
      expect(photos.clearCount, 0);
      expect(find.byType(EditorScreen), findsNothing);
    });

    testWidgets('その日の日記が保存済みなら上書き確認する', (tester) async {
      await pumpEditor(
        tester,
        // 今日の日記の有無ではなく、指定日の日記の有無で確認する
        datesWithEntry: {'2026-01-01'},
        editor: pastEditor,
      );

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.text('この日の日記は保存済みです。上書きしますか？'), findsOneWidget);
      await tester.tap(find.text('上書きする'));
      await tester.pumpAndSettle();
      expect(diary.saveCount, 1);
      expect(diary.savedDate, '2026-01-01');
    });

    testWidgets('今日の日記があっても指定日に日記が無ければ確認しない', (tester) async {
      await pumpEditor(tester, hasTodayEntry: true, editor: pastEditor);

      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(diary.saveCount, 1);
    });
  });

  group('編集', () {
    Widget editEditor() => EditorScreen.edit(
      entry: DiaryEntry(
        photo: File('dummy.jpg'),
        caption: '前の一言',
        date: '2026-01-01',
      ),
    );

    testWidgets('保存済みの一言が入った状態で開き、確認なしで同じ日付に保存する', (tester) async {
      await pumpEditor(
        tester,
        datesWithEntry: {'2026-01-01'},
        editor: editEditor,
      );

      expect(find.text('編集する'), findsOneWidget);
      expect(find.text('前の一言'), findsOneWidget);
      expect(find.text('写真を変更'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '新しい一言');
      await tester.tap(saveButton());
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(diary.saveCount, 1);
      expect(diary.savedDate, '2026-01-01');
      expect(diary.savedCaption, '新しい一言');
      expect(photos.clearCount, 0);
      expect(find.byType(EditorScreen), findsNothing);
    });
  });

  testWidgets('今日の記録では撮影済み写真をクリアし、写真の変更ボタンは出さない', (tester) async {
    await pumpEditor(tester);

    expect(find.text('写真を変更'), findsNothing);
    await tester.tap(saveButton());
    await tester.pumpAndSettle();

    expect(diary.savedDate, isNull);
    expect(photos.clearCount, 1);
  });

  group('取り込んだ写真の後片付け', () {
    testWidgets('保存せずに閉じると取り込んだ写真を削除する', (tester) async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({});
      final imported = createPhoto(documents, 'imported.jpg');
      await pumpEditor(
        tester,
        editor: () => EditorScreen(
          selectedPhoto: imported,
          date: '2026-01-01',
          photoIsImported: true,
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      // 参照の確認・削除は実際のファイルI/Oのため、実時間で完了を待つ
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      expect(find.byType(EditorScreen), findsNothing);
      expect(imported.existsSync(), isFalse);
    });

    testWidgets('保存済みのエントリが参照している写真は閉じても削除しない', (tester) async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({
        'diary_dates': jsonEncode(['2026-01-01']),
        'diary_2026-01-01': jsonEncode({
          'photo': 'imported.jpg',
          'caption': '',
          'date': '2026-01-01',
        }),
      });
      final imported = createPhoto(documents, 'imported.jpg');
      await pumpEditor(
        tester,
        editor: () => EditorScreen(
          selectedPhoto: imported,
          date: '2026-01-01',
          photoIsImported: true,
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      expect(imported.existsSync(), isTrue);
    });

    testWidgets('取り込んでいない写真（撮影済み・編集前の写真）は閉じても削除しない', (tester) async {
      final documents = setUpFakeDocumentsDirectory();
      FlutterSecureStorage.setMockInitialValues({});
      final original = createPhoto(documents, 'original.jpg');
      await pumpEditor(
        tester,
        editor: () => EditorScreen.edit(
          entry: DiaryEntry(photo: original, caption: '', date: '2026-01-01'),
        ),
      );

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();

      expect(original.existsSync(), isTrue);
    });
  });
}

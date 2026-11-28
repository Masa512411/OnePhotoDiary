import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/calendar_provider.dart';
import 'package:one_photo_diary/screens/home_screen.dart';

import 'helpers/fake_documents.dart';

void main() {
  late ProviderContainer container;

  Future<void> pumpHome(WidgetTester tester, DateTime selectedDay) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(calendarProvider.notifier)
        .selectDay(selectedDay, selectedDay);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// カレンダーと同じく、日付をUTCの0時で表す
  DateTime dayOffset(int days) {
    final now = DateTime.now();
    return DateTime.utc(now.year, now.month, now.day + days);
  }

  setUp(() {
    setUpFakeDocumentsDirectory();
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('記録の無い過去の日は「この日を記録する」を表示する', (tester) async {
    await pumpHome(tester, dayOffset(-1));

    expect(find.text('この日の記録はありません'), findsOneWidget);
    expect(find.text('この日を記録する'), findsOneWidget);
    expect(find.text('写真を撮る'), findsNothing);
  });

  testWidgets('今日は従来どおり撮影ボタンを表示する', (tester) async {
    await pumpHome(tester, dayOffset(0));

    expect(find.text('写真を撮る'), findsOneWidget);
    expect(find.text('この日を記録する'), findsNothing);
  });

  testWidgets('未来の日は記録できない', (tester) async {
    await pumpHome(tester, dayOffset(1));

    expect(find.text('この日の記録はありません'), findsOneWidget);
    expect(find.text('写真を撮る'), findsNothing);
    expect(find.text('この日を記録する'), findsNothing);
  });

  testWidgets('記録のある日は編集・削除のメニューから削除できる', (tester) async {
    final day = dayOffset(-1);
    final dateKey = day.toIso8601String().substring(0, 10);
    FlutterSecureStorage.setMockInitialValues({
      'diary_dates': jsonEncode([dateKey]),
      'diary_$dateKey': jsonEncode({
        'photo': 'a.jpg',
        'caption': '昨日の一言',
        'date': dateKey,
      }),
    });
    await pumpHome(tester, day);
    expect(find.text('昨日の一言'), findsOneWidget);

    await tester.tap(find.byTooltip('メニュー'));
    await tester.pumpAndSettle();
    expect(find.text('編集'), findsOneWidget);
    await tester.tap(find.text('削除'));
    await tester.pumpAndSettle();
    expect(find.text('この日の日記を削除しますか？'), findsOneWidget);
    await tester.tap(find.text('削除する'));
    // 写真ファイルの確認・削除は実際のファイルI/Oのため、実時間で完了を待つ
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(find.text('日記を削除しました'), findsOneWidget);
    expect(find.text('昨日の一言'), findsNothing);
    expect(find.text('この日を記録する'), findsOneWidget);
  });
}

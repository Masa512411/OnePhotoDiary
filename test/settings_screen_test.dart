import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/reminder_provider.dart';
import 'package:one_photo_diary/screens/settings_screen.dart';

import 'helpers/fake_documents.dart';
import 'helpers/fake_notifications.dart';

void main() {
  /// launcherに渡されたURLの記録
  late List<Uri> launched;

  Future<void> pumpSettings(
    WidgetTester tester,
    Future<bool> Function(Uri) launcher,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationServiceProvider.overrideWithValue(
            FakeNotificationService(),
          ),
          urlLauncherProvider.overrideWithValue(launcher),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapPrivacyPolicy(WidgetTester tester) async {
    final tile = find.text('プライバシーポリシー');
    await tester.scrollUntilVisible(tile, 100);
    await tester.tap(tile);
    await tester.pumpAndSettle();
  }

  setUp(() {
    setUpFakeDocumentsDirectory();
    FlutterSecureStorage.setMockInitialValues({});
    launched = [];
  });

  testWidgets('プライバシーポリシーをタップすると公開URLを開く', (tester) async {
    await pumpSettings(tester, (url) async {
      launched.add(url);
      return true;
    });

    await tapPrivacyPolicy(tester);

    expect(launched, [
      Uri.parse(
        'https://github.com/Masa512411/OnePhotoDiary/blob/main/docs/privacy_policy.md',
      ),
    ]);
    expect(find.text('プライバシーポリシーを開けませんでした'), findsNothing);
  });

  testWidgets('開けなかった場合はメッセージを表示する', (tester) async {
    await pumpSettings(tester, (url) async {
      launched.add(url);
      return false;
    });

    await tapPrivacyPolicy(tester);

    expect(launched, hasLength(1));
    expect(find.text('プライバシーポリシーを開けませんでした'), findsOneWidget);
  });

  testWidgets('launcherが例外を投げた場合もメッセージを表示する', (tester) async {
    await pumpSettings(tester, (url) async {
      launched.add(url);
      throw Exception('ブラウザがありません');
    });

    await tapPrivacyPolicy(tester);

    expect(launched, hasLength(1));
    expect(find.text('プライバシーポリシーを開けませんでした'), findsOneWidget);
  });
}

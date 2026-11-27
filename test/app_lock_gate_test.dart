import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/auth_provider.dart';
import 'package:one_photo_diary/screens/app_lock_gate.dart';

import 'helpers/fake_local_auth.dart';

void main() {
  late FakeLocalAuthentication fake;
  late ProviderContainer container;
  late DateTime now;

  Future<void> pumpApp(WidgetTester tester) async {
    now = DateTime(2026, 1, 1, 12);
    container = ProviderContainer(
      overrides: [
        localAuthProvider.overrideWithValue(fake),
        relockTimerProvider.overrideWithValue(RelockTimer(now: () => now)),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(body: Text('詳細画面')),
                  ),
                ),
                child: const Text('ホーム'),
              ),
            ),
          ),
          builder: (context, child) => AppLockGate(child: child!),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// HOMEキーでバックグラウンドへ移り、指定時間後に復帰する
  Future<void> backgroundFor(WidgetTester tester, Duration duration) async {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    now = now.add(duration);
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
  }

  final lockScreen = find.text('もう一度認証する');

  testWidgets('再ロックしても画面スタックが保持される', (tester) async {
    fake = FakeLocalAuthentication(authResult: false);
    await pumpApp(tester);

    // 認証前はアプリ本体を生成しない
    expect(find.text('ホーム'), findsNothing);
    expect(lockScreen, findsOneWidget);

    // リトライで解除
    fake.authResult = true;
    await tester.tap(lockScreen);
    await tester.pumpAndSettle();
    expect(find.text('ホーム'), findsOneWidget);

    // 詳細画面へ進んでから再ロック
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();
    fake.authResult = false;
    container.read(authProvider.notifier).lock();
    await tester.pumpAndSettle();
    expect(lockScreen, findsOneWidget);

    // 解除すると詳細画面に戻る
    fake.authResult = true;
    await tester.tap(lockScreen);
    await tester.pumpAndSettle();
    expect(lockScreen, findsNothing);
    expect(find.text('詳細画面'), findsOneWidget);
  });

  testWidgets('60秒以上バックグラウンドにいると復帰時に再認証する', (tester) async {
    fake = FakeLocalAuthentication();
    await pumpApp(tester);
    expect(fake.authenticateCalls, 1);
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();

    fake.authResult = false;
    await backgroundFor(tester, const Duration(seconds: 61));

    expect(fake.authenticateCalls, 2);
    expect(lockScreen, findsOneWidget);
  });

  testWidgets('60秒未満の離脱では再ロックしない', (tester) async {
    fake = FakeLocalAuthentication();
    await pumpApp(tester);

    await backgroundFor(tester, const Duration(seconds: 59));

    expect(fake.authenticateCalls, 1);
    expect(find.text('ホーム'), findsOneWidget);
  });

  testWidgets('画面ロックなしで通過中に画面ロックが設定されたら復帰時にロックする',
      (tester) async {
    fake = FakeLocalAuthentication(deviceSupported: [false]);
    await pumpApp(tester);
    expect(container.read(authProvider).status, AuthStatus.unsupported);

    fake
      ..deviceSupported = [true]
      ..authResult = false;
    await backgroundFor(tester, const Duration(seconds: 5));

    expect(fake.authenticateCalls, 1);
    expect(lockScreen, findsOneWidget);
  });
}

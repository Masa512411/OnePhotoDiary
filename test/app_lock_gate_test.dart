import 'dart:async';

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

  Future<void> pumpApp(WidgetTester tester, {bool settle = true}) async {
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
    // 認証中はインジケーターが動き続けるので落ち着くのを待たない
    settle ? await tester.pumpAndSettle() : await tester.pump();
  }

  void goBackground(WidgetTester tester) {
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  Future<void> resume(WidgetTester tester) async {
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
    await tester.pumpAndSettle();
  }

  /// HOMEキーでバックグラウンドへ移り、指定時間後に復帰する
  Future<void> backgroundFor(WidgetTester tester, Duration duration) async {
    goBackground(tester);
    now = now.add(duration);
    await resume(tester);
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

  testWidgets('画面ロックなしの端末は60秒以上離脱してもロック画面を出さない', (tester) async {
    fake = FakeLocalAuthentication(deviceSupported: [false]);
    await pumpApp(tester);
    final statuses = <AuthStatus>[];
    container.listen<AuthState>(
      authProvider,
      (_, next) => statuses.add(next.status),
    );

    await backgroundFor(tester, const Duration(seconds: 61));

    expect(statuses, isEmpty);
    expect(find.text('ホーム'), findsOneWidget);
  });

  testWidgets('認証中のバックグラウンド時間は再ロックの対象外', (tester) async {
    // Androidのパスコード画面など、認証中にアプリが裏に回るケース
    fake = FakeLocalAuthentication()..pendingAuth = Completer<bool>();
    await pumpApp(tester, settle: false);
    await tester.pump();
    expect(container.read(authProvider).status, AuthStatus.authenticating);

    goBackground(tester);
    now = now.add(const Duration(seconds: 61));
    fake.pendingAuth!.complete(true);
    await resume(tester);

    expect(fake.authenticateCalls, 1);
    expect(find.text('ホーム'), findsOneWidget);
  });

  testWidgets('認証失敗中のバックグラウンド時間は再ロックの対象外', (tester) async {
    fake = FakeLocalAuthentication(authResult: false);
    await pumpApp(tester);
    expect(lockScreen, findsOneWidget);

    await backgroundFor(tester, const Duration(seconds: 61));
    fake.authResult = true;
    await tester.tap(lockScreen);
    await tester.pumpAndSettle();

    // 解除後の短い離脱で、失敗中の時間が加算されて再ロックされない
    await backgroundFor(tester, const Duration(seconds: 1));

    expect(fake.authenticateCalls, 2);
    expect(find.text('ホーム'), findsOneWidget);
  });
}

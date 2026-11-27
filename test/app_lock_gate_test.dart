import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/auth_provider.dart';
import 'package:one_photo_diary/screens/app_lock_gate.dart';

import 'helpers/fake_local_auth.dart';

void main() {
  late FakeLocalAuthentication fake;
  late ProviderContainer container;
  late DateTime now;

  late GlobalKey<NavigatorState> navigatorKey;

  Future<void> pumpApp(WidgetTester tester, {bool settle = true}) async {
    navigatorKey = GlobalKey<NavigatorState>();
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
          navigatorKey: navigatorKey,
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const Scaffold(
                      body: Column(children: [Text('詳細画面'), TextField()]),
                    ),
                  ),
                ),
                child: const Text('ホーム'),
              ),
            ),
          ),
          builder: (context, child) =>
              AppLockGate(navigatorKey: navigatorKey, child: child!),
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
  final privacyCover = find.byKey(AppLockGate.privacyCoverKey);

  /// Androidの予測型「戻る」ジェスチャーを最後まで行う
  Future<void> predictiveBack(WidgetTester tester) async {
    for (final call in [
      const MethodCall('startBackGesture', <String, dynamic>{
        'touchOffset': <double>[5.0, 300.0],
        'progress': 0.0,
        'swipeEdge': 0,
      }),
      const MethodCall('updateBackGestureProgress', <String, dynamic>{
        'x': 100.0,
        'y': 300.0,
        'progress': 0.35,
        'swipeEdge': 0,
      }),
      const MethodCall('commitBackGesture'),
    ]) {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'flutter/backgesture',
        const StandardMethodCodec().encodeMethodCall(call),
        (_) {},
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  /// ロックしてロック画面（認証失敗状態）を表示する
  Future<void> lockNow(WidgetTester tester) async {
    fake.authResult = false;
    container.read(authProvider.notifier).lock();
    await tester.pumpAndSettle();
    expect(lockScreen, findsOneWidget);
  }

  Future<void> unlockByRetry(WidgetTester tester) async {
    fake.authResult = true;
    await tester.tap(lockScreen);
    await tester.pumpAndSettle();
    expect(lockScreen, findsNothing);
  }

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

  group('ロック中の戻る操作', () {
    testWidgets('システムの戻る・予測型「戻る」で下の画面が閉じない', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      await lockNow(tester);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      await predictiveBack(tester);
      expect(lockScreen, findsOneWidget);

      // 解除すると詳細画面が残っている
      await unlockByRetry(tester);
      expect(find.text('詳細画面'), findsOneWidget);

      // 解除後は通常どおり戻れる
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('詳細画面'), findsNothing);
      expect(find.text('ホーム'), findsOneWidget);
    });

    testWidgets('解除後は予測型「戻る」で戻れる', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      await lockNow(tester);
      await unlockByRetry(tester);

      await predictiveBack(tester);
      expect(find.text('詳細画面'), findsNothing);
      expect(find.text('ホーム'), findsOneWidget);
    });

    testWidgets('最初の画面でロック中に戻る操作をしてもアプリを閉じない', (tester) async {
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          platformCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      bool? frameworkHandlesBack() =>
          platformCalls
                  .lastWhere(
                    (c) =>
                        c.method == 'SystemNavigator.setFrameworkHandlesBack',
                  )
                  .arguments
              as bool;

      // 前面にいないとWidgetsAppはOSへ戻る操作の受け取りを通知しない
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      expect(frameworkHandlesBack(), isFalse);
      await lockNow(tester);

      // OSではなくFlutterが戻る操作を受け取り、何もしない
      expect(frameworkHandlesBack(), isTrue);
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(
        platformCalls.where((c) => c.method == 'SystemNavigator.pop'),
        isEmpty,
      );

      // 解除後は最初の画面の戻る操作をOSに任せる
      await unlockByRetry(tester);
      expect(frameworkHandlesBack(), isFalse);
    });

    testWidgets('ロック中に開いた画面も戻る操作で閉じない', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      await lockNow(tester);

      // 通知タップなどでロック中に画面が積まれるケース
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('ロック中の画面')),
        ),
      );
      await tester.pumpAndSettle();

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      await predictiveBack(tester);

      await unlockByRetry(tester);
      expect(find.text('ロック中の画面'), findsOneWidget);
    });

    testWidgets('ロック中にコードで画面が閉じたら、新しい最前面の画面で止め直す', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('一時的な画面')),
        ),
      );
      await tester.pumpAndSettle();
      await lockNow(tester);

      navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      await predictiveBack(tester);

      await unlockByRetry(tester);
      expect(find.text('一時的な画面'), findsNothing);
      expect(find.text('詳細画面'), findsOneWidget);
    });

    testWidgets('ロック中は最前面のダイアログも戻る操作で閉じない', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      showDialog<void>(
        context: navigatorKey.currentContext!,
        builder: (_) => const AlertDialog(content: Text('確認ダイアログ')),
      );
      await tester.pumpAndSettle();
      await lockNow(tester);

      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();

      await unlockByRetry(tester);
      expect(find.text('確認ダイアログ'), findsOneWidget);

      // 解除後は戻る操作で閉じられる
      expect(await tester.binding.handlePopRoute(), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('確認ダイアログ'), findsNothing);
    });
  });

  group('プライバシーカバー', () {
    /// 裏から戻り始めた（resumed前の）最初のフレームで内容が覆われていることを確認する
    Future<void> returnToForeground(WidgetTester tester) async {
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(privacyCover, findsOneWidget);
      expect(find.text('ホーム').hitTestable(), findsNothing);
      expect(find.text('詳細画面').hitTestable(), findsNothing);
    }

    testWidgets('裏に回ると内容を覆い、60秒未満で戻ると入力途中のまま外す', (tester) async {
      // カメラで撮影して戻るケース
      fake = FakeLocalAuthentication();
      await pumpApp(tester);
      await tester.tap(find.text('ホーム'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '今日のひとこと');
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );

      // Androidはinactiveでは覆わない
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(privacyCover, findsNothing);

      // hidden以降はフレームが描画されないため、復帰時の最初のフレームで覆われている
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 30));
      await returnToForeground(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(privacyCover, findsNothing);
      expect(lockScreen, findsNothing);
      expect(fake.authenticateCalls, 1);
      expect(find.text('詳細画面').hitTestable(), findsOneWidget);
      expect(find.text('今日のひとこと'), findsOneWidget);
      expect(
        tester.state<EditableTextState>(find.byType(EditableText)),
        same(editable),
      );
    });

    testWidgets('Androidではinactiveだけでは覆わない', (tester) async {
      // 通知シェード・権限ダイアログ・分割画面で別アプリを操作中など
      fake = FakeLocalAuthentication();
      await pumpApp(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(privacyCover, findsNothing);
      expect(find.text('ホーム').hitTestable(), findsOneWidget);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(privacyCover, findsNothing);
    });

    testWidgets('iOSではinactiveで覆い、そのまま戻ったら外す', (tester) async {
      // アプリ切り替え画面のスナップショット前に覆う
      fake = FakeLocalAuthentication();
      await pumpApp(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(privacyCover, findsOneWidget);
      expect(find.text('ホーム').hitTestable(), findsNothing);

      // コントロールセンターなど
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(privacyCover, findsNothing);
      expect(find.text('ホーム').hitTestable(), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('60秒以上離脱するとカバーからロック画面に切り替わる', (tester) async {
      fake = FakeLocalAuthentication();
      await pumpApp(tester);

      fake.authResult = false;
      await backgroundFor(tester, const Duration(seconds: 61));

      expect(privacyCover, findsNothing);
      expect(lockScreen, findsOneWidget);

      // 再認証するとそのまま使える
      await unlockByRetry(tester);
      expect(privacyCover, findsNothing);
      expect(find.text('ホーム').hitTestable(), findsOneWidget);
    });

    testWidgets('画面ロックなしの端末でも覆い、復帰時に外す', (tester) async {
      fake = FakeLocalAuthentication(deviceSupported: [false]);
      await pumpApp(tester);
      expect(container.read(authProvider).status, AuthStatus.unsupported);

      goBackground(tester);
      now = now.add(const Duration(seconds: 61));
      await returnToForeground(tester);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(privacyCover, findsNothing);
      expect(lockScreen, findsNothing);
      expect(find.text('ホーム').hitTestable(), findsOneWidget);
    });

    group('画面ロックなしの端末で画面ロック設定の確認中', () {
      Future<void> resumeWhileChecking(WidgetTester tester) async {
        fake = FakeLocalAuthentication(deviceSupported: [false]);
        await pumpApp(tester);
        goBackground(tester);

        fake
          ..pendingDeviceSupported = Completer<bool>()
          ..authResult = false;
        for (final s in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(s);
        }
        await tester.pump();

        // 確認が終わるまで内容を出さない
        expect(privacyCover, findsOneWidget);
        expect(lockScreen, findsNothing);
        expect(find.text('ホーム').hitTestable(), findsNothing);
      }

      testWidgets('画面ロックが設定されていたら内容を見せずにロック画面へ切り替わる', (tester) async {
        await resumeWhileChecking(tester);

        fake.pendingDeviceSupported!.complete(true);
        await tester.pumpAndSettle();

        expect(lockScreen, findsOneWidget);
        expect(privacyCover, findsNothing);
      });

      testWidgets('画面ロックが未設定のままならカバーを外す', (tester) async {
        await resumeWhileChecking(tester);

        fake.pendingDeviceSupported!.complete(false);
        await tester.pumpAndSettle();

        expect(privacyCover, findsNothing);
        expect(lockScreen, findsNothing);
        expect(find.text('ホーム').hitTestable(), findsOneWidget);
      });

      testWidgets('確認中に再び裏に回ったら覆ったままにする', (tester) async {
        await resumeWhileChecking(tester);

        goBackground(tester);
        fake.pendingDeviceSupported!.complete(false);
        await tester.pump();

        // 次に戻り始めた最初のフレームでも覆われている
        await returnToForeground(tester);
      });
    });

    testWidgets(
      '認証ダイアログ表示中は覆わず、解除後にも残らない',
      (tester) async {
        fake = FakeLocalAuthentication();
        await pumpApp(tester);
        await tester.tap(find.text('ホーム'));
        await tester.pumpAndSettle();
        await lockNow(tester);

        // 認証ダイアログ（Androidのパスコード画面など）でアプリが裏に回っている間に
        // 認証が成功する
        fake.pendingAuth = Completer<bool>();
        await tester.tap(lockScreen);
        await tester.pump();
        goBackground(tester);
        await tester.pump();
        expect(privacyCover, findsNothing);

        fake.pendingAuth!.complete(true);
        await tester.pump();
        await resume(tester);

        expect(privacyCover, findsNothing);
        expect(lockScreen, findsNothing);
        expect(find.text('詳細画面').hitTestable(), findsOneWidget);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_photo_diary/providers/auth_provider.dart';
import 'package:one_photo_diary/screens/app_lock_gate.dart';

import 'helpers/fake_local_auth.dart';

void main() {
  testWidgets('再ロックしても画面スタックが保持される', (tester) async {
    final fake = FakeLocalAuthentication(authResult: false);
    final container = ProviderContainer(
      overrides: [localAuthProvider.overrideWithValue(fake)],
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

    // 認証前はアプリ本体を生成しない
    expect(find.text('ホーム'), findsNothing);
    expect(find.text('もう一度認証する'), findsOneWidget);

    // リトライで解除
    fake.authResult = true;
    await tester.tap(find.text('もう一度認証する'));
    await tester.pumpAndSettle();
    expect(find.text('ホーム'), findsOneWidget);

    // 詳細画面へ進んでから再ロック
    await tester.tap(find.text('ホーム'));
    await tester.pumpAndSettle();
    fake.authResult = false;
    container.read(authProvider.notifier).lock();
    await tester.pumpAndSettle();
    expect(find.text('もう一度認証する'), findsOneWidget);

    // 解除すると詳細画面に戻る
    fake.authResult = true;
    await tester.tap(find.text('もう一度認証する'));
    await tester.pumpAndSettle();
    expect(find.text('もう一度認証する'), findsNothing);
    expect(find.text('詳細画面'), findsOneWidget);
  });
}

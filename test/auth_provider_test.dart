import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:one_photo_diary/providers/auth_provider.dart';

import 'helpers/fake_local_auth.dart';

void main() {
  late FakeLocalAuthentication fake;
  late ProviderContainer container;

  ProviderContainer createContainer() {
    final c = ProviderContainer(
      overrides: [localAuthProvider.overrideWithValue(fake)],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<AuthState> authenticate() async {
    await container.read(authProvider.notifier).authenticate();
    return container.read(authProvider);
  }

  group('AuthNotifier.authenticate', () {
    test('認証成功でauthenticatedになる', () async {
      fake = FakeLocalAuthentication();
      container = createContainer();

      final state = await authenticate();

      expect(state.status, AuthStatus.authenticated);
      expect(state.isUnlocked, isTrue);
      // パスコードへのフォールバックを許可している
      expect(fake.lastOptions?.biometricOnly, isFalse);
      expect(fake.lastOptions?.useErrorDialogs, isFalse);
    });

    test('認証がfalseで返るとfailedになる', () async {
      fake = FakeLocalAuthentication(authResult: false);
      container = createContainer();

      final state = await authenticate();

      expect(state.status, AuthStatus.failed);
      expect(state.isUnlocked, isFalse);
    });

    test('ユーザーキャンセルはfailedになる', () async {
      fake = FakeLocalAuthentication(
        authError: PlatformException(code: 'UserCancelled'),
      );
      container = createContainer();

      final state = await authenticate();

      expect(state.status, AuthStatus.failed);
      expect(state.errorMessage, isNotNull);
    });

    test('ロックアウトはfailedになる', () async {
      fake = FakeLocalAuthentication(
        authError: PlatformException(code: auth_error.lockedOut),
      );
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.failed);
    });

    test('PasscodeNotSetは画面ロックなしとして通す', () async {
      fake = FakeLocalAuthentication(
        authError: PlatformException(code: auth_error.passcodeNotSet),
      );
      container = createContainer();

      final state = await authenticate();

      expect(state.status, AuthStatus.unsupported);
      expect(state.isUnlocked, isTrue);
    });

    test('NotAvailableで端末も非対応なら通す', () async {
      fake = FakeLocalAuthentication(
        deviceSupported: [true, false],
        authError: PlatformException(code: auth_error.notAvailable),
      );
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.unsupported);
    });

    test('NotEnrolledで端末も非対応なら通す', () async {
      fake = FakeLocalAuthentication(
        deviceSupported: [true, false],
        authError: PlatformException(code: auth_error.notEnrolled),
      );
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.unsupported);
    });

    test('NotAvailableでも端末に画面ロックがあればfailedのまま', () async {
      // iOSのシステムキャンセル等もNotAvailableになるため
      fake = FakeLocalAuthentication(
        deviceSupported: [true],
        authError: PlatformException(code: auth_error.notAvailable),
      );
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.failed);
    });

    test('端末が非対応なら認証せずに通す', () async {
      fake = FakeLocalAuthentication(deviceSupported: [false]);
      container = createContainer();

      final state = await authenticate();

      expect(state.status, AuthStatus.unsupported);
      expect(fake.authenticateCalls, 0);
    });
  });

  group('AuthNotifier.authenticate（多重実行・例外）', () {
    test('awaitせずに2回呼んでも認証は1回だけ', () async {
      fake = FakeLocalAuthentication();
      container = createContainer();
      final notifier = container.read(authProvider.notifier);

      await Future.wait([notifier.authenticate(), notifier.authenticate()]);

      expect(fake.authenticateCalls, 1);
      expect(container.read(authProvider).status, AuthStatus.authenticated);
    });

    test('isDeviceSupportedが例外でも通さずに認証へ進む', () async {
      fake = FakeLocalAuthentication()
        ..deviceSupportedError = PlatformException(code: 'error');
      container = createContainer();

      final state = await authenticate();

      expect(fake.authenticateCalls, 1);
      expect(state.status, AuthStatus.authenticated);
    });

    test('isDeviceSupportedが例外で認証も失敗ならfailed', () async {
      fake = FakeLocalAuthentication(
        authError: PlatformException(code: 'UserCancelled'),
      )..deviceSupportedError = PlatformException(code: 'error');
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.failed);
    });

    test('NotAvailable後の再確認が例外ならfailed', () async {
      fake = FakeLocalAuthentication(
        authError: PlatformException(code: auth_error.notAvailable),
      )..deviceSupportedError = PlatformException(code: 'error');
      container = createContainer();

      expect((await authenticate()).status, AuthStatus.failed);
    });
  });

  group('AuthNotifier.lock', () {
    test('解除済みならinitialに戻る', () async {
      fake = FakeLocalAuthentication();
      container = createContainer();
      await authenticate();

      container.read(authProvider.notifier).lock();

      expect(container.read(authProvider).status, AuthStatus.initial);
    });

    test('失敗状態では何もしない', () async {
      fake = FakeLocalAuthentication(authResult: false);
      container = createContainer();
      await authenticate();

      container.read(authProvider.notifier).lock();

      expect(container.read(authProvider).status, AuthStatus.failed);
    });
  });

  group('AuthNotifier.recheckDeviceLock', () {
    test('画面ロックなしで通過中に画面ロックが設定されたらロックする', () async {
      fake = FakeLocalAuthentication(deviceSupported: [false, true]);
      container = createContainer();
      await authenticate();

      await container.read(authProvider.notifier).recheckDeviceLock();

      expect(container.read(authProvider).status, AuthStatus.initial);
    });

    test('画面ロックが未設定のままなら通過したまま', () async {
      fake = FakeLocalAuthentication(deviceSupported: [false]);
      container = createContainer();
      await authenticate();

      await container.read(authProvider.notifier).recheckDeviceLock();

      expect(container.read(authProvider).status, AuthStatus.unsupported);
    });

    test('再確認が例外ならロックする', () async {
      fake = FakeLocalAuthentication(deviceSupported: [false]);
      container = createContainer();
      await authenticate();
      fake.deviceSupportedError = PlatformException(code: 'error');

      await container.read(authProvider.notifier).recheckDeviceLock();

      expect(container.read(authProvider).status, AuthStatus.initial);
    });

    test('認証済みなら何もしない', () async {
      fake = FakeLocalAuthentication();
      container = createContainer();
      await authenticate();

      await container.read(authProvider.notifier).recheckDeviceLock();

      expect(container.read(authProvider).status, AuthStatus.authenticated);
    });
  });

  group('RelockTimer', () {
    late DateTime now;
    late RelockTimer timer;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      timer = RelockTimer(now: () => now);
    });

    test('猶予時間は60秒', () {
      expect(RelockTimer.lockAfter, const Duration(seconds: 60));
    });

    test('60秒未満の離脱ではロックしない', () {
      timer.markBackground();
      now = now.add(const Duration(seconds: 59));
      expect(timer.shouldLockOnResume(), isFalse);
    });

    test('60秒以上の離脱でロックする', () {
      timer.markBackground();
      now = now.add(const Duration(seconds: 60));
      expect(timer.shouldLockOnResume(), isTrue);
    });

    test('hidden→pausedと続いても最初の時刻から計測する', () {
      timer.markBackground();
      now = now.add(const Duration(seconds: 30));
      timer.markBackground();
      now = now.add(const Duration(seconds: 30));
      expect(timer.shouldLockOnResume(), isTrue);
    });

    test('バックグラウンド記録がなければロックしない', () {
      now = now.add(const Duration(minutes: 10));
      expect(timer.shouldLockOnResume(), isFalse);
    });

    test('復帰すると記録がリセットされる', () {
      timer.markBackground();
      now = now.add(const Duration(seconds: 10));
      expect(timer.shouldLockOnResume(), isFalse);
      now = now.add(const Duration(minutes: 10));
      expect(timer.shouldLockOnResume(), isFalse);
    });
  });
}

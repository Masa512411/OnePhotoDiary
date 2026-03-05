import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

/// 認証の状態を表すenum
enum AuthStatus {
  initial,        // 初期状態
  authenticating, // 認証中
  authenticated,  // 認証成功
  failed,         // 認証失敗
  unsupported,    // 生体認証非対応
}

/// 認証状態を保持するクラス
class AuthState {
  final AuthStatus status;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.errorMessage,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      errorMessage: errorMessage,
    );
  }
}

/// 認証状態を管理するNotifier
class AuthNotifier extends Notifier<AuthState> {
  final LocalAuthentication _localAuth = LocalAuthentication();

  @override
  AuthState build() {
    return const AuthState();
  }

  /// 生体認証を実行する
  Future<void> authenticate() async {
    // 生体認証の利用可否をチェック
    try {
      final canCheckBiometrics = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();

      if (!canCheckBiometrics || !isDeviceSupported) {
        state = state.copyWith(status: AuthStatus.unsupported);
        return;
      }
    } on PlatformException {
      state = state.copyWith(status: AuthStatus.unsupported);
      return;
    }

    // 認証中に設定
    state = state.copyWith(
      status: AuthStatus.authenticating,
      errorMessage: null,
    );

    // 生体認証を実行
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'アプリのロックを解除してください',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );

      if (authenticated) {
        state = state.copyWith(status: AuthStatus.authenticated);
      } else {
        state = state.copyWith(
          status: AuthStatus.failed,
          errorMessage: '認証に失敗しました',
        );
      }
    } on PlatformException catch (e) {
      state = state.copyWith(
        status: AuthStatus.failed,
        errorMessage: '認証エラーが発生しました: ${e.message}',
      );
    }
  }
}

/// 認証状態のProvider
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  () => AuthNotifier(),
);

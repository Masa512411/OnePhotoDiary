import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/error_codes.dart' as auth_error;
import 'package:local_auth/local_auth.dart';

/// 認証の状態を表すenum
enum AuthStatus {
  initial,        // 初期状態（ロック中）
  authenticating, // 認証中
  authenticated,  // 認証成功
  failed,         // 認証失敗
  unsupported,    // 端末に画面ロックが未設定（保護対象なしとして通す）
}

/// 認証状態を保持するクラス
class AuthState {
  final AuthStatus status;
  final String? errorMessage;

  const AuthState({
    this.status = AuthStatus.initial,
    this.errorMessage,
  });

  /// ロックが解除されているか
  bool get isUnlocked =>
      status == AuthStatus.authenticated || status == AuthStatus.unsupported;

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

/// LocalAuthenticationのProvider（テストで差し替え可能にする）
final localAuthProvider = Provider<LocalAuthentication>(
  (ref) => LocalAuthentication(),
);

/// 認証状態を管理するNotifier
class AuthNotifier extends Notifier<AuthState> {
  LocalAuthentication get _localAuth => ref.read(localAuthProvider);

  @override
  AuthState build() {
    return const AuthState();
  }

  /// 端末認証（生体認証 or パスコード）を実行する
  Future<void> authenticate() async {
    // 認証ダイアログの多重表示を防ぐ
    if (state.status == AuthStatus.authenticating) return;

    // 端末に画面ロックがなければ保護対象なしとして通す
    if (!await _isDeviceSupported()) {
      state = state.copyWith(status: AuthStatus.unsupported);
      return;
    }

    // 認証中に設定
    state = state.copyWith(
      status: AuthStatus.authenticating,
      errorMessage: null,
    );

    // 生体認証が使えない場合はパスコードにフォールバック
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'アプリのロックを解除してください',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
          // trueだとiOSで設定誘導ダイアログ経由の「失敗」になり、エラーコードが取れない
          useErrorDialogs: false,
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
      if (await _isNoScreenLockError(e)) {
        state = state.copyWith(status: AuthStatus.unsupported);
        return;
      }
      state = state.copyWith(
        status: AuthStatus.failed,
        errorMessage: '認証エラーが発生しました: ${e.message}',
      );
    }
  }

  /// ロック状態に戻す（バックグラウンド復帰時の再ロック用）
  void lock() {
    if (!state.isUnlocked) return;
    state = const AuthState();
  }

  /// 端末で認証（生体認証 or パスコード）が利用可能か
  Future<bool> _isDeviceSupported() async {
    try {
      return await _localAuth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// 端末に画面ロックが設定されていないことを示すエラーか
  Future<bool> _isNoScreenLockError(PlatformException e) async {
    if (e.code == auth_error.passcodeNotSet) return true;
    // iOSはシステムによるキャンセル等もNotAvailableになるため、端末の状態を再確認する
    if (e.code == auth_error.notAvailable || e.code == auth_error.notEnrolled) {
      return !await _isDeviceSupported();
    }
    return false;
  }
}

/// 認証状態のProvider
final authProvider = NotifierProvider<AuthNotifier, AuthState>(
  () => AuthNotifier(),
);

/// バックグラウンド復帰時に再ロックするかを判定するクラス
class RelockTimer {
  /// この時間以上バックグラウンドにいたら再ロックする
  /// （カメラや認証ダイアログによる短時間の離脱ではロックしないための猶予）
  static const Duration lockAfter = Duration(seconds: 60);

  final Duration _lockAfter;
  final DateTime Function() _now;
  DateTime? _backgroundedAt;

  RelockTimer({Duration? lockAfter, DateTime Function()? now})
      : _lockAfter = lockAfter ?? RelockTimer.lockAfter,
        _now = now ?? DateTime.now;

  /// バックグラウンドに入った時刻を記録（hidden→pausedの順に来るので最初の時刻を保持）
  void markBackground() {
    _backgroundedAt ??= _now();
  }

  /// 復帰時に呼ぶ。猶予時間を超えていればtrue
  bool shouldLockOnResume() {
    final backgroundedAt = _backgroundedAt;
    _backgroundedAt = null;
    if (backgroundedAt == null) return false;
    return _now().difference(backgroundedAt) >= _lockAfter;
  }
}

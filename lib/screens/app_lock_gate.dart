import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'auth_screen.dart';

/// アプリ全体にロック画面を重ねるゲート
/// MaterialApp.builderで画面スタック（Navigator）の上に置くため、
/// 再ロックしても操作途中の画面はそのまま残る
class AppLockGate extends ConsumerStatefulWidget {
  final Widget child;

  const AppLockGate({super.key, required this.child});

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  late final AppLifecycleListener _lifecycleListener;

  // 一度もロック解除していない間はアプリ本体を生成しない
  bool _hasUnlocked = false;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onHide: _onBackground,
      onPause: _onBackground,
      onResume: _onResume,
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  void _onBackground() {
    // ロック中・認証ダイアログ表示中の離脱は再ロックの対象外
    if (ref.read(authProvider).isUnlocked) {
      ref.read(relockTimerProvider).markBackground();
    }
  }

  void _onResume() {
    final notifier = ref.read(authProvider.notifier);
    final shouldLock = ref.read(relockTimerProvider).shouldLockOnResume();
    if (ref.read(authProvider).status == AuthStatus.unsupported) {
      // 画面ロックなしの端末はロック画面を出さず、画面ロックが設定されたかだけ確認
      notifier.recheckDeviceLock();
    } else if (shouldLock) {
      notifier.lock();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isUnlocked = ref.watch(authProvider.select((s) => s.isUnlocked));
    if (isUnlocked) _hasUnlocked = true;

    if (!_hasUnlocked) return const AuthScreen();

    return Stack(
      children: [
        // ロック中は下の画面を操作・読み上げできないようにする
        ExcludeFocus(
          excluding: !isUnlocked,
          child: ExcludeSemantics(
            excluding: !isUnlocked,
            child: IgnorePointer(
              ignoring: !isUnlocked,
              child: widget.child,
            ),
          ),
        ),
        if (!isUnlocked) const AuthScreen(),
      ],
    );
  }
}

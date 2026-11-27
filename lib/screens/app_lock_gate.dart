import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'auth_screen.dart';

/// アプリ全体にロック画面を重ねるゲート
/// MaterialApp.builderで画面スタック（Navigator）の上に置くため、
/// 再ロックしても操作途中の画面はそのまま残る
class AppLockGate extends ConsumerStatefulWidget {
  final Widget child;

  /// アプリ本体のNavigator（ロック中の戻る操作を止める対象）
  final GlobalKey<NavigatorState> navigatorKey;

  const AppLockGate({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// アプリが前面から外れている間に内容を隠すカバー（テスト用にキーを公開）
  static const privacyCoverKey = ValueKey('privacyCover');

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate> {
  late final AppLifecycleListener _lifecycleListener;

  // 一度もロック解除していない間はアプリ本体を生成しない
  bool _hasUnlocked = false;

  // アプリ切り替え画面や復帰直後に内容が見えないよう覆っているか
  bool _privacyCovered = false;

  // ロック中に下の画面が戻る操作で閉じないよう、最前面の画面に登録する
  // ロック画面はNavigatorの外にあるためPopScopeでは止められない
  final _lockPopEntry = _LockPopEntry();
  ModalRoute<Object?>? _guardedRoute;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onInactive: _onInactive,
      onHide: _onBackground,
      onPause: _onBackground,
      onResume: _onResume,
    );
    ref.listenManual(authProvider.select((s) => s.isUnlocked), (_, _) {
      // ロック画面を描画した後の画面スタックに対して付け外しする
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(authProvider).isUnlocked) {
          _releaseBack();
        } else {
          _guardBack();
        }
      });
    });
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    _releaseBack();
    _lockPopEntry.dispose();
    super.dispose();
  }

  void _coverContent() {
    // ロック中（認証ダイアログ表示中を含む）はロック画面が出ているので覆わない
    if (_privacyCovered || !ref.read(authProvider).isUnlocked) return;
    setState(() => _privacyCovered = true);
  }

  void _onInactive() {
    // iOSはアプリ切り替え画面のスナップショットがinactiveの間に撮られるので、ここで覆う
    // Androidは通知シェードや権限ダイアログ、分割画面でもinactiveになるため覆わない
    // （最近のアプリ一覧はAPI 33以上ならMainActivityで非表示にしている）
    if (defaultTargetPlatform == TargetPlatform.iOS) _coverContent();
  }

  void _onBackground() {
    _coverContent();
    // ロック中・認証ダイアログ表示中の離脱は再ロックの対象外
    if (ref.read(authProvider).isUnlocked) {
      ref.read(relockTimerProvider).markBackground();
    }
  }

  Future<void> _onResume() async {
    final notifier = ref.read(authProvider.notifier);
    final shouldLock = ref.read(relockTimerProvider).shouldLockOnResume();
    if (ref.read(authProvider).status == AuthStatus.unsupported) {
      // 画面ロックなしの端末はロック画面を出さず、画面ロックが設定されたかだけ確認
      // 離脱中に画面ロックが設定されていたら、ロック画面に切り替わるまで覆ったままにする
      await notifier.recheckDeviceLock();
      if (!mounted) return;
      // 確認中に再び前面から外れていたら覆ったままにする
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
    } else if (shouldLock) {
      notifier.lock();
    }
    // ロックする場合も同じフレームでロック画面に切り替わるので、内容は見えない
    if (_privacyCovered) setState(() => _privacyCovered = false);
  }

  /// ロック中は画面スタックの最前面の画面を戻る操作で閉じられないようにする
  /// （システムの戻るボタン・予測型「戻る」ジェスチャーのどちらも止まる）
  void _guardBack() {
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return;
    Route<dynamic>? top;
    // 条件が最前面で成立するので何も閉じずに最前面の画面だけ取得できる
    navigator.popUntil((route) {
      top = route;
      return true;
    });
    final route = top;
    if (route is! ModalRoute<Object?> || identical(route, _guardedRoute)) {
      return;
    }
    // 付け外しで発生する通知から再度呼ばれるので、先に登録先を更新しておく
    final previous = _guardedRoute;
    _guardedRoute = route;
    _unregisterFrom(previous);
    route.registerPopEntry(_lockPopEntry);
  }

  void _releaseBack() {
    final route = _guardedRoute;
    _guardedRoute = null;
    _unregisterFrom(route);
  }

  void _unregisterFrom(ModalRoute<Object?>? route) {
    // 既に閉じた画面には何もしない
    if (route != null && route.isActive) {
      route.unregisterPopEntry(_lockPopEntry);
    }
  }

  bool _onNavigationNotification(NavigationNotification notification) {
    if (ref.read(authProvider).isUnlocked) return false;
    // ロック中に画面スタックが変わったら、新しい最前面の画面で止め直す
    _guardBack();
    if (notification.canHandlePop) return false;
    // ロック中は戻る操作を常にFlutter側で受け取って止める
    // （OSに任せるとアプリが閉じて操作途中の画面が失われることがある）
    const NavigationNotification(canHandlePop: true).dispatch(context);
    return true;
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
              child: NotificationListener<NavigationNotification>(
                onNotification: _onNavigationNotification,
                child: widget.child,
              ),
            ),
          ),
        ),
        if (!isUnlocked) const AuthScreen(),
        // 入力中のフォーカスを外さないよう、下の画面には手を加えず上から覆う
        if (_privacyCovered)
          const Positioned.fill(
            child: ColoredBox(
              key: AppLockGate.privacyCoverKey,
              color: Colors.white,
            ),
          ),
      ],
    );
  }
}

/// 戻る操作で画面を閉じさせないPopEntry
class _LockPopEntry extends PopEntry<Object?> {
  final ValueNotifier<bool> _canPop = ValueNotifier(false);

  @override
  ValueNotifier<bool> get canPopNotifier => _canPop;

  void dispose() => _canPop.dispose();
}

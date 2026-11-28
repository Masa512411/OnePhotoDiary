import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/calendar_provider.dart';
import 'providers/diary_provider.dart';
import 'providers/photo_provider.dart';
import 'providers/reminder_provider.dart';
import 'screens/app_lock_gate.dart';
import 'screens/camera_screen.dart';
import 'screens/editor_screen.dart';
import 'screens/home_screen.dart';
import 'screens/selection_screen.dart';
import 'services/backup_service.dart';
import 'services/install_guard.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 再インストール時にKeychainに残った古いデータを、Providerが読み込む前に消去する
  await InstallGuard.run();
  await NotificationService.instance.init();
  final container = ProviderContainer();
  // ロック解除を待たずに起動時点でリマインダーを読み込み、予約を延長する
  container.read(reminderProvider);
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
  // 以前に書き出したまま残っているバックアップ（暗号化されていない）を片付ける
  _deleteStaleBackupExports();
}

Future<void> _deleteStaleBackupExports() async {
  try {
    await BackupService.deleteOldExports(
      await getTemporaryDirectory(),
      olderThan: BackupService.staleExportAge,
    );
  } catch (_) {
    // 片付けられなくても起動には影響しないため無視する
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One Photo Diary',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      navigatorKey: navigatorKey,
      home: const HomeScreen(),
      // 画面スタックの上にロック画面を重ねる
      builder: (context, child) => AppLockGate(
        navigatorKey: navigatorKey,
        child: ReminderTapHandler(navigatorKey: navigatorKey, child: child!),
      ),
    );
  }
}

/// リマインダー通知のタップで「今日の撮影」画面を開く
///
/// AppLockGate の内側に置くため、一度ロック解除するまでは生成されない。
/// バックグラウンドからのタップは復帰時の再ロックより先に届くことがあるので、
/// 受け取った時点では遷移せず、前面にいてロック解除されていることを
/// フレーム描画後に確かめてから開く（ロック画面の裏で開かないようにする）
class ReminderTapHandler extends ConsumerStatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const ReminderTapHandler({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  @override
  ConsumerState<ReminderTapHandler> createState() => _ReminderTapHandlerState();
}

class _ReminderTapHandlerState extends ConsumerState<ReminderTapHandler> {
  late final NotificationService _notifications;
  late final AppLifecycleListener _lifecycleListener;

  // 判定用のフレームコールバックを登録済みか
  bool _checkScheduled = false;

  // 記録済みの確認から遷移までの間true（連続タップで二重に開かない）
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _notifications = ref.read(notificationServiceProvider);
    _notifications.reminderTapPending.addListener(_scheduleCheck);
    _lifecycleListener = AppLifecycleListener(onResume: _scheduleCheck);
    ref.listenManual(authProvider.select((s) => s.isUnlocked), (_, unlocked) {
      if (unlocked) _scheduleCheck();
    });
    // 起動時のタップは、初回のロック解除でこの画面が生成された時点で保留されている
    _scheduleCheck();
  }

  @override
  void dispose() {
    _notifications.reminderTapPending.removeListener(_scheduleCheck);
    _lifecycleListener.dispose();
    super.dispose();
  }

  void _scheduleCheck() {
    if (_checkScheduled || !_notifications.reminderTapPending.value) return;
    _checkScheduled = true;
    // 復帰時の再ロックとロック画面の描画が済んでから判定する
    // （バックグラウンド中はフレームが止まるので、前面に戻るまで待つことになる）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      _openCameraIfReady();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  /// 前面にいて、ロック解除済みで、画面スタックが使えるか
  bool _isReady() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ref.read(authProvider).isUnlocked &&
        widget.navigatorKey.currentState != null;
  }

  Future<void> _openCameraIfReady() async {
    if (!mounted || _opening || !_isReady()) return;
    _opening = true;
    Future<void>? cameraClosed;
    try {
      // 起動直後は日付一覧の読み込みが終わっていないことがあるため、ストレージで確かめる
      bool recorded;
      try {
        recorded = await ref.read(diaryProvider.notifier).hasEntryToday();
      } catch (e) {
        debugPrint('今日の記録の確認に失敗しました: $e');
        recorded = false;
      }
      // 確認中に再ロック・離脱した場合は、戻ってきたときに改めて判定する
      if (!mounted || !_isReady()) return;
      if (!_notifications.consumeReminderTap()) return;

      final navigator = widget.navigatorKey.currentState!;
      // 撮影から保存までの画面を開いている間は重ねて開かない（連続タップも含む）
      // （閉じると取り込んだ写真を削除する画面もあるため、閉じて開き直すこともしない）
      if (_isRecordingFlowOpen(navigator)) return;

      if (recorded) {
        // 今日は記録済みなので撮影画面へは進まず、今日の記録を表示する
        // （ホーム以外の画面を開いている場合は、戻ったときに今日が選ばれている）
        final now = DateTime.now();
        ref.read(calendarProvider.notifier).selectDay(now, now);
        return;
      }
      cameraClosed = navigator.push(
        MaterialPageRoute(builder: (context) => const CameraScreen()),
      );
    } finally {
      _opening = false;
    }
    await cameraClosed;
    // ホームの撮影ボタンから開いたときと同じく、撮影済み写真を読み込み直す
    if (mounted) ref.read(pendingPhotosProvider.notifier).reload();
  }

  /// 撮影・選択・編集の画面が画面スタックにあるか
  /// 下に隠れた画面も状態を保ったまま木に残っているので、要素をたどって探す
  static bool _isRecordingFlowOpen(NavigatorState navigator) {
    var found = false;
    void visit(Element element) {
      if (found) return;
      final widget = element.widget;
      if (widget is CameraScreen ||
          widget is SelectionScreen ||
          widget is EditorScreen) {
        found = true;
        return;
      }
      element.visitChildElements(visit);
    }

    navigator.context.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

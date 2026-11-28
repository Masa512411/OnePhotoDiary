import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'providers/reminder_provider.dart';
import 'screens/app_lock_gate.dart';
import 'screens/home_screen.dart';
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
      builder: (context, child) =>
          AppLockGate(navigatorKey: navigatorKey, child: child!),
    );
  }
}

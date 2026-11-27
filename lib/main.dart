import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'screens/app_lock_gate.dart';
import 'screens/home_screen.dart';
import 'services/install_guard.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 再インストール時にKeychainに残った古いデータを、Providerが読み込む前に消去する
  await InstallGuard.run();
  await NotificationService.instance.init();
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'One Photo Diary',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      // 画面スタックの上にロック画面を重ねる
      builder: (context, child) => AppLockGate(child: child!),
    );
  }
}

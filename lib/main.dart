import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/reminder_provider.dart';
import 'screens/app_lock_gate.dart';
import 'screens/home_screen.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.init();
  final container = ProviderContainer();
  // ロック解除を待たずに起動時点でリマインダーを読み込み、予約を延長する
  container.read(reminderProvider);
  runApp(UncontrolledProviderScope(container: container, child: const MyApp()));
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

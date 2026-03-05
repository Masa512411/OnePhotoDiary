import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'home_screen.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  @override
  void initState() {
    super.initState();
    // 画面表示後に認証を開始
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(authProvider.notifier).authenticate();
    });
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    // 認証成功 or 非対応 → ホーム画面へ遷移
    ref.listen<AuthState>(authProvider, (previous, next) {
      if (next.status == AuthStatus.authenticated ||
          next.status == AuthStatus.unsupported) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const HomeScreen()),
        );
      }
    });

    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // アプリアイコン
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: Colors.blueGrey.shade50,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.photo_camera,
                  size: 48,
                  color: Colors.blueGrey.shade400,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'One Photo Diary',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 48),

              // 認証中のインジケーター
              if (authState.status == AuthStatus.authenticating) ...[
                const CircularProgressIndicator(
                  color: Colors.blueGrey,
                ),
                const SizedBox(height: 16),
                const Text(
                  '認証中...',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 16,
                  ),
                ),
              ],

              // エラーメッセージ + リトライボタン
              if (authState.status == AuthStatus.failed) ...[
                Icon(
                  Icons.fingerprint,
                  size: 64,
                  color: Colors.blueGrey.shade300,
                ),
                const SizedBox(height: 16),
                Text(
                  authState.errorMessage ?? '認証に失敗しました',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () {
                    ref.read(authProvider.notifier).authenticate();
                  },
                  icon: const Icon(Icons.fingerprint),
                  label: const Text('もう一度認証する'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],

              // 初期状態（認証前）
              if (authState.status == AuthStatus.initial) ...[
                Icon(
                  Icons.fingerprint,
                  size: 64,
                  color: Colors.blueGrey.shade300,
                ),
                const SizedBox(height: 16),
                const Text(
                  '指紋認証でロックを解除',
                  style: TextStyle(
                    color: Colors.black54,
                    fontSize: 16,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

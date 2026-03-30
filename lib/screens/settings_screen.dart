import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          _SectionHeader(title: 'テーマ'),
          RadioGroup<AppThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (v) {
              if (v != null) {
                ref.read(settingsProvider.notifier).setThemeMode(v);
              }
            },
            child: Column(
              children: const [
                RadioListTile<AppThemeMode>(
                  title: Text('システム設定に従う'),
                  value: AppThemeMode.system,
                ),
                RadioListTile<AppThemeMode>(
                  title: Text('ライト'),
                  value: AppThemeMode.light,
                ),
                RadioListTile<AppThemeMode>(
                  title: Text('ダーク'),
                  value: AppThemeMode.dark,
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          _SectionHeader(title: 'データ管理'),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text(
              'すべてのデータを削除',
              style: TextStyle(color: Colors.red),
            ),
            subtitle: const Text('日記・写真・未選択の写真をすべて削除します'),
            onTap: () => _confirmDeleteAll(context, ref),
          ),
          const Divider(height: 32),
          _SectionHeader(title: 'アプリ情報'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('バージョン'),
            trailing: Text('1.0.0', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('データを削除'),
        content: const Text(
          'すべての日記・写真データが削除されます。\nこの操作は取り消せません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除する'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await ref.read(diaryProvider.notifier).deleteAllData();
    await ref.read(pendingPhotosProvider.notifier).clear();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('すべてのデータを削除しました')),
      );
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

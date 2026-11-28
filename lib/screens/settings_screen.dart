import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../providers/diary_provider.dart';
import '../providers/reminder_provider.dart';
import '../services/backup_service.dart';
import '../services/photo_storage.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// バックアップの書き出し・復元の処理中か（ボタンの無効化とインジケーター表示に使う）
  bool _isBackupBusy = false;

  @override
  void initState() {
    super.initState();
    _deleteStaleExports();
  }

  /// 以前に書き出したまま残っているzipを片付ける
  /// （暗号化されていないため、次回の書き出しまで残さない）
  static Future<void> _deleteStaleExports() async {
    try {
      await BackupService.deleteOldExports(
        await getTemporaryDirectory(),
        olderThan: BackupService.staleExportAge,
      );
    } catch (_) {
      // 片付けられなくても設定画面の動作には影響しないため無視する
    }
  }

  String _formatTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickTime() async {
    final current = ref.read(reminderProvider).time;
    final picked = await showTimePicker(
      context: context,
      initialTime: current,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked != null) {
      await ref.read(reminderProvider.notifier).setTime(picked);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String okLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(okLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 処理中の再タップを無視し、処理中はインジケーターを表示する
  Future<void> _runBackupTask(Future<void> Function() task) async {
    if (_isBackupBusy) return;
    setState(() => _isBackupBusy = true);
    try {
      await task();
    } finally {
      if (mounted) setState(() => _isBackupBusy = false);
    }
  }

  /// 日記をzipに書き出し、共有シートで保存先を選んでもらう
  /// [shareOrigin]はiPadで共有シートを表示する位置
  Future<void> _exportBackup(Rect? shareOrigin) => _runBackupTask(() async {
    final ok = await _confirm(
      title: 'バックアップを書き出す',
      content:
          'すべての日記の写真とテキストを1つのファイルに書き出します。\n\n'
          '書き出したファイルは暗号化されません。'
          '保存先（ファイル・Driveなど）は他の人に見られない場所を選んでください。',
      okLabel: '書き出す',
    );
    if (!ok || !mounted) return;

    final BackupExportResult result;
    try {
      result = await BackupService.exportBackup(
        storage: ref.read(diaryStorageProvider),
        documents: await PhotoStorage.documentsDirectory(),
        outputDir: await getTemporaryDirectory(),
      );
    } catch (e) {
      debugPrint('バックアップの書き出しに失敗しました: $e');
      _showMessage('バックアップの書き出しに失敗しました');
      return;
    }
    final file = result.file;
    if (file == null) {
      _showMessage(
        result.complete ? '書き出せる日記がありません' : '日記を読み込めませんでした。時間をおいて再度お試しください',
      );
      return;
    }

    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/zip')],
          sharePositionOrigin: shareOrigin,
        ),
      );
    } catch (e) {
      debugPrint('バックアップの共有に失敗しました: $e');
      _showMessage('バックアップの共有に失敗しました');
      return;
    }
    if (!result.complete) {
      _showMessage('一部の日記を確認できなかったため、書き出しに含まれていない可能性があります');
    } else if (result.skippedCount > 0) {
      _showMessage('写真が見つからないなどの理由で${result.skippedCount}件の日記は書き出せませんでした');
    }
  });

  /// バックアップのzipを選んで復元する
  /// 選んだファイルはアプリの一時領域にコピーされるため、終わったら削除する
  /// （暗号化されていない日記のコピーを端末に残さないため）
  Future<void> _restoreBackup() => _runBackupTask(() async {
    try {
      await _pickAndRestoreBackup();
    } finally {
      try {
        await FilePicker.clearTemporaryFiles();
      } catch (_) {
        // 削除できなくても復元には影響しないため無視する
      }
    }
  });

  Future<void> _pickAndRestoreBackup() async {
    final FilePickerResult? picked;
    try {
      // 拡張子で絞り込むと、Androidでは保存先によってzipを選べないことがあるため
      // 絞り込まずに選んでもらい、中身の検証で判定する
      picked = await FilePicker.pickFiles();
    } catch (e) {
      debugPrint('ファイルの選択に失敗しました: $e');
      _showMessage('ファイルを選択できませんでした');
      return;
    }
    final zipPath = picked?.files.single.path;
    if (zipPath == null || !mounted) return;

    final storage = ref.read(diaryStorageProvider);
    final BackupContents contents;
    final int overlapping;
    try {
      contents = await BackupService.readBackup(zipPath);
      overlapping = await BackupService.countOverlapping(contents, storage);
    } on BackupFormatException catch (e) {
      _showMessage(e.message);
      return;
    } catch (e) {
      debugPrint('バックアップの読み込みに失敗しました: $e');
      _showMessage('バックアップを読み込めませんでした');
      return;
    }
    if (contents.entries.isEmpty) {
      _showMessage(
        contents.skippedFutureCount > 0
            ? 'バックアップの日記はすべて未来の日付のため復元できません'
            : 'バックアップに日記が含まれていません',
      );
      return;
    }
    if (!mounted) return;

    final ok = await _confirm(
      title: 'バックアップから復元',
      content:
          '${contents.entries.length}件の日記を復元します。'
          '${overlapping > 0 ? '\n\nそのうち$overlapping件は保存済みの日記と日付が重なっています。'
                    '同じ日付の日記はバックアップの内容で上書きされます。' : ''}'
          '${contents.skippedFutureCount > 0 ? '\n\n未来の日付の${contents.skippedFutureCount}件は復元しません。' : ''}',
      okLabel: '復元する',
    );
    if (!ok || !mounted) return;

    try {
      await BackupService.restoreBackup(
        contents,
        documents: await PhotoStorage.documentsDirectory(),
        storage: storage,
        importEntries: ref.read(diaryProvider.notifier).importEntries,
      );
    } on BackupFormatException catch (e) {
      _showMessage(e.message);
      return;
    } on FileSystemException catch (e) {
      debugPrint('バックアップの復元に失敗しました: $e');
      _showMessage('復元に失敗しました。端末の空き容量を確認してください');
      return;
    } catch (e) {
      debugPrint('バックアップの復元に失敗しました: $e');
      _showMessage('バックアップの復元に失敗しました');
      return;
    }
    _showMessage('${contents.entries.length}件の日記を復元しました');
  }

  /// ウィジェットの画面上の位置（iPadの共有シートの表示位置に使う）
  static Rect? _originOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    final reminder = ref.watch(reminderProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('設定'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'リマインダー',
              style: TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('毎日の記録をリマインドする'),
            subtitle: const Text('指定した時刻に通知でお知らせします'),
            value: reminder.enabled,
            activeThumbColor: Colors.blueGrey,
            onChanged: (v) => ref.read(reminderProvider.notifier).setEnabled(v),
          ),
          ListTile(
            title: const Text('通知時刻'),
            subtitle: Text(_formatTime(reminder.time)),
            trailing: const Icon(Icons.access_time),
            enabled: reminder.enabled,
            onTap: reminder.enabled ? _pickTime : null,
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'その日にすでに記録済みの場合、通知はスキップされます。',
              style: TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(
              'バックアップ',
              style: TextStyle(
                fontSize: 12,
                color: Colors.black54,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Builder(
            builder: (tileContext) => ListTile(
              title: const Text('書き出す'),
              subtitle: const Text('日記を1つのファイルに保存します'),
              trailing: const Icon(Icons.upload_file),
              enabled: !_isBackupBusy,
              onTap: () => _exportBackup(_originOf(tileContext)),
            ),
          ),
          ListTile(
            title: const Text('バックアップから復元'),
            subtitle: const Text('書き出したファイルから日記を読み込みます'),
            trailing: const Icon(Icons.restore),
            enabled: !_isBackupBusy,
            onTap: _restoreBackup,
          ),
          if (_isBackupBusy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Text(
              '機種変更や端末の紛失に備えて、定期的に書き出しておくことをおすすめします。',
              style: TextStyle(fontSize: 12, color: Colors.black45),
            ),
          ),
        ],
      ),
    );
  }
}

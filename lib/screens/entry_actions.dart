import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/diary_provider.dart';
import '../services/photo_import.dart';
import 'editor_screen.dart';

/// 日記エントリのメニュー（編集・削除）の項目
enum EntryAction { edit, delete }

/// 日記エントリの編集・削除メニュー（Homeの詳細とギャラリーのカードで共通）
class EntryActionsMenu extends ConsumerWidget {
  const EntryActionsMenu({super.key, required this.entry, this.color});

  final DiaryEntry entry;
  final Color? color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<EntryAction>(
      icon: Icon(Icons.more_vert, color: color),
      tooltip: 'メニュー',
      onSelected: (action) {
        switch (action) {
          case EntryAction.edit:
            openEntryEditor(context, entry);
          case EntryAction.delete:
            confirmAndDeleteEntry(context, ref, entry.date);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: EntryAction.edit,
          child: ListTile(
            leading: Icon(Icons.edit_outlined),
            title: Text('編集'),
          ),
        ),
        PopupMenuItem(
          value: EntryAction.delete,
          child: ListTile(
            leading: Icon(Icons.delete_outline),
            title: Text('削除'),
          ),
        ),
      ],
    );
  }
}

/// 編集画面を開く（日付は変えず、一言と写真を変更できる）
Future<void> openEntryEditor(BuildContext context, DiaryEntry entry) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (context) => EditorScreen.edit(entry: entry),
    ),
  );
}

/// 確認ダイアログを出してから指定日のエントリを削除する
Future<void> confirmAndDeleteEntry(
  BuildContext context,
  WidgetRef ref,
  String dateKey,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('削除の確認'),
      content: const Text('この日の日記を削除しますか？'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('キャンセル'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('削除する'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(diaryProvider.notifier).deleteEntry(dateKey);
    messenger.showSnackBar(const SnackBar(content: Text('日記を削除しました')));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('日記の削除に失敗しました')));
  }
}

/// 「カメラで撮る」「アルバムから選ぶ」を選ばせて写真を1枚取り込む
/// 取り込み中は保存中のインジケーターを表示する。キャンセル・失敗時はnull
Future<File?> pickEntryPhoto(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('カメラで撮る'),
            onTap: () => Navigator.of(context).pop(ImageSource.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('アルバムから選ぶ'),
            onTap: () => Navigator.of(context).pop(ImageSource.gallery),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;

  final String? path;
  try {
    path = await PhotoImport.pick(source);
  } catch (e) {
    if (context.mounted) _showError(context, '写真の読み込みに失敗しました: $e');
    return null;
  }
  if (path == null || !context.mounted) return null;

  // 保存が終わるまで操作できないよう、閉じられないダイアログで覆う
  // 保存後は最前面の画面ではなく、このダイアログを指定して閉じる
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const PopScope(
      canPop: false,
      child: Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('写真を保存しています…'),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Navigator.of(context, rootNavigator: true).push(progress);
  try {
    return await PhotoImport.save(path);
  } catch (e) {
    if (context.mounted) _showError(context, '写真の保存に失敗しました: $e');
    return null;
  } finally {
    if (progress.isActive) progress.navigator?.removeRoute(progress);
  }
}

void _showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

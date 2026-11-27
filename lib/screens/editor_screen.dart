import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';

class EditorScreen extends ConsumerStatefulWidget {
  final File selectedPhoto;

  const EditorScreen({super.key, required this.selectedPhoto});

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  final TextEditingController _captionController = TextEditingController();

  /// 保存フロー（確認ダイアログを含む）の実行中か。同一フレーム内の連続タップも弾く
  bool _isBusy = false;

  /// 保存処理中かどうか（ボタンの無効化とインジケーター表示に使う）
  bool _isSaving = false;

  /// 今日の日記が保存済みの場合に上書きしてよいか確認する
  Future<bool> _confirmOverwrite() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上書きの確認'),
        content: const Text('今日の日記は保存済みです。上書きしますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('上書きする'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _saveDiary() async {
    // 保存中・確認ダイアログ表示中の再タップは無視する
    if (_isBusy) return;
    _isBusy = true;

    try {
      // 今日の日記が既にある場合は上書きの確認を取る
      // 日付一覧の読み込み前・失敗時でも確認できるよう、ストレージを直接確認する
      // （確認に失敗した場合は保存失敗として扱う）
      final hasEntryToday =
          await ref.read(diaryProvider.notifier).hasEntryToday();
      if (!mounted) {
        _isBusy = false;
        return;
      }
      if (hasEntryToday) {
        final confirmed = await _confirmOverwrite();
        if (!confirmed || !mounted) {
          _isBusy = false;
          return;
        }
      }

      setState(() => _isSaving = true);
      await ref.read(diaryProvider.notifier).saveEntry(
            photo: widget.selectedPhoto,
            caption: _captionController.text,
          );
    } catch (_) {
      // 失敗時はボタンを再度押せるように戻す
      _isBusy = false;
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日記の保存に失敗しました')),
      );
      return;
    }

    // 保存完了後、未選択の写真をクリアする
    // 日記自体は保存済みなので、クリアに失敗しても保存成功として扱う
    try {
      await ref.read(pendingPhotosProvider.notifier).clear();
    } catch (e) {
      debugPrint('未選択の写真のクリアに失敗しました: $e');
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日記を保存しました！')),
    );
    // 保存後、ホーム画面に戻る（スタックをすべてクリア）
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  void dispose() {
    _captionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 保存中に画面を閉じると結果が分からなくなるため、戻る操作を止める
    return PopScope(
      canPop: !_isSaving,
      child: _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        // 保存中は戻るボタンを無効化する
        leading: _isSaving
            ? const IconButton(icon: BackButtonIcon(), onPressed: null)
            : null,
        title: const Text('記録する'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
      ),
      // キーボードが表示されたときにスクロールできるようにする
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'selected_photo',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  widget.selectedPhoto,
                  width: double.infinity,
                  height: 300,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    width: double.infinity,
                    height: 300,
                    color: Colors.grey[200],
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image_outlined,
                        color: Colors.black26, size: 48),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),
            const Text(
              '今日の一言',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _captionController,
              maxLength: 140,
              maxLines: 5,
              decoration: InputDecoration(
                hintText: 'どんな一日でしたか？',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Colors.grey[100],
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                // 保存中は無効化して二重保存を防ぐ
                onPressed: _isSaving ? null : _saveDiary,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey,
                  foregroundColor: Colors.white,
                  // 保存中（無効化中）も見た目を保ちインジケーターを見やすくする
                  disabledBackgroundColor: Colors.blueGrey,
                  disabledForegroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('保存する'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

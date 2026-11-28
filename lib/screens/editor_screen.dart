import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import '../providers/diary_provider.dart';
import '../providers/photo_provider.dart';
import 'entry_actions.dart';

/// 日記を記録・編集する画面
///
/// - 今日の記録（[date]なし）: 撮影済み写真から選んだ写真で今日の日記を保存する
/// - 過去日の記録（[date]あり）: 取り込んだ写真でその日の日記を保存する
/// - 編集（[EditorScreen.edit]）: 日付は変えずに一言と写真を変更する
class EditorScreen extends ConsumerStatefulWidget {
  final File selectedPhoto;

  /// 記録する日付（yyyy-MM-dd）。nullなら今日
  final String? date;

  /// 一言の初期値（編集時は保存済みの一言）
  final String initialCaption;

  /// 保存済みエントリの編集か（上書き確認をしない）
  final bool isEdit;

  /// [selectedPhoto]が撮影済み写真ではなく、この記録のために取り込んだ写真か
  /// （保存せずに閉じた場合に削除する）
  final bool photoIsImported;

  const EditorScreen({
    super.key,
    required this.selectedPhoto,
    this.date,
    this.photoIsImported = false,
  })  : initialCaption = '',
        isEdit = false;

  EditorScreen.edit({super.key, required DiaryEntry entry})
      : selectedPhoto = entry.photo,
        date = entry.date,
        initialCaption = entry.caption,
        isEdit = true,
        photoIsImported = false;

  /// 今日の記録（撮影済み写真から選ぶフロー）か
  bool get isTodayFlow => date == null;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen> {
  late final TextEditingController _captionController =
      TextEditingController(text: widget.initialCaption);

  /// 保存する写真（差し替えると変わる）
  late File _photo = widget.selectedPhoto;

  /// この画面のために取り込んだ写真（閉じるときに、保存に使われなかったものを削除する）
  late final List<File> _importedPhotos = [
    if (widget.photoIsImported) widget.selectedPhoto,
  ];

  /// 写真の後片付けに使うストレージ（dispose時はrefを使えないため先に取得する）
  late final FlutterSecureStorage _storage;

  /// 保存フロー（確認ダイアログを含む）の実行中か。同一フレーム内の連続タップも弾く
  bool _isBusy = false;

  /// 保存処理中かどうか（ボタンの無効化とインジケーター表示に使う）
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _storage = ref.read(diaryStorageProvider);
  }

  /// 記録する日の日記が保存済みの場合に上書きしてよいか確認する
  Future<bool> _confirmOverwrite() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('上書きの確認'),
        content: Text(widget.isTodayFlow
            ? '今日の日記は保存済みです。上書きしますか？'
            : 'この日の日記は保存済みです。上書きしますか？'),
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
      // 記録する日の日記が既にある場合は上書きの確認を取る（編集時は同じ日記なので不要）
      // 日付一覧の読み込み前・失敗時でも確認できるよう、ストレージを直接確認する
      // （確認に失敗した場合は保存失敗として扱う）
      final notifier = ref.read(diaryProvider.notifier);
      final hasEntry = widget.isEdit
          ? false
          : widget.date == null
              ? await notifier.hasEntryToday()
              : await notifier.hasEntryOn(widget.date!);
      if (!mounted) {
        _isBusy = false;
        return;
      }
      if (hasEntry) {
        final confirmed = await _confirmOverwrite();
        if (!confirmed || !mounted) {
          _isBusy = false;
          return;
        }
      }

      setState(() => _isSaving = true);
      await ref.read(diaryProvider.notifier).saveEntry(
            photo: _photo,
            caption: _captionController.text,
            date: widget.date,
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

    // 今日の記録では、保存完了後に未選択の写真をクリアする
    // （過去日の記録・編集では今日の撮影済み写真を消さないようクリアしない）
    // 日記自体は保存済みなので、クリアに失敗しても保存成功として扱う
    if (widget.isTodayFlow) {
      try {
        await ref.read(pendingPhotosProvider.notifier).clear();
      } catch (e) {
        debugPrint('未選択の写真のクリアに失敗しました: $e');
      }
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日記を保存しました！')),
    );
    if (widget.isTodayFlow) {
      // 保存後、ホーム画面に戻る（スタックをすべてクリア）
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      // 開いた画面（ホーム・ギャラリー）に戻る
      Navigator.of(context).pop();
    }
  }

  /// 写真を差し替える（カメラ・アルバムから取り込む）
  Future<void> _changePhoto() async {
    if (_isBusy) return;
    _isBusy = true;
    try {
      final photo = await pickEntryPhoto(context, ref);
      if (photo == null || !mounted) return;
      setState(() {
        _photo = photo;
        _importedPhotos.add(photo);
      });
    } finally {
      _isBusy = false;
    }
  }

  @override
  void dispose() {
    _captionController.dispose();
    // 取り込んだが保存に使われなかった写真を削除する
    // 保存済みのエントリが参照している写真は削除されない
    if (_importedPhotos.isNotEmpty) {
      deletePhotosIfUnreferenced(_importedPhotos, storage: _storage);
    }
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
        title: Text(widget.isEdit ? '編集する' : '記録する'),
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
            if (!widget.isTodayFlow) ...[
              Text(
                DateFormat('yyyy年MM月dd日 (E)', 'ja_JP')
                    .format(DateTime.parse(widget.date!)),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
            ],
            Hero(
              tag: 'selected_photo',
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  _photo,
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
            if (!widget.isTodayFlow)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _isSaving ? null : _changePhoto,
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('写真を変更'),
                ),
              ),
            SizedBox(height: widget.isTodayFlow ? 32 : 16),
            Text(
              widget.isTodayFlow ? '今日の一言' : 'この日の一言',
              style: const TextStyle(
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

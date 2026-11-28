import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../providers/photo_provider.dart';
import 'selection_screen.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  // カメラ・アルバム起動から保存完了までtrue（二重操作を防ぐ）
  bool _busy = false;
  // カメラ・アルバムから戻って写真を保存している間true（保存中の表示を出す）
  bool _saving = false;

  /// カメラで撮影、またはアルバムから選んだ写真を撮影済み写真として保存する
  Future<void> _addPhotos(ImageSource source) async {
    if (_busy) return;
    setState(() => _busy = true);
    final notifier = ref.read(pendingPhotosProvider.notifier);
    try {
      final List<String> paths;
      var skipped = 0;
      try {
        (:paths, :skipped) = await notifier.pickPhoto(source: source);
      } catch (e) {
        _showError(
          source == ImageSource.camera
              ? 'カメラの起動に失敗しました: $e'
              : 'アルバムを開けませんでした: $e',
        );
        return;
      }
      if (paths.isEmpty) return;

      // 選んだ写真を失わないよう、画面を離れていても保存は行う
      if (mounted) setState(() => _saving = true);
      // 1枚の保存に失敗しても、残りの写真は保存する
      Object? error;
      for (final path in paths) {
        try {
          // 保存中に上限に達した場合はnullが返り、その写真は取り込まない
          if (await notifier.addPhoto(path) == null) skipped++;
        } catch (e) {
          error ??= e;
        }
      }
      if (error != null) {
        _showError('写真の保存に失敗しました: $error');
      } else if (skipped > 0) {
        _showError(
          '撮影済み写真は${PhotoNotifier.maxPhotos}枚までのため、'
          '$skipped枚は取り込みませんでした',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _saving = false;
        });
      }
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 「撮影する」「アルバムから選ぶ」のボタン（同じ見た目で並べる）
  Widget _buildAddButton({
    required VoidCallback onPressed,
    required IconData icon,
    required String label,
  }) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton.icon(
        onPressed: _busy ? null : onPressed,
        icon: Icon(icon),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.blueGrey,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final takenPhotos = ref.watch(pendingPhotosProvider);
    final maxPhotos = PhotoNotifier.maxPhotos;

    return PopScope(
      // 保存中に画面を離れると、保存した写真が表示されないまま戻ってしまうため
      canPop: !_saving,
      child: Stack(
        children: [
          _buildContent(context, takenPhotos, maxPhotos),
          if (_saving) const _SavingOverlay(),
        ],
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    List<File> takenPhotos,
    int maxPhotos,
  ) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日の撮影'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
      ),
      body: Column(
        children: [
          const SizedBox(height: 20),
          Text(
            '${takenPhotos.length} / $maxPhotos',
            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w300),
          ),
          const Text('枚撮影済み', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 40),
          Expanded(
            child: takenPhotos.isEmpty
                ? const _EmptyHint()
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                    itemCount: takenPhotos.length,
                    itemBuilder: (context, index) {
                      return Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              takenPhotos[index],
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: double.infinity,
                              errorBuilder: (_, _, _) => Container(
                                width: double.infinity,
                                height: double.infinity,
                                color: Colors.grey[200],
                                alignment: Alignment.center,
                                child: const Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.black26,
                                  size: 48,
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '${index + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              children: [
                // 上限に達したら撮影・アルバムの両方を隠す
                if (takenPhotos.length < maxPhotos) ...[
                  _buildAddButton(
                    onPressed: () => _addPhotos(ImageSource.camera),
                    icon: Icons.camera_alt,
                    label: '撮影する',
                  ),
                  const SizedBox(height: 16),
                  _buildAddButton(
                    onPressed: () => _addPhotos(ImageSource.gallery),
                    icon: Icons.photo_library,
                    label: 'アルバムから選ぶ',
                  ),
                ],
                if (takenPhotos.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(
                                  builder: (context) =>
                                      SelectionScreen(photos: takenPhotos),
                                ),
                              );
                            },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.blueGrey),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      child: const Text(
                        '今日の一枚を選ぶ',
                        style: TextStyle(color: Colors.blueGrey),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 写真が1枚もないときにグリッドの代わりに表示する案内
class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.photo_camera_outlined, size: 64, color: Colors.black26),
          SizedBox(height: 12),
          Text('撮影するか、アルバムから選んでください', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

/// 撮影した写真を保存している間、画面全体を覆って表示するインジケーター
class _SavingOverlay extends StatelessWidget {
  const _SavingOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const ModalBarrier(dismissible: false, color: Colors.black38),
        Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('写真を保存しています…'),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

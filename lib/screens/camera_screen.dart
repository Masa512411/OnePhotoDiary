import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/photo_provider.dart';
import 'selection_screen.dart';

class CameraScreen extends ConsumerStatefulWidget {
  const CameraScreen({super.key});

  @override
  ConsumerState<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends ConsumerState<CameraScreen> {
  // カメラ起動から保存完了までtrue（二重操作を防ぐ）
  bool _busy = false;
  // カメラから戻って写真を保存している間true（保存中の表示を出す）
  bool _saving = false;

  Future<void> _takePhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    final notifier = ref.read(pendingPhotosProvider.notifier);
    try {
      final String? path;
      try {
        path = await notifier.pickPhoto();
      } catch (e) {
        _showError('カメラの起動に失敗しました: $e');
        return;
      }
      if (path == null) return;

      // 撮影した写真を失わないよう、画面を離れていても保存は行う
      if (mounted) setState(() => _saving = true);
      try {
        await notifier.addPhoto(path);
      } catch (e) {
        _showError('写真の保存に失敗しました: $e');
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
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
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
                if (takenPhotos.length < maxPhotos)
                  SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _takePhoto,
                      icon: const Icon(Icons.camera_alt),
                      label: const Text('撮影する'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueGrey,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                    ),
                  ),
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

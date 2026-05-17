import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import '../providers/diary_provider.dart';

class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  @override
  void initState() {
    super.initState();
    initializeDateFormatting('ja_JP');
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(allDiaryEntriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('フォトギャラリー'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: entriesAsync.when(
        data: (entries) {
          if (entries.isEmpty) return _buildEmptyState();
          return ListView.builder(
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: entries.length,
            itemBuilder: (context, index) => _buildEntryCard(entries[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('読み込みエラー: $e')),
      ),
    );
  }

  Widget _buildEntryCard(DiaryEntry entry) {
    final date = DateTime.parse(entry.date);
    final dateLabel = DateFormat('yyyy年MM月dd日 (E)', 'ja_JP').format(date);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dateLabel,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.black54,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () => _openFullscreen(entry),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                entry.photo,
                width: double.infinity,
                height: 280,
                fit: BoxFit.cover,
              ),
            ),
          ),
          if (entry.caption.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              entry.caption,
              style: const TextStyle(
                fontSize: 15,
                height: 1.6,
                color: Colors.black87,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Divider(),
        ],
      ),
    );
  }

  void _openFullscreen(DiaryEntry entry) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _FullscreenPhotoScreen(entry: entry),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.photo_library_outlined, size: 64, color: Colors.black12),
          SizedBox(height: 16),
          Text(
            'まだ記録がありません',
            style: TextStyle(color: Colors.black38, fontSize: 16),
          ),
        ],
      ),
    );
  }
}

class _FullscreenPhotoScreen extends StatelessWidget {
  const _FullscreenPhotoScreen({required this.entry});

  final DiaryEntry entry;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.parse(entry.date);
    final dateLabel = DateFormat('yyyy年MM月dd日 (E)', 'ja_JP').format(date);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(dateLabel, style: const TextStyle(fontSize: 15)),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: InteractiveViewer(
                child: Center(
                  child: Image.file(entry.photo, fit: BoxFit.contain),
                ),
              ),
            ),
            if (entry.caption.isNotEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                color: Colors.black87,
                child: Text(
                  entry.caption,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.6,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

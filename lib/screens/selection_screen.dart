import 'dart:io';
import 'package:flutter/material.dart';
import 'editor_screen.dart';

class SelectionScreen extends StatefulWidget {
  final List<File> photos;

  const SelectionScreen({super.key, required this.photos});

  @override
  State<SelectionScreen> createState() => _SelectionScreenState();
}

class _SelectionScreenState extends State<SelectionScreen> {
  int? _selectedIndex;

  void _proceedToEditor() {
    if (_selectedIndex != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => EditorScreen(
            selectedPhoto: widget.photos[_selectedIndex!],
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('今日の一枚を選ぶ'),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: Colors.black87,
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '今日撮った写真から、一番残したいものを選んでください。',
              style: TextStyle(fontSize: 16, color: Colors.black54),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 1, // 1枚ずつ大きく表示して縦スクロール、または2列
                mainAxisSpacing: 16,
                childAspectRatio: 4 / 3,
              ),
              itemCount: widget.photos.length,
              itemBuilder: (context, index) {
                final isSelected = _selectedIndex == index;
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedIndex = index;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? Colors.blueGrey : Colors.transparent,
                        width: isSelected ? 4 : 0,
                      ),
                      boxShadow: [
                        if (isSelected)
                          BoxShadow(
                            color: Colors.blueGrey.withOpacity(0.3),
                            blurRadius: 10,
                            spreadRadius: 2,
                          )
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            widget.photos[index],
                            fit: BoxFit.cover,
                          ),
                          if (isSelected)
                            Container(
                              color: Colors.black.withOpacity(0.2),
                              child: const Center(
                                child: Icon(
                                  Icons.check_circle,
                                  color: Colors.white,
                                  size: 48,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(32.0),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _selectedIndex != null ? _proceedToEditor : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blueGrey,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28),
                  ),
                ),
                child: const Text('この写真にする'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

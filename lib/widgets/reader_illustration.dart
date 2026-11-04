import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../models/reader_illustration.dart';
import '../services/reader_cache_service.dart';

class ReaderIllustrationView extends StatefulWidget {
  final String bookId;
  final ReaderIllustration image;
  final double height;
  final Color textColor;
  final Future<Directory> Function()? documents;
  final VoidCallback? onTapDown;
  final ValueChanged<bool>? onViewerChanged;
  final Future<void> Function()? onRetry;
  const ReaderIllustrationView({
    super.key,
    required this.bookId,
    required this.image,
    required this.height,
    required this.textColor,
    this.documents,
    this.onTapDown,
    this.onViewerChanged,
    this.onRetry,
  });
  @override
  State<ReaderIllustrationView> createState() => _ReaderIllustrationViewState();
}

class _ReaderIllustrationViewState extends State<ReaderIllustrationView> {
  bool _retrying = false;
  late Future<File?> _file = _resolve();
  Future<File?> _resolve() async {
    final asset = widget.image.asset;
    if (asset == null || !ReaderIllustration.assetPattern.hasMatch(asset)) {
      return null;
    }
    final root = await (widget.documents ?? ReaderCacheService().documents)();
    for (final tree in ['offline_books', 'reader_cache_v2']) {
      final book = Directory(
        '${root.path}/$tree/${ReaderCacheService.segment(widget.bookId)}',
      );
      final images = Directory('${book.path}/images');
      final file = File('${book.path}/$asset');
      if (await FileSystemEntity.isLink(book.path) ||
          await FileSystemEntity.isLink(images.path) ||
          await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
        continue;
      }
      final size = await file.length();
      if (size > 0 && size <= 8 * 1024 * 1024) return file;
    }
    return null;
  }

  @override
  void didUpdateWidget(covariant ReaderIllustrationView old) {
    super.didUpdateWidget(old);
    if (old.bookId != widget.bookId ||
        old.image.asset != widget.image.asset ||
        old.image.error != widget.image.error) {
      _file = _resolve();
    }
  }

  Widget _missing() => GestureDetector(
    onTap: widget.onRetry == null || _retrying
        ? null
        : () async {
            setState(() => _retrying = true);
            try {
              await widget.onRetry!();
              _file = _resolve();
            } finally {
              if (mounted) setState(() => _retrying = false);
            }
          },
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          '${widget.image.error ?? '插图缺失或无法显示'}${widget.image.alt.isEmpty ? '' : '\n${widget.image.alt}'}'
          '${widget.onRetry == null
              ? ''
              : _retrying
              ? '\n正在重试…'
              : '\n点击重试'}',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: widget.textColor),
        ),
      ),
    ),
  );

  Widget _image(File file, {bool zoom = false}) {
    if (file.path.endsWith('.svg')) {
      return SvgPicture.file(
        file,
        fit: BoxFit.contain,
        semanticsLabel: widget.image.alt,
        placeholderBuilder: (_) =>
            const Center(child: CircularProgressIndicator()),
        errorBuilder: (_, _, _) => _missing(),
      );
    }
    final maxSide = zoom ? 2048.0 : 1200.0;
    final ratio = math.min(
      1.0,
      math.min(maxSide / widget.image.width, maxSide / widget.image.height),
    );
    return Image.file(
      file,
      fit: BoxFit.contain,
      cacheWidth: math.max(1, (widget.image.width * ratio).round()),
      cacheHeight: math.max(1, (widget.image.height * ratio).round()),
      semanticLabel: widget.image.alt,
      errorBuilder: (_, _, _) => _missing(),
    );
  }

  Future<void> _zoom(File file) async {
    widget.onViewerChanged?.call(true);
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: SafeArea(
            child: Stack(
              children: [
                Positioned.fill(
                  child: InteractiveViewer(
                    minScale: .5,
                    maxScale: 6,
                    child: Center(child: _image(file, zoom: true)),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    tooltip: '关闭图片',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      widget.onViewerChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: ValueKey('epub-image-${widget.image.id}'),
    height: widget.height,
    width: double.infinity,
    child: FutureBuilder<File?>(
      future: _file,
      builder: (context, snapshot) {
        if (widget.image.error != null || snapshot.hasError) return _missing();
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final file = snapshot.data;
        if (file == null) return _missing();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => widget.onTapDown?.call(),
          onTap: () => _zoom(file),
          child: _image(file),
        );
      },
    ),
  );
}

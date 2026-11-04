import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../main.dart';
import '../services/cover_cache_service.dart';
import '../services/book_image_fetcher.dart';

/// 多级自愈书籍封面组件
/// 优先级：本地离线持久化文件 > 已下载 EPUB 内部提取 > 网络加载与自动备份缓存 > 占位图
class BookCoverWidget extends StatefulWidget {
  final String bookId;
  final String bookName;
  final String? thumbUrl;
  final String? epubPath;
  final BoxFit fit;
  final double iconSize;

  const BookCoverWidget({
    super.key,
    required this.bookId,
    required this.bookName,
    this.thumbUrl,
    this.epubPath,
    this.fit = BoxFit.cover,
    this.iconSize = 28,
  });

  @override
  State<BookCoverWidget> createState() => _BookCoverWidgetState();
}

class _BookCoverWidgetState extends State<BookCoverWidget> {
  final CoverCacheService _cacheService = CoverCacheService();
  File? _localCoverFile;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _checkCoverSource();
  }

  @override
  void didUpdateWidget(BookCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.thumbUrl != widget.thumbUrl ||
        oldWidget.epubPath != widget.epubPath) {
      _checkCoverSource();
    }
  }

  Future<void> _checkCoverSource() async {
    final generation = ++_generation;
    final bookId = widget.bookId;
    final epubPath = widget.epubPath;
    final url = _cleanUrl(widget.thumbUrl);
    if (mounted) setState(() => _localCoverFile = null);
    try {
      File? file;
      if (await _cacheService.hasLocalCover(bookId)) {
        file = await _cacheService.getCoverFile(bookId);
      }
      if (file == null && epubPath != null && epubPath.isNotEmpty) {
        file = await _cacheService.extractCoverFromEpub(bookId, epubPath);
      }
      if (file == null && url != null) {
        file = await _cacheService.cacheNetworkCover(bookId, url);
      }
      if (mounted && generation == _generation && file != null) {
        await FileImage(file).evict();
        if (mounted && generation == _generation) {
          setState(() => _localCoverFile = file);
        }
      }
    } catch (_) {
      // A removed/unreadable cover must not break the shelf.
    }
  }

  String? _cleanUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    final clean = BookImageFetcher.normalize(url);
    return clean.startsWith('https://') ? clean : null;
  }

  @override
  Widget build(BuildContext context) {
    // 本地持久化文件优先
    if (_localCoverFile != null && _localCoverFile!.existsSync()) {
      return Image.file(
        _localCoverFile!,
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) => _buildPlaceholder(),
      );
    }

    final netUrl = _cleanUrl(widget.thumbUrl);
    if (netUrl != null && netUrl.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: netUrl,
        fit: widget.fit,
        cacheManager: BookCoverCacheManager.instance,
        placeholder: (context, url) => Container(color: AppTheme.primaryLight),
        errorWidget: (context, url, error) => _buildPlaceholder(),
      );
    }

    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      color: AppTheme.primaryLight,
      padding: const EdgeInsets.all(4),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: widget.iconSize,
              color: AppTheme.primaryColor.withValues(alpha: 0.6),
            ),
            if (widget.bookName.isNotEmpty) ...[
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  widget.bookName,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.primaryColor.withValues(alpha: 0.8),
                  ),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

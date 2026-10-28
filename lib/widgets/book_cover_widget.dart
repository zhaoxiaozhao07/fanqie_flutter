import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../app_theme.dart';
import '../main.dart';
import '../services/cover_cache_service.dart';

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
    // 1. 优先检查本地离线持久化封面
    final coverFile = await _cacheService.getCoverFile(widget.bookId);
    if (await coverFile.exists() && (await coverFile.length()) > 100) {
      if (mounted) {
        setState(() {
          _localCoverFile = coverFile;
        });
      }
      return;
    }

    // 2. 检查是否可从已下载的 EPUB 文件中提取封面
    if (widget.epubPath != null && widget.epubPath!.isNotEmpty) {
      final extracted = await _cacheService.extractCoverFromEpub(widget.bookId, widget.epubPath!);
      if (extracted != null && mounted) {
        setState(() {
          _localCoverFile = extracted;
        });
        return;
      }
    }

    // 3. 网络图片自动触发后台本地备份
    final netUrl = _cleanUrl(widget.thumbUrl);
    if (netUrl != null) {
      _cacheService.cacheNetworkCover(widget.bookId, netUrl).then((cached) {
        if (cached != null && mounted && _localCoverFile == null) {
          setState(() {
            _localCoverFile = cached;
          });
        }
      });
    }

    if (mounted) {
      setState(() {
      });
    }
  }

  String? _cleanUrl(String? url) {
    if (url == null || url.isEmpty) return null;
    var clean = url.trim();
    if (clean.startsWith('http://')) {
      clean = clean.replaceFirst('http://', 'https://');
    }
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
              Text(
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
            ],
          ],
        ),
      ),
    );
  }
}

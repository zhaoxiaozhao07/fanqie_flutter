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
  final CoverCacheService? cacheService;

  const BookCoverWidget({
    super.key,
    required this.bookId,
    required this.bookName,
    this.thumbUrl,
    this.epubPath,
    this.fit = BoxFit.cover,
    this.iconSize = 28,
    this.cacheService,
  });

  @override
  State<BookCoverWidget> createState() => _BookCoverWidgetState();
}

class _BookCoverWidgetState extends State<BookCoverWidget> {
  late final CoverCacheService _cacheService =
      widget.cacheService ?? CoverCacheService();
  File? _localCoverFile;
  int _localRevision = 0;
  bool _networkFallback = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _localCoverFile = _cacheService.peekCover(widget.bookId);
    _localRevision = _cacheService.coverRevision(widget.bookId);
    _checkCoverSource();
  }

  @override
  void didUpdateWidget(BookCoverWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bookId != widget.bookId ||
        oldWidget.thumbUrl != widget.thumbUrl ||
        oldWidget.epubPath != widget.epubPath) {
      if (oldWidget.bookId != widget.bookId) {
        _localCoverFile = _cacheService.peekCover(widget.bookId);
        _localRevision = _cacheService.coverRevision(widget.bookId);
        _networkFallback = false;
      }
      _checkCoverSource();
    }
  }

  Future<void> _checkCoverSource() async {
    final generation = ++_generation;
    final bookId = widget.bookId;
    final epubPath = widget.epubPath;
    final url = _cleanUrl(widget.thumbUrl);
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
      if (mounted && generation == _generation) {
        final revision = _cacheService.coverRevision(bookId);
        if (_localCoverFile?.path != file?.path ||
            _localRevision != revision ||
            _networkFallback != (file == null && url != null)) {
          setState(() {
            _localCoverFile = file;
            _localRevision = revision;
            _networkFallback = file == null && url != null;
          });
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
    // No synchronous disk reads or unconditional image-cache eviction in build.
    final file = _localCoverFile;
    if (file != null) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : 128.0;
          final pixels = (width * MediaQuery.devicePixelRatioOf(context))
              .ceil()
              .clamp(64, 512);
          return Image(
            image: ResizeImage.resizeIfNeeded(
              pixels,
              null,
              _VersionedCoverImage(file, _localRevision),
            ),
            fit: widget.fit,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _buildPlaceholder(),
          );
        },
      );
    }
    final netUrl = _cleanUrl(widget.thumbUrl);
    if (_networkFallback && netUrl != null) {
      return CachedNetworkImage(
        imageUrl: netUrl,
        fit: widget.fit,
        cacheManager: BookCoverCacheManager.instance,
        memCacheWidth: 256,
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        placeholder: (_, _) => _buildPlaceholder(),
        errorWidget: (_, _, _) => _buildPlaceholder(),
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

/// A new file revision gets a new codec key without evicting warm images used by
/// other rows/routes. Unchanged covers retain exactly the same decoded image.
class _VersionedCoverImage extends FileImage {
  final int revision;
  const _VersionedCoverImage(super.file, this.revision);
  @override
  bool operator ==(Object other) =>
      other is _VersionedCoverImage &&
      other.file.path == file.path &&
      other.scale == scale &&
      other.revision == revision;
  @override
  int get hashCode => Object.hash(file.path, scale, revision);
}

import 'package:flutter/material.dart';
import '../models/comment.dart';
import '../services/api_service.dart';

/// 段落评论与回复弹窗（BottomSheet 抽屉）
class ParagraphCommentSheet extends StatefulWidget {
  final String bookId;
  final String chapterId;
  final int paraIndex;
  final String paraText;
  final String chapterTitle;
  final bool isBookReview;
  final Color backgroundColor;
  final Color textColor;
  final Color secondaryColor;
  final Color highlightColor;
  final VoidCallback? onLocateParagraph;

  const ParagraphCommentSheet({
    super.key,
    required this.bookId,
    required this.chapterId,
    required this.paraIndex,
    required this.paraText,
    required this.chapterTitle,
    this.isBookReview = false,
    required this.backgroundColor,
    required this.textColor,
    required this.secondaryColor,
    required this.highlightColor,
    this.onLocateParagraph,
  });

  static Future<void> show({
    required BuildContext context,
    required String bookId,
    required String chapterId,
    required int paraIndex,
    required String paraText,
    required String chapterTitle,
    bool isBookReview = false,
    required Color backgroundColor,
    required Color textColor,
    required Color secondaryColor,
    required Color highlightColor,
    VoidCallback? onLocateParagraph,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => ParagraphCommentSheet(
        bookId: bookId,
        chapterId: chapterId,
        paraIndex: paraIndex,
        paraText: paraText,
        chapterTitle: chapterTitle,
        isBookReview: isBookReview,
        backgroundColor: backgroundColor,
        textColor: textColor,
        secondaryColor: secondaryColor,
        highlightColor: highlightColor,
        onLocateParagraph: onLocateParagraph,
      ),
    );
  }

  @override
  State<ParagraphCommentSheet> createState() => _ParagraphCommentSheetState();
}

class _ParagraphCommentSheetState extends State<ParagraphCommentSheet> {
  final ApiService _apiService = ApiService();
  final ScrollController _scrollController = ScrollController();

  int _currentSort = 1; // 1=最热, 3=最新
  bool _isLoading = true;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<CommentItem> _comments = [];
  String _cursor = '';
  bool _hasMore = false;
  int _totalCount = 0;

  // 展开回复的评论 ID 映射表及其回复列表与加载状态
  final Map<String, List<CommentReplyItem>> _repliesMap = {};
  final Map<String, bool> _repliesLoadingMap = {};
  final Map<String, String> _repliesCursorMap = {};
  final Map<String, bool> _repliesHasMoreMap = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadComments();
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
            _scrollController.position.maxScrollExtent - 200 &&
        !_isLoading &&
        !_isLoadingMore &&
        _hasMore) {
      _loadMoreComments();
    }
  }

  Future<void> _loadComments() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final CommentPageData? result;
      if (widget.isBookReview) {
        result = await _apiService.getBookReviews(
          widget.bookId,
          sort: _currentSort,
        );
      } else {
        result = await _apiService.getParagraphComments(
          widget.bookId,
          widget.chapterId,
          widget.paraIndex,
          sort: _currentSort,
        );
      }

      if (mounted) {
        setState(() {
          _isLoading = false;
          if (result != null) {
            _comments = result.comments;
            _cursor = result.cursor;
            _hasMore = result.hasMore;
            _totalCount = result.total;
          } else {
            _errorMessage = '暂无段评内容或网络连接不可用';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = '加载失败: $e';
        });
      }
    }
  }

  Future<void> _loadMoreComments() async {
    if (_isLoadingMore || !_hasMore) return;

    setState(() {
      _isLoadingMore = true;
    });

    try {
      final CommentPageData? result;
      if (widget.isBookReview) {
        result = await _apiService.getBookReviews(
          widget.bookId,
          sort: _currentSort,
          cursor: _cursor,
        );
      } else {
        result = await _apiService.getParagraphComments(
          widget.bookId,
          widget.chapterId,
          widget.paraIndex,
          sort: _currentSort,
          cursor: _cursor,
        );
      }

      final page = result;
      if (mounted && page != null) {
        setState(() {
          _isLoadingMore = false;
          _comments.addAll(page.comments);
          _cursor = page.cursor;
          _hasMore = page.hasMore;
        });
      } else if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoadingMore = false;
        });
      }
    }
  }

  Future<void> _toggleReplies(String commentId) async {
    if (_repliesMap.containsKey(commentId)) {
      // 已展开则收起
      setState(() {
        _repliesMap.remove(commentId);
      });
      return;
    }

    // 开始拉取回复
    setState(() {
      _repliesLoadingMap[commentId] = true;
    });

    try {
      final result = await _apiService.getCommentReplies(commentId);
      if (mounted) {
        setState(() {
          _repliesLoadingMap[commentId] = false;
          if (result != null) {
            _repliesMap[commentId] = result.replies;
            _repliesCursorMap[commentId] = result.cursor;
            _repliesHasMoreMap[commentId] = result.hasMore;
          } else {
            _repliesMap[commentId] = [];
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _repliesLoadingMap[commentId] = false;
          _repliesMap[commentId] = [];
        });
      }
    }
  }

  Future<void> _loadMoreReplies(String commentId) async {
    final cursor = _repliesCursorMap[commentId] ?? '';
    if (cursor.isEmpty) return;

    setState(() {
      _repliesLoadingMap[commentId] = true;
    });

    try {
      final result = await _apiService.getCommentReplies(commentId, cursor: cursor);
      if (mounted && result != null) {
        setState(() {
          _repliesLoadingMap[commentId] = false;
          final currentList = _repliesMap[commentId] ?? [];
          currentList.addAll(result.replies);
          _repliesMap[commentId] = currentList;
          _repliesCursorMap[commentId] = result.cursor;
          _repliesHasMoreMap[commentId] = result.hasMore;
        });
      } else if (mounted) {
        setState(() {
          _repliesLoadingMap[commentId] = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _repliesLoadingMap[commentId] = false;
        });
      }
    }
  }

  void _showImagePreview(BuildContext context, String imageUrl) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              maxScale: 4.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  imageUrl,
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white70),
                    );
                  },
                  errorBuilder: (context, error, stackTrace) => Container(
                    padding: const EdgeInsets.all(24),
                    color: Colors.black87,
                    child: const Text('图片加载失败', style: TextStyle(color: Colors.white)),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int timestamp) {
    if (timestamp <= 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inMinutes < 1) {
      return '刚刚';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}小时前';
    } else if (diff.inDays < 30) {
      return '${diff.inDays}天前';
    } else {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final sheetHeight = mediaQuery.size.height * 0.78;
    final isDark = widget.backgroundColor.computeLuminance() < 0.2;
    final cardColor = isDark
        ? widget.backgroundColor.withValues(alpha: 0.9)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.04), widget.backgroundColor);

    return Container(
      height: sheetHeight,
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 顶部拖拽手柄
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: widget.secondaryColor.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 10),

            // 标题栏与定位原文
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    widget.isBookReview
                        ? '书籍评价'
                        : (widget.paraIndex == 0 ? '本章评论' : '第 ${widget.paraIndex + 1} 段评论'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: widget.textColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_totalCount > 0)
                    Text(
                      '($_totalCount)',
                      style: TextStyle(
                        fontSize: 14,
                        color: widget.secondaryColor,
                      ),
                    ),
                  const Spacer(),
                  if (widget.onLocateParagraph != null)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        widget.onLocateParagraph!();
                      },
                      icon: const Icon(Icons.my_location, size: 16),
                      label: const Text('定位原文', style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).primaryColor,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  IconButton(
                    icon: Icon(Icons.close, size: 20, color: widget.secondaryColor),
                    onPressed: () => Navigator.of(context).pop(),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

            // 原文引用卡片（如果是段评则显示引用的段落原文）
            if (widget.paraText.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: widget.highlightColor.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(
                        color: Theme.of(context).primaryColor.withValues(alpha: 0.8),
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    widget.paraText.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: widget.textColor.withValues(alpha: 0.85),
                      fontStyle: FontStyle.italic,
                      height: 1.4,
                    ),
                  ),
                ),
              ),

            // 排序切换选项卡 (最热 / 最新)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  _buildSortChip(1, '🔥 热门'),
                  const SizedBox(width: 8),
                  _buildSortChip(3, '🕒 最新'),
                  const Spacer(),
                  Text(
                    '数据来自官方社区',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.secondaryColor.withValues(alpha: 0.6),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, thickness: 0.5),

            // 评论列表主体
            Expanded(
              child: _buildListContent(cardColor, isDark),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortChip(int sortValue, String label) {
    final isSelected = _currentSort == sortValue;
    return GestureDetector(
      onTap: () {
        if (_currentSort != sortValue) {
          setState(() {
            _currentSort = sortValue;
          });
          _loadComments();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).primaryColor
              : widget.secondaryColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : widget.textColor.withValues(alpha: 0.8),
          ),
        ),
      ),
    );
  }

  Widget _buildListContent(Color cardColor, bool isDark) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: Theme.of(context).primaryColor,
              strokeWidth: 2.5,
            ),
            const SizedBox(height: 12),
            Text(
              '正在加载段评...',
              style: TextStyle(fontSize: 13, color: widget.secondaryColor),
            ),
          ],
        ),
      );
    }

    if (_errorMessage != null && _comments.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.chat_bubble_outline, size: 48, color: widget.secondaryColor.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: widget.secondaryColor),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadComments,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_comments.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 48, color: widget.secondaryColor.withValues(alpha: 0.4)),
            const SizedBox(height: 10),
            Text(
              '该段落暂无段评',
              style: TextStyle(fontSize: 14, color: widget.secondaryColor),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: _comments.length + (_hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (ctx, index) {
        if (index >= _comments.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context).primaryColor,
                ),
              ),
            ),
          );
        }

        final comment = _comments[index];
        return _buildCommentCard(comment, cardColor, isDark);
      },
    );
  }

  Widget _buildCommentCard(CommentItem comment, Color cardColor, bool isDark) {
    final hasReplies = comment.replyCount > 0;
    final isExpanded = _repliesMap.containsKey(comment.id);
    final isRepliesLoading = _repliesLoadingMap[comment.id] == true;
    final replies = _repliesMap[comment.id] ?? const [];
    final hasMoreReplies = _repliesHasMoreMap[comment.id] == true;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 用户信息行
          Row(
            children: [
              // 用户头像
              CircleAvatar(
                radius: 16,
                backgroundColor: widget.secondaryColor.withValues(alpha: 0.2),
                backgroundImage: comment.avatar.isNotEmpty
                    ? NetworkImage(comment.avatar)
                    : null,
                child: comment.avatar.isEmpty
                    ? Text(
                        comment.userName.isNotEmpty ? comment.userName[0] : '友',
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.textColor,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 10),

              // 用户名与头衔
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.userName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: widget.textColor,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 徽章与标签
                        if (comment.isAuthor)
                          _buildBadge('作者', Colors.redAccent)
                        else if (comment.isVip)
                          _buildBadge('VIP', Colors.amber.shade700),
                        for (final t in comment.titles)
                          if (t != '作者' && t != 'VIP') _buildBadge(t, widget.secondaryColor),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatTime(comment.createTime),
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.secondaryColor.withValues(alpha: 0.8),
                      ),
                    ),
                  ],
                ),
              ),

              // 点赞计数
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.thumb_up_alt_outlined,
                    size: 14,
                    color: widget.secondaryColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    comment.diggCount > 0 ? '${comment.diggCount}' : '赞',
                    style: TextStyle(fontSize: 12, color: widget.secondaryColor),
                  ),
                ],
              ),
            ],
          ),

          // 评论正文
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text(
              comment.text,
              style: TextStyle(
                fontSize: 14,
                color: widget.textColor,
                height: 1.45,
              ),
            ),
          ),

          // 评论配图
          if (comment.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: comment.images.map((imgUrl) {
                  return GestureDetector(
                    onTap: () => _showImagePreview(context, imgUrl),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        imgUrl,
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          width: 90,
                          height: 90,
                          color: widget.secondaryColor.withValues(alpha: 0.1),
                          child: const Icon(Icons.broken_image, size: 24),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

          // 楼中楼回复入口
          if (hasReplies)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: InkWell(
                onTap: () => _toggleReplies(comment.id),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        isExpanded
                            ? '收起回复'
                            : '查看 ${comment.replyCount} 条回复',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).primaryColor,
                        ),
                      ),
                      Icon(
                        isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        size: 16,
                        color: Theme.of(context).primaryColor,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 楼中楼回复列表（内联展开）
          if (isExpanded)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: widget.backgroundColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isRepliesLoading && replies.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                      ),
                    )
                  else ...[
                    for (final reply in replies) ...[
                      _buildReplyRow(reply),
                      const SizedBox(height: 8),
                    ],
                    if (hasMoreReplies)
                      Center(
                        child: TextButton(
                          onPressed: () => _loadMoreReplies(comment.id),
                          child: Text(
                            isRepliesLoading ? '正在加载...' : '加载更多回复',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).primaryColor,
                            ),
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

  Widget _buildReplyRow(CommentReplyItem reply) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 10,
              backgroundColor: widget.secondaryColor.withValues(alpha: 0.2),
              backgroundImage: reply.avatar.isNotEmpty ? NetworkImage(reply.avatar) : null,
              child: reply.avatar.isEmpty
                  ? Text(
                      reply.userName.isNotEmpty ? reply.userName[0] : '友',
                      style: TextStyle(fontSize: 8, color: widget.textColor),
                    )
                  : null,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                reply.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.textColor.withValues(alpha: 0.9),
                ),
              ),
            ),
            if (reply.isAuthor) ...[
              const SizedBox(width: 4),
              _buildBadge('作者', Colors.redAccent, fontSize: 9),
            ],
            const SizedBox(width: 6),
            Text(
              _formatTime(reply.createTime),
              style: TextStyle(fontSize: 10, color: widget.secondaryColor.withValues(alpha: 0.7)),
            ),
            const Spacer(),
            if (reply.diggCount > 0)
              Text(
                '${reply.diggCount}赞',
                style: TextStyle(fontSize: 10, color: widget.secondaryColor.withValues(alpha: 0.8)),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 26, top: 2),
          child: Text(
            reply.text,
            style: TextStyle(
              fontSize: 13,
              color: widget.textColor.withValues(alpha: 0.95),
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBadge(String text, Color color, {double fontSize = 10}) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

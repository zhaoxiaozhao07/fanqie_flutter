import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app_theme.dart';
import '../services/reader_platform.dart';
import '../services/reader_system_service.dart';

/// 金句海报主题配色方案
class _QuoteCardStyle {
  final String id;
  final String label;
  final Color bgTop;
  final Color bgBottom;
  final Color cardBorder;
  final Color textColor;
  final Color secondaryColor;
  final Color accentColor;

  const _QuoteCardStyle({
    required this.id,
    required this.label,
    required this.bgTop,
    required this.bgBottom,
    required this.cardBorder,
    required this.textColor,
    required this.secondaryColor,
    required this.accentColor,
  });
}

const _kQuoteCardStyles = <_QuoteCardStyle>[
  _QuoteCardStyle(
    id: 'parchment',
    label: '宣纸羊皮',
    bgTop: Color(0xFFFBF5E8),
    bgBottom: Color(0xFFF2E6CE),
    cardBorder: Color(0xFFDCC9A3),
    textColor: Color(0xFF2D241B),
    secondaryColor: Color(0xFF7B6955),
    accentColor: Color(0xFFC45B2A),
  ),
  _QuoteCardStyle(
    id: 'minimal',
    label: '素雅纯白',
    bgTop: Color(0xFFFFFFFF),
    bgBottom: Color(0xFFF7F8FA),
    cardBorder: Color(0xFFE5E7EB),
    textColor: Color(0xFF1F2329),
    secondaryColor: Color(0xFF6B7280),
    accentColor: Color(0xFFFF5722),
  ),
  _QuoteCardStyle(
    id: 'night',
    label: '墨夜星空',
    bgTop: Color(0xFF1F242D),
    bgBottom: Color(0xFF14181F),
    cardBorder: Color(0xFF323946),
    textColor: Color(0xFFE9EDF5),
    secondaryColor: Color(0xFF9AA4B2),
    accentColor: Color(0xFFE8A45B),
  ),
  _QuoteCardStyle(
    id: 'bamboo',
    label: '竹韵墨绿',
    bgTop: Color(0xFF1A332B),
    bgBottom: Color(0xFF11231E),
    cardBorder: Color(0xFF2B4D42),
    textColor: Color(0xFFE7F0EC),
    secondaryColor: Color(0xFF9EB7AE),
    accentColor: Color(0xFFCFA96B),
  ),
];

/// 划线金句海报卡片预览与原生图片分享抽屉
class QuoteShareCardSheet extends StatefulWidget {
  final String quote;
  final String bookName;
  final String? author;
  final String? chapterTitle;
  final String? noteText;

  const QuoteShareCardSheet({
    super.key,
    required this.quote,
    required this.bookName,
    this.author,
    this.chapterTitle,
    this.noteText,
  });

  static Future<void> show(
    BuildContext context, {
    required String quote,
    required String bookName,
    String? author,
    String? chapterTitle,
    String? noteText,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppTheme.surfaceOf(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => QuoteShareCardSheet(
        quote: quote,
        bookName: bookName,
        author: author,
        chapterTitle: chapterTitle,
        noteText: noteText,
      ),
    );
  }

  @override
  State<QuoteShareCardSheet> createState() => _QuoteShareCardSheetState();
}

class _QuoteShareCardSheetState extends State<QuoteShareCardSheet> {
  final GlobalKey _repaintKey = GlobalKey();
  int _styleIndex = 0;
  bool _showChapter = true;
  bool _showNote = true;
  bool _sharing = false;

  String _formattedText() {
    final buf = StringBuffer('「${widget.quote.trim()}」');
    if (_showNote && (widget.noteText?.trim().isNotEmpty ?? false)) {
      buf.write('\n想法：${widget.noteText!.trim()}');
    }
    buf.write('\n——《${widget.bookName}》');
    if (widget.author != null && widget.author!.trim().isNotEmpty) {
      buf.write(' ${widget.author!.trim()}');
    }
    if (_showChapter && (widget.chapterTitle?.trim().isNotEmpty ?? false)) {
      buf.write(' · ${widget.chapterTitle!.trim()}');
    }
    return buf.toString();
  }

  Future<void> _exportAndShare() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final boundary =
          _repaintKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('卡片尚未渲染完成');
      }
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        throw StateError('生成图片字节失败');
      }
      final bytes = byteData.buffer.asUint8List();
      final cacheDir = await getTemporaryDirectory();
      final outDir = Directory('${cacheDir.path}/quote_cards');
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outFile = File('${outDir.path}/quote_$stamp.png');
      await outFile.writeAsBytes(bytes, flush: true);

      if (ReaderPlatform.isAndroid) {
        final ok = await ReaderSystemService.shareImageFile(
          filePath: outFile.path,
          text: _formattedText(),
          title: '分享《${widget.bookName}》金句卡片',
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(ok ? '已调起系统分享面板' : '图片已生成：${outFile.path}'),
              duration: const Duration(seconds: 2),
            ),
          );
          if (ok) Navigator.pop(context);
        }
      } else {
        await Clipboard.setData(ClipboardData(text: _formattedText()));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('海报已保存到 ${outFile.path}，金句文本已复制'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('生成金句海报失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = _kQuoteCardStyles[_styleIndex];
    final hasNote = widget.noteText?.trim().isNotEmpty == true;
    final hasChapter = widget.chapterTitle?.trim().isNotEmpty == true;
    final cleanQuote = widget.quote.trim();

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.88,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textHintOf(context).withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome_mosaic_outlined,
                    size: 20,
                    color: AppTheme.primaryColor,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '金句书摘分享卡片',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 离屏导出区域
                    Center(
                      child: RepaintBoundary(
                        key: _repaintKey,
                        child: Container(
                          key: const ValueKey('quote-share-card-preview'),
                          width: double.infinity,
                          constraints: const BoxConstraints(maxWidth: 420),
                          padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [style.bgTop, style.bgBottom],
                            ),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: style.cardBorder),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.10),
                                blurRadius: 16,
                                offset: const Offset(0, 6),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.format_quote_rounded,
                                    size: 28,
                                    color: style.accentColor.withValues(
                                      alpha: 0.85,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: style.accentColor.withValues(
                                        alpha: 0.14,
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '书摘',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                        color: style.accentColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Text(
                                cleanQuote,
                                style: TextStyle(
                                  fontSize: cleanQuote.length > 140 ? 15 : 17,
                                  height: 1.75,
                                  letterSpacing: 0.4,
                                  color: style.textColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (hasNote && _showNote) ...[
                                const SizedBox(height: 14),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: style.accentColor.withValues(
                                      alpha: 0.08,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border(
                                      left: BorderSide(
                                        color: style.accentColor,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                  child: Text(
                                    widget.noteText!.trim(),
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.5,
                                      color: style.secondaryColor,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: 20),
                              Divider(
                                height: 1,
                                color: style.cardBorder.withValues(alpha: 0.8),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '《${widget.bookName}》',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: style.textColor,
                                          ),
                                        ),
                                        if ((widget.author?.trim().isNotEmpty ??
                                                false) ||
                                            (hasChapter && _showChapter))
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Text(
                                              [
                                                if (widget.author
                                                        ?.trim()
                                                        .isNotEmpty ??
                                                    false)
                                                  widget.author!.trim(),
                                                if (hasChapter && _showChapter)
                                                  widget.chapterTitle!.trim(),
                                              ].join(' · '),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 11.5,
                                                color: style.secondaryColor,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    '番茄Reader',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: style.accentColor.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '卡片配色风格',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textSecondaryOf(context),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (var i = 0; i < _kQuoteCardStyles.length; i++)
                          ChoiceChip(
                            label: Text(
                              _kQuoteCardStyles[i].label,
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _styleIndex == i,
                            visualDensity: VisualDensity.compact,
                            onSelected: (_) => setState(() => _styleIndex = i),
                          ),
                      ],
                    ),
                    if (hasChapter || hasNote) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        children: [
                          if (hasChapter)
                            FilterChip(
                              label: const Text(
                                '显示章节名',
                                style: TextStyle(fontSize: 12),
                              ),
                              selected: _showChapter,
                              visualDensity: VisualDensity.compact,
                              onSelected: (v) =>
                                  setState(() => _showChapter = v),
                            ),
                          if (hasNote)
                            FilterChip(
                              label: const Text(
                                '显示我的想法',
                                style: TextStyle(fontSize: 12),
                              ),
                              selected: _showNote,
                              visualDensity: VisualDensity.compact,
                              onSelected: (v) => setState(() => _showNote = v),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _formattedText()));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制带出处的书摘文字'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 17),
                    label: const Text('复制文案'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('quote-share-export-btn'),
                      onPressed: _sharing ? null : _exportAndShare,
                      icon: _sharing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.share_rounded, size: 18),
                      label: Text(_sharing ? '正在生成高清海报…' : '分享海报图片'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

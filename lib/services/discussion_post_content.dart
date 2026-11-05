import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

/// Forum posts use a rich document, not the plain text used by chapter comments.
/// Parse its skeleton without executing HTML, and preserve supported materials.
class DiscussionPostContent {
  final String text;
  final List<String> images;
  const DiscussionPostContent(this.text, this.images);

  factory DiscussionPostContent.parse(Map content) {
    final raw = content['text']?.toString() ?? '';
    var plain = content['pure_text']?.toString() ?? '';
    Map? document;
    try {
      final value = jsonDecode(raw);
      if (value is Map) document = value;
    } catch (_) {}
    final materials = document?['materials'] is List
        ? document!['materials'] as List
        : const [];
    final images = <String>{};
    final output = StringBuffer();
    void image(dynamic value) {
      final uri = Uri.tryParse(value?.toString() ?? '');
      if (uri != null &&
          (uri.scheme == 'https' || uri.scheme == 'http') &&
          uri.host.isNotEmpty) {
        images.add(uri.toString());
      }
    }

    String material(int index) {
      if (index < 0 || index >= materials.length || materials[index] is! Map) {
        return '[暂不支持的帖子附件]';
      }
      final item = materials[index] as Map;
      final data = item['data'] is Map ? item['data'] as Map : const {};
      final type = item['type']?.toString() ?? '';
      if (type == 'image') {
        final url = data['web_url']?.toString() ?? '';
        final value = url.isNotEmpty ? url : data['url'];
        final uri = Uri.tryParse(value?.toString() ?? '');
        if (uri == null ||
            !const {'https', 'http'}.contains(uri.scheme) ||
            uri.host.isEmpty) {
          return '[图片暂不可用]';
        }
        image(value);
        return '';
      }
      if (type == 'mention_user') {
        final text = data['text']?.toString() ?? '';
        return text.isNotEmpty ? text : '@${data['user_name'] ?? '书友'}';
      }
      return data['text']?.toString() ?? '[暂不支持的帖子附件]';
    }

    void visit(dom.Node node) {
      if (node is dom.Text) {
        output.write(node.data);
        return;
      }
      if (node is dom.Element) {
        if (const {'script', 'style', 'iframe'}.contains(node.localName)) {
          return;
        }
        final match = RegExp(
          r'^cc_material_(\d+)$',
        ).firstMatch(node.localName ?? '');
        if (match != null) {
          output.write(material(int.parse(match.group(1)!)));
          return;
        }
        if (node.localName == 'br') {
          output.write('\n');
          return;
        }
        for (final child in node.nodes) {
          visit(child);
        }
        if (const {'p', 'div', 'li', 'blockquote'}.contains(node.localName)) {
          output.write('\n');
        }
      }
    }

    final rawSkeleton = document?['skeleton'];
    final skeleton = rawSkeleton is Map
        ? (rawSkeleton['type'] == 'html' ? rawSkeleton['data'] : null)
        : rawSkeleton;
    if (skeleton is String) {
      for (final node in html.parseFragment(skeleton).nodes) {
        visit(node);
      }
      final rendered = output
          .toString()
          .replaceAll(RegExp(r'\n{3,}'), '\n\n')
          .trim();
      if (rendered.isNotEmpty) plain = rendered;
    }
    if (plain.isEmpty) {
      final extensions = content['text_exts'];
      if (extensions is List) {
        plain = extensions
            .whereType<Map>()
            .map((item) => item['text']?.toString() ?? '')
            .join(' ')
            .trim();
      }
      if (plain.isEmpty && images.isEmpty) {
        plain = document == null && raw.isNotEmpty ? raw : '[暂不支持的帖子内容格式]';
      }
    }
    return DiscussionPostContent(plain, List.unmodifiable(images));
  }
}

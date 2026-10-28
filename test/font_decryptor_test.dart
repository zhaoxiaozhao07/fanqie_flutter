import 'package:flutter_test/flutter_test.dart';
import 'package:fanqie_flutter/services/font_decryptor.dart';
import 'package:fanqie_flutter/services/fanqie_mobile_gateway.dart';

void main() {
  test('FontDecryptor decrypts library text accurately', () {
    final dec = FontDecryptor.decryptLibText('');
    expect(dec, equals('神通者'));
  });

  test('FontDecryptor decrypts HTML to paragraphs', () {
    final html = '<p>第一段测试</p><p>第二段测试</p>';
    final text = FontDecryptor.decryptHtmlToText(html);
    expect(text, equals('第一段测试\n\n第二段测试'));
  });

  test('Mobile HTML clean filters duplicate title in first paragraph', () {
    const html = '<h1>第1章 惊变</h1><p>第1章 惊变</p><p>夜色深沉，雷电交加。</p>';
    final cleaned = FanqieMobileGateway.cleanMobileHtml(html);
    expect(cleaned.startsWith('第1章'), isFalse);
    expect(cleaned, equals('夜色深沉，雷电交加。'));
  });
}

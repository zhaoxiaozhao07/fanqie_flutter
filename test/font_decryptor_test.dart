import 'package:flutter_test/flutter_test.dart';
import 'package:fanqie_flutter/services/font_decryptor.dart';

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
}

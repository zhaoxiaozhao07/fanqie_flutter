import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

Uint8List imagePng({int width = 64, int height = 48}) {
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String name, List<int> data) {
    final type = ascii.encode(name);
    final length = ByteData(4)..setUint32(0, data.length);
    final crc = ByteData(4)..setUint32(0, getCrc32([...type, ...data]));
    output.add(length.buffer.asUint8List());
    output.add(type);
    output.add(data);
    output.add(crc.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height);
  header.setUint8(8, 8);
  header.setUint8(9, 6);
  chunk('IHDR', header.buffer.asUint8List());
  final pixels = Uint8List((width * 4 + 1) * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * (width * 4 + 1) + 1 + x * 4;
      pixels[i] = 20;
      pixels[i + 1] = 120;
      pixels[i + 2] = 210;
      pixels[i + 3] = 255;
    }
  }
  chunk('IDAT', ZLibEncoder().encode(pixels));
  chunk('IEND', []);
  return output.takeBytes();
}

Future<File> imageEpub(
  Directory root,
  List<String> bodies, {
  Map<String, List<int>>? resources,
  List<String>? labels,
  String? navigation,
  String? encryption,
  String filename = 'illustrated.epub',
}) async {
  final manifest = [
    for (var i = 0; i < bodies.length; i++)
      '<item id="c$i" href="Text/$i.xhtml" media-type="application/xhtml+xml"/>',
    if (navigation != null)
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
  ].join();
  final files = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(
      '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    ),
    'OPS/book.opf': utf8.encode(
      '''<package xmlns:dc="http://purl.org/dc/elements/1.1/">
<metadata><dc:title>插图测试</dc:title><dc:creator>测试作者</dc:creator></metadata>
<manifest>$manifest</manifest><spine>${List.generate(bodies.length, (i) => '<itemref idref="c$i"/>').join()}</spine></package>''',
    ),
    for (var i = 0; i < bodies.length; i++)
      'OPS/Text/$i.xhtml': utf8.encode(
        '<html xmlns:epub="http://www.idpf.org/2007/ops" xmlns:xlink="http://www.w3.org/1999/xlink"><head><title>${labels?[i] ?? '第${i + 1}章'}</title></head><body>${bodies[i]}</body></html>',
      ),
    'OPS/Images/图 1.png': imagePng(),
    ...?resources,
    if (navigation != null) 'OPS/nav.xhtml': utf8.encode(navigation),
    if (encryption != null) 'META-INF/encryption.xml': utf8.encode(encryption),
  };
  final archive = Archive();
  for (final e in files.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return File(
    '${root.path}/$filename',
  ).writeAsBytes(ZipEncoder().encode(archive));
}

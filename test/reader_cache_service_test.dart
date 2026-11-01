import 'dart:io';

import 'package:fanqie_flutter/services/reader_cache_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ReaderCacheService cache;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('reader_cache_test_');
    cache = ReaderCacheService(documents: () async => root);
    ReaderCacheService.pinnedBooks.clear();
  });
  tearDown(() async {
    await root.delete(recursive: true);
    ReaderCacheService.pinnedBooks.clear();
  });

  test(
    'reads complete short chapters, never partial or failure placeholders',
    () async {
      await cache.write('book', 'short', '终。');
      expect(await cache.read('book', 'short'), '终。');
      final partial = await cache.temporaryFile('book', 'partial');
      await File('${partial.path}.pending').writeAsString('尚未提交');
      expect(await cache.read('book', 'partial'), isNull);
      for (final invalid in ['', '   ', '[本章内容下载失败，请在联网时重新阅读]']) {
        await expectLater(
          cache.write('book', 'bad', invalid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'clear never touches downloaded or imported content and annotations',
    () async {
      for (final id in ['downloaded', 'local_imported']) {
        final permanent = File('${root.path}/offline_books/$id/ch.txt');
        await permanent.parent.create(recursive: true);
        await permanent.writeAsString('永久正文');
        await cache.write(id, 'temp', '临时正文');
        await File('${permanent.parent.path}/notes.json').writeAsString('{}');
      }
      expect(await cache.trim(0, includePinned: true), 0);
      for (final id in ['downloaded', 'local_imported']) {
        expect(await cache.read(id, 'ch'), '永久正文');
        expect(await cache.read(id, 'temp'), isNull);
        expect(
          await File('${root.path}/offline_books/$id/notes.json').exists(),
          isTrue,
        );
      }
    },
  );

  test('quota uses LRU and protects the active reading book', () async {
    await cache.write('old', 'a', 'a' * 100);
    await (await cache.temporaryFile(
      'old',
      'a',
    )).setLastModified(DateTime(2000));
    await cache.write('new', 'b', 'b' * 100);
    await cache.write('active', 'c', 'c' * 100);
    ReaderCacheService.pinnedBooks.add('active');
    expect(await cache.trim(200), 200);
    expect(await cache.read('old', 'a'), isNull);
    expect(await cache.read('new', 'b'), isNotNull);
    expect(await cache.trim(0), 100);
    expect(await cache.read('active', 'c'), isNotNull);
  });

  test('availability stops at first missing or invalid chapter', () async {
    await cache.write('book', '1', '第一章');
    await cache.write('book', '2', '第二章');
    await cache.write('book', '4', '第四章');
    expect(await cache.contiguousEnd('book', ['1', '2', '3', '4'], 0), 1);
    expect(await cache.contiguousEnd('book', ['1', '2', '3', '4'], 2), 1);
  });

  test(
    'identifiers cannot escape cache tree; concurrent writes remain atomic',
    () async {
      final file = await cache.temporaryFile('../outside', '../../secret');
      expect(file.path, startsWith('${root.path}/reader_cache_v2/'));
      expect(file.path, isNot(contains('/../')));
      await Future.wait(
        List.generate(
          20,
          (i) => cache.write('../outside', '../../secret', 'content-$i'),
        ),
      );
      expect(await cache.read('../outside', '../../secret'), 'content-19');
      expect(await File('${file.path}.pending').exists(), isFalse);
    },
  );

  test('network policy is conservative for Wi-Fi-only and persists', () async {
    const policy = ReaderCachePolicy(
      mode: ReaderCacheMode.commute,
      wifiOnly: true,
      maxBytes: 100 * 1024 * 1024,
    );
    expect(policy.allowsPrefetch('mobile'), isFalse);
    expect(policy.allowsPrefetch('unknown'), isFalse);
    expect(policy.allowsPrefetch('offline'), isFalse);
    expect(policy.allowsPrefetch('wifi'), isTrue);
    await policy.save();
    final loaded = await ReaderCachePolicy.load();
    expect(loaded.ahead, 12);
    expect(loaded.wifiOnly, isTrue);
    expect(loaded.maxBytes, 100 * 1024 * 1024);
  });
}

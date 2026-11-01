import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 先完成字体注册，再更新排版参数，避免回退字体与真实字体之间二次重排。
class ReaderFontService {
  static final Map<String, Future<void>> _loads = {};
  static bool _licensesRegistered = false;
  static const _fonts = {
    'kaiti': ('ReaderKaiTi', 'assets/fonts/LXGWWenKaiLite-Regular.ttf'),
    'serif': ('ReaderSongTi', 'assets/fonts/ZCOOLXiaoWei-Regular.ttf'),
  };

  static Future<void> ensureLoaded(String preference) {
    if (!_licensesRegistered) {
      _licensesRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(const [
          'LXGW WenKai Lite',
        ], await rootBundle.loadString('assets/fonts/LXGW-OFL.txt'));
        yield LicenseEntryWithLineBreaks(const [
          'ZCOOL XiaoWei',
        ], await rootBundle.loadString('assets/fonts/ZCOOL-OFL.txt'));
      });
    }
    final font = _fonts[preference];
    if (font == null) return Future.value();
    return _loads.putIfAbsent(preference, () async {
      try {
        final loader = FontLoader(font.$1);
        loader.addFont(rootBundle.load(font.$2));
        await loader.load();
      } catch (_) {
        _loads.remove(preference);
        rethrow;
      }
    });
  }
}

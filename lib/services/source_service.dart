import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/api_source.dart';

/// 源管理服务 - 负责管理 API 后端源列表及其状态
class SourceService {
  static const String _storageKey = 'api_sources_v2';
  static const String _currentSourceKey = 'current_api_source_v2';

  /// 默认 FastAPI 后端地址
  static const String defaultBackendUrl = 'http://192.168.10.158:8000';

  static const List<String> _defaultUrls = [
    defaultBackendUrl,
  ];

  /// 旧版本内置的第三方端点，需要自动剔除
  static const Set<String> _legacyBuiltinUrls = {
    "https://qkfqapi.vv9v.cn",
    "http://49.232.137.12",
    "https://bk.yydjtc.cn",
    "http://103.236.91.147:9999",
    "http://43.248.77.205:22222",
    "http://47.108.80.161:5005",
    "https://fq.shusan.cn",
  };

  static final SourceService _instance = SourceService._internal();
  factory SourceService() => _instance;
  SourceService._internal();

  List<ApiSource> _sources = _defaultUrls
      .map((url) => ApiSource(baseUrl: url))
      .toList();
  SharedPreferences? _prefs;
  bool _initialized = false;

  List<ApiSource> get sources => List.unmodifiable(_sources);

  int _currentUrlIndex = 0;

  int get currentUrlIndex => _currentUrlIndex;

  set currentUrlIndex(int index) {
    if (index >= 0) {
      _currentUrlIndex = index;
      _saveCurrentSource();
    }
  }

  /// 获取当前正在使用的源 URL
  String? get currentActiveUrl {
    final activeUrls = activeSourceUrls;
    if (activeUrls.isEmpty) return defaultBackendUrl;
    if (_currentUrlIndex >= activeUrls.length) {
      _currentUrlIndex = 0;
    }
    return activeUrls[_currentUrlIndex];
  }

  /// 获取当前可用的源URL列表
  List<String> get activeSourceUrls {
    final urls = _sources
        .where((s) => s.isEnabled)
        .map((s) => s.baseUrl.trim().replaceAll(RegExp(r'/+$'), ''))
        .toList();
    if (urls.isEmpty) {
      return [defaultBackendUrl];
    }
    return urls;
  }

  Future<void> initialize() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();

    // 清理旧版本 v1 存储中的第三方默认源
    _cleanupLegacyPreferences();

    final jsonString = _prefs?.getString(_storageKey);

    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final List<dynamic> jsonList = json.decode(jsonString);
        var loaded = jsonList.map((j) => ApiSource.fromJson(j)).toList();

        // 过滤掉所有旧的第三方内置端点
        loaded.removeWhere((s) => _isLegacySource(s.baseUrl));

        _sources = loaded;

        // 确保默认后端源在列表中
        _mergeDefaultSources();
      } catch (e) {
        _resetToDefaults();
      }
    } else {
      _resetToDefaults();
    }

    // 恢复上次使用的源
    final savedUrl = _prefs?.getString(_currentSourceKey);
    if (savedUrl != null &&
        savedUrl.isNotEmpty &&
        !_isLegacySource(savedUrl)) {
      final activeUrls = activeSourceUrls;
      final index = activeUrls.indexOf(savedUrl.trim().replaceAll(RegExp(r'/+$'), ''));
      if (index != -1) {
        _currentUrlIndex = index;
      } else {
        _currentUrlIndex = 0;
      }
    } else {
      _currentUrlIndex = 0;
      _saveCurrentSource();
    }

    _initialized = true;
  }

  void _cleanupLegacyPreferences() {
    try {
      _prefs?.remove('api_sources_v1');
      _prefs?.remove('current_api_source_v1');
    } catch (_) {}
  }

  bool _isLegacySource(String url) {
    final clean = url.trim().replaceAll(RegExp(r'/+$'), '');
    return _legacyBuiltinUrls.contains(clean);
  }

  void _saveCurrentSource() {
    final url = currentActiveUrl;
    if (url != null && _prefs != null) {
      _prefs?.setString(_currentSourceKey, url);
    }
  }

  void _resetToDefaults() {
    _sources = _defaultUrls.map((url) => ApiSource(baseUrl: url)).toList();
    _currentUrlIndex = 0;
    _saveSources();
  }

  void _mergeDefaultSources() {
    final existingUrls = _sources.map((s) => s.baseUrl).toSet();
    bool changed = false;

    for (var url in _defaultUrls) {
      if (!existingUrls.contains(url)) {
        _sources.insert(0, ApiSource(baseUrl: url));
        changed = true;
      }
    }

    if (changed) {
      _saveSources();
    }
  }

  Future<void> _saveSources() async {
    if (_prefs == null) return;
    final jsonList = _sources.map((s) => s.toJson()).toList();
    await _prefs!.setString(_storageKey, json.encode(jsonList));
  }

  Future<void> addSource(String url) async {
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanUrl.isEmpty) return;
    if (_sources.any((s) => s.baseUrl == cleanUrl)) return;
    _sources.add(ApiSource(baseUrl: cleanUrl));
    await _saveSources();
  }

  Future<void> removeSource(String url) async {
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    _sources.removeWhere((s) => s.baseUrl == cleanUrl);
    if (_sources.isEmpty) {
      _sources.add(ApiSource(baseUrl: defaultBackendUrl));
    }
    await _saveSources();
  }

  Future<void> toggleSource(String url, bool isEnabled) async {
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
    final index = _sources.indexWhere((s) => s.baseUrl == cleanUrl);
    if (index != -1) {
      _sources[index] = _sources[index].copyWith(isEnabled: isEnabled);
      await _saveSources();
    }
  }

  /// 检测所有源的连通性
  Future<List<ApiSource>> checkAllConnectivity() async {
    final futures = _sources.map((source) => checkSource(source));
    await Future.wait(futures);
    return _sources;
  }

  /// 检测单个源的连通性（优先通过 /health，回退到 /api/search）
  Future<ApiSource> checkSource(ApiSource source) async {
    final stopwatch = Stopwatch()..start();
    try {
      final cleanUrl = source.baseUrl.replaceAll(RegExp(r'/+$'), '');
      final healthUri = Uri.parse('$cleanUrl/health');

      http.Response response;
      try {
        response = await http.get(healthUri).timeout(const Duration(seconds: 4));
      } catch (_) {
        final searchUri = Uri.parse('$cleanUrl/api/search?key=test_conn&offset=0');
        response = await http.get(searchUri).timeout(const Duration(seconds: 5));
      }

      stopwatch.stop();

      bool isWorking = false;
      String? error;

      if (response.statusCode == 200) {
        isWorking = true;
      } else {
        error = 'HTTP ${response.statusCode}';
      }

      final index = _sources.indexWhere((s) => s.baseUrl == source.baseUrl);
      if (index != -1) {
        _sources[index] = _sources[index].copyWith(
          latency: stopwatch.elapsedMilliseconds,
          isWorking: isWorking,
          error: error,
        );
        return _sources[index];
      }
      return source;
    } catch (e) {
      if (kDebugMode) {
        print('Source check error for ${source.baseUrl}: $e');
      }
      final index = _sources.indexWhere((s) => s.baseUrl == source.baseUrl);
      if (index != -1) {
        _sources[index] = _sources[index].copyWith(
          latency: null,
          isWorking: false,
          error: '连接失败',
        );
        return _sources[index];
      }
      return source;
    }
  }

  /// 手动设置当前使用的源
  bool setCurrentSource(String url) {
    if (url.isEmpty) return false;
    final cleanUrl = url.trim().replaceAll(RegExp(r'/+$'), '');

    final activeUrls = activeSourceUrls;
    final index = activeUrls.indexOf(cleanUrl);

    if (index != -1) {
      _currentUrlIndex = index;
      _saveCurrentSource();
      return true;
    }
    return false;
  }
}

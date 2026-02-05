import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/api_source.dart';

/// 源管理服务 - 负责管理 API 源列表及其状态
class SourceService {
  static const String _storageKey = 'api_sources_v1';
  static const String _currentSourceKey = 'current_api_source_v1';

  // 按照用户要求的顺序配置默认源
  static const List<String> _defaultUrls = [
    "https://qkfqapi.vv9v.cn",
    "http://49.232.137.12",
    "https://bk.yydjtc.cn",
    "http://103.236.91.147:9999",
    "http://43.248.77.205:22222",
    "http://47.108.80.161:5005",
    "https://fq.shusan.cn",
  ];

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
    if (activeUrls.isEmpty) return null;
    if (_currentUrlIndex >= activeUrls.length) {
      _currentUrlIndex = 0;
    }
    return activeUrls[_currentUrlIndex];
  }

  // 获取当前可用的源URL列表（仅包含启用且未被标记为永久失效的）
  List<String> get activeSourceUrls {
    return _sources.where((s) => s.isEnabled).map((s) => s.baseUrl).toList();
  }

  Future<void> initialize() async {
    if (_initialized) return;

    _prefs = await SharedPreferences.getInstance();
    final jsonString = _prefs?.getString(_storageKey);

    if (jsonString != null && jsonString.isNotEmpty) {
      try {
        final List<dynamic> jsonList = json.decode(jsonString);
        _sources = jsonList.map((j) => ApiSource.fromJson(j)).toList();

        // 检查是否有新的默认源还没在列表中，如果有则添加
        _mergeDefaultSources();
      } catch (e) {
        _resetToDefaults();
      }
    } else {
      _resetToDefaults();
    }

    // 恢复上次使用的源
    final savedUrl = _prefs?.getString(_currentSourceKey);
    if (savedUrl != null && savedUrl.isNotEmpty) {
      final activeUrls = activeSourceUrls;
      final index = activeUrls.indexOf(savedUrl);
      if (index != -1) {
        _currentUrlIndex = index;
      }
    }

    _initialized = true;
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
        _sources.add(ApiSource(baseUrl: url));
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
    if (_sources.any((s) => s.baseUrl == url)) return;
    _sources.add(ApiSource(baseUrl: url));
    await _saveSources();
  }

  Future<void> removeSource(String url) async {
    _sources.removeWhere((s) => s.baseUrl == url);
    await _saveSources();
  }

  Future<void> toggleSource(String url, bool isEnabled) async {
    final index = _sources.indexWhere((s) => s.baseUrl == url);
    if (index != -1) {
      _sources[index] = _sources[index].copyWith(isEnabled: isEnabled);
      await _saveSources();
    }
  }

  /// 检测所有源的连通性
  /// 返回更新后的列表
  Future<List<ApiSource>> checkAllConnectivity() async {
    final futures = _sources.map((source) => checkSource(source));
    await Future.wait(futures);
    return _sources;
  }

  Future<ApiSource> checkSource(ApiSource source) async {
    final stopwatch = Stopwatch()..start();
    try {
      final testUrl = '${source.baseUrl}/api/search?key=test_conn&offset=0';
      final response = await http
          .get(Uri.parse(testUrl))
          .timeout(const Duration(seconds: 5));

      stopwatch.stop();

      bool isWorking = false;
      String? error;

      if (response.statusCode == 200) {
        isWorking = true;
      } else {
        error = 'Status: ${response.statusCode}';
      }

      // 更新列表中的状态
      final index = _sources.indexWhere((s) => s.baseUrl == source.baseUrl);
      if (index != -1) {
        _sources[index] = _sources[index].copyWith(
          latency: stopwatch.elapsedMilliseconds,
          isWorking: isWorking,
          error: error,
        );
        return _sources[index]; // Return updated source
      }
      return source;
    } catch (e) {
      final index = _sources.indexWhere((s) => s.baseUrl == source.baseUrl);
      if (index != -1) {
        _sources[index] = _sources[index].copyWith(
          latency: null,
          isWorking: false,
          error: e.toString(),
        );
        return _sources[index];
      }
      return source;
    }
  }

  /// 手动设置当前使用的源
  /// 返回是否设置成功
  bool setCurrentSource(String url) {
    if (url.isEmpty) return false;

    // 找到在 activeSourceUrls 中的索引
    final activeUrls = activeSourceUrls;
    final index = activeUrls.indexOf(url);

    if (index != -1) {
      _currentUrlIndex = index;
      _saveCurrentSource();
      return true;
    }
    return false;
  }
}

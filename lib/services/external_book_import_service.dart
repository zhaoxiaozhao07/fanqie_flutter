import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'reader_platform.dart';
import 'reader_system_service.dart';

typedef ExternalImportBridge =
    Future<Object?> Function(String method, Map<String, Object?>? arguments);

class ExternalBookImportRequest {
  final String id, name;
  final String? filePath, error;
  const ExternalBookImportRequest({
    required this.id,
    required this.name,
    this.filePath,
    this.error,
  });
}

/// The native inbox buffers cold-start events; this queue serializes dialogs
/// even when another settings/import modal or a reader route is open.
class ExternalBookImportService extends ChangeNotifier {
  static final _instance = ExternalBookImportService._();
  factory ExternalBookImportService() => _instance;
  ExternalBookImportService._()
    : _invoke = ((method, arguments) =>
          ReaderPlatform.invoke<Object?>(method, arguments)),
      _testing = false;

  @visibleForTesting
  ExternalBookImportService.forTesting({required ExternalImportBridge invoke})
    : _invoke = invoke,
      _testing = true;

  final ExternalImportBridge _invoke;
  final bool _testing;
  final _pending = <ExternalBookImportRequest>[];
  final _seen = <String>{};
  Future<void>? _draining;
  bool _drainAgain = false, _initialized = false, _closed = false;
  ExternalBookImportRequest? _active;
  String? lastError;

  int get pendingCount => _pending.length;
  bool get hasActiveRequest => _active != null;
  bool get _enabled =>
      _testing ||
      (ReaderPlatform.isMacOS && ReaderPlatform.capabilities.fileImport);

  Future<void> initialize() async {
    if (_initialized || !_enabled) return;
    _initialized = true;
    if (!_testing) {
      ReaderSystemService.registerExternalImportsListener(this, drain);
    }
    await drain();
  }

  Future<void> drain() {
    if (!_enabled || _closed) return Future.value();
    if (_draining != null) {
      _drainAgain = true;
      return _draining!;
    }
    late final Future<void> operation;
    operation = _readInbox().whenComplete(() {
      if (identical(_draining, operation)) _draining = null;
    });
    _draining = operation;
    return operation;
  }

  Future<void> _readInbox() async {
    do {
      _drainAgain = false;
      try {
        final raw = await _invoke('takeExternalImports', null);
        if (_closed) return;
        if (raw is List) {
          for (final item in raw) {
            if (item is! Map || item['id'] is! String) continue;
            final id = item['id'] as String;
            if (id.isEmpty || !_seen.add(id)) continue;
            final name = path.basename(item['name']?.toString() ?? '文件导入');
            final file = item['path'] is String ? item['path'] as String : null;
            final valid =
                file != null &&
                path.isAbsolute(file) &&
                ['.txt', '.epub'].contains(path.extension(file).toLowerCase());
            _pending.add(
              ExternalBookImportRequest(
                id: id,
                name: name,
                filePath: valid ? file : null,
                error:
                    item['error']?.toString() ??
                    (valid ? null : '系统交付的文件路径或格式无效'),
              ),
            );
          }
        }
        lastError = null;
        notifyListeners();
      } catch (_) {
        lastError = 'Finder 导入暂不可用，原文件未改变，请使用“导入本地小说”重试。';
        if (!_closed) notifyListeners();
      }
    } while (_drainAgain && !_closed);
  }

  ExternalBookImportRequest? takeNext() {
    if (_active != null || _pending.isEmpty) return null;
    _active = _pending.removeAt(0);
    return _active;
  }

  Future<void> complete(ExternalBookImportRequest request) async {
    try {
      await _invoke('releaseExternalImport', {'id': request.id});
    } catch (_) {
      lastError = '导入临时文件未能清理，原文件和已导入图书未改变。';
    } finally {
      _seen.remove(request.id);
      if (_active?.id == request.id) _active = null;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> canQuit() async {
    if (!_enabled) return true;
    if (_active != null) return false;
    try {
      return await _invoke('externalImportsBusy', null) != true;
    } catch (_) {
      return false;
    }
  }

  Future<void> releasePending() async {
    final pending = List<ExternalBookImportRequest>.from(_pending);
    _pending.clear();
    for (final request in pending) {
      await complete(request);
    }
  }

  @override
  void dispose() {
    _closed = true;
    if (!_testing) {
      ReaderSystemService.registerExternalImportsListener(this, null);
    }
    super.dispose();
  }
}

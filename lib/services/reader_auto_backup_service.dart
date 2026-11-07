import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_storage.dart';
import 'reader_backup_service.dart';

class ReaderAutoBackupPolicy {
  final bool enabled;
  final int hours, retain;
  final DateTime? lastCreated, lastChecked;
  final String fingerprint;
  const ReaderAutoBackupPolicy({
    this.enabled = false,
    this.hours = 24,
    this.retain = 7,
    this.lastCreated,
    this.lastChecked,
    this.fingerprint = '',
  });
  Map<String, dynamic> toJson() => {
    'version': 1,
    'enabled': enabled,
    'hours': hours,
    'retain': retain,
    'last_created': lastCreated?.toUtc().toIso8601String(),
    'last_checked': lastChecked?.toUtc().toIso8601String(),
    'fingerprint': fingerprint,
  };
  factory ReaderAutoBackupPolicy.fromJson(Map json) {
    if (json['version'] != 1 ||
        json['enabled'] is! bool ||
        ![6, 24, 72, 168].contains(json['hours']) ||
        ![3, 7, 14, 30].contains(json['retain']) ||
        json['fingerprint'] is! String) {
      throw const FormatException('自动备份设置损坏，未覆盖原记录');
    }
    return ReaderAutoBackupPolicy(
      enabled: json['enabled'],
      hours: json['hours'],
      retain: json['retain'],
      lastCreated: json['last_created'] == null
          ? null
          : DateTime.parse(json['last_created']),
      lastChecked: json['last_checked'] == null
          ? null
          : DateTime.parse(json['last_checked']),
      fingerprint: json['fingerprint'],
    );
  }
  ReaderAutoBackupPolicy copyWith({
    bool? enabled,
    int? hours,
    int? retain,
    DateTime? lastCreated,
    DateTime? lastChecked,
    String? fingerprint,
  }) => ReaderAutoBackupPolicy(
    enabled: enabled ?? this.enabled,
    hours: hours ?? this.hours,
    retain: retain ?? this.retain,
    lastCreated: lastCreated ?? this.lastCreated,
    lastChecked: lastChecked ?? this.lastChecked,
    fingerprint: fingerprint ?? this.fingerprint,
  );
}

/// Opt-in application-local metadata snapshots, not cloud/external backups.
/// Keep the last verified archive BEFORE pruning only owned auto snapshots.
class ReaderAutoBackupService extends ChangeNotifier
    with WidgetsBindingObserver {
  static const preferencesKey = 'reader_auto_backups_v1';
  static const maxBytes = 128 * 1024 * 1024;
  static final _name = RegExp(r'^auto-backup-\d+\.zip$');
  static final _instance = ReaderAutoBackupService._(
    AppStorage.documents,
    DateTime.now,
  );
  factory ReaderAutoBackupService() => _instance;
  ReaderAutoBackupService._(this.documents, this.clock);
  @visibleForTesting
  ReaderAutoBackupService.forTesting({
    required this.documents,
    required this.clock,
  });
  final Future<Directory> Function() documents;
  final DateTime Function() clock;
  ReaderAutoBackupPolicy _policy = const ReaderAutoBackupPolicy();
  ReaderAutoBackupPolicy get policy => _policy;
  bool _initialized = false, _readable = true;
  Timer? _timer;
  Future<File?>? _running;
  Future<void>? _writes;
  String? lastError;
  bool get busy => _running != null;

  Future<void> initialize({bool observe = true}) async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    try {
      final raw = prefs.getString(preferencesKey);
      _policy = raw == null
          ? const ReaderAutoBackupPolicy()
          : ReaderAutoBackupPolicy.fromJson(jsonDecode(raw) as Map);
    } catch (_) {
      _readable = false;
      lastError = '自动备份设置不可读，原记录保留；自动备份未启用';
    }
    _initialized = true;
    if (observe) {
      WidgetsBinding.instance.addObserver(this);
      _timer = Timer.periodic(
        const Duration(minutes: 15),
        (_) => _background(),
      );
      _background();
    }
    notifyListeners();
  }

  Future<void> configure({bool? enabled, int? hours, int? retain}) async {
    await initialize();
    if (!_readable) throw StateError('自动备份设置损坏，请先恢复设置');
    await _save(() {
      final next = _policy.copyWith(
        enabled: enabled,
        hours: hours,
        retain: retain,
      );
      return ReaderAutoBackupPolicy.fromJson(next.toJson());
    });
    if (_policy.enabled) _background();
  }

  void _background() {
    unawaited(runDue().catchError((_) => null));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _background();
    }
  }

  Future<File?> runDue({bool force = false}) {
    if (_running != null) return _running!;
    late final Future<File?> operation;
    operation = _run(force).whenComplete(() {
      if (identical(_running, operation)) {
        _running = null;
        notifyListeners();
      }
    });
    _running = operation;
    notifyListeners();
    return operation;
  }

  Future<File?> _run(bool force) async {
    await initialize();
    if (!_readable || (!force && !_policy.enabled)) return null;
    if (ReaderBackupService.hasActiveTransaction) {
      if (force) throw StateError('恢复进行中，请稍后创建快照');
      return null;
    }
    final now = clock();
    if (!force &&
        _policy.lastChecked != null &&
        now.difference(_policy.lastChecked!) < Duration(hours: _policy.hours)) {
      return null;
    }
    final backup = ReaderBackupService(documents: documents);
    try {
      final hash = await backup.fingerprint();
      if (!force && hash == _policy.fingerprint) {
        await _save(() => _policy.copyWith(lastChecked: now));
        return null;
      }
      final file = await backup.create(
        includeBooks: false,
        includeFonts: false,
      );
      await backup.inspect(file);
      final directory = await _root();
      final target = File(
        '${directory.path}/auto-backup-${now.microsecondsSinceEpoch}.zip',
      );
      // Never overwrite a snapshot if a clock is repeated.
      var owned = target;
      var timestamp = now.microsecondsSinceEpoch;
      while (await owned.exists()) {
        owned = File('${directory.path}/auto-backup-${++timestamp}.zip');
      }
      await file.rename(owned.path);
      await _save(
        () => _policy.copyWith(
          lastChecked: now,
          lastCreated: now,
          fingerprint: hash,
        ),
      );
      await _prune();
      lastError = null;
      notifyListeners();
      return owned;
    } catch (_) {
      lastError = '自动备份未完成，请检查空间或阅读数据；已有快照和原数据保留';
      notifyListeners();
      rethrow;
    }
  }

  Future<Directory> _root() async {
    final directory = Directory(
      '${(await documents()).path}/reader_auto_backups',
    );
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('自动备份目录不是普通目录');
    }
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<File>> snapshots() async {
    final directory = await _root();
    final files = await directory
        .list(followLinks: false)
        .where((e) => e is File && _name.hasMatch(e.uri.pathSegments.last))
        .cast<File>()
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  Future<void> _prune() async {
    final files = await snapshots();
    var bytes = 0;
    final sizes = <String, int>{};
    for (final file in files) {
      sizes[file.path] = await file.length();
      bytes += sizes[file.path]!;
    }
    for (var i = files.length - 1; i > 0; i--) {
      if (i < _policy.retain && bytes <= maxBytes) break;
      bytes -= sizes[files[i].path]!;
      await files[i].delete();
    }
  }

  Future<void> _save(ReaderAutoBackupPolicy Function() readNext) {
    late final Future<void> pending;
    pending = (_writes ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          final next = readNext();
          if (!await (await SharedPreferences.getInstance()).setString(
            preferencesKey,
            jsonEncode(next.toJson()),
          )) {
            throw StateError('自动备份设置保存失败');
          }
          _policy = next;
          notifyListeners();
        })
        .whenComplete(() {
          if (identical(_writes, pending)) _writes = null;
        });
    _writes = pending;
    return pending;
  }

  Future<void> flush() async {
    await _running;
    await _writes;
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

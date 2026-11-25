import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/immersive_entities.dart';

/// 音频缓存原子认领发布结果
class AssetPublishResult {
  final bool published;
  final String reason;

  const AssetPublishResult({required this.published, required this.reason});
}

/// 持久化状态存储接口（支持真实 SQLite WAL 事务库与纯 Dart 等价事务内存实现）
abstract class ImmersiveStateStore {
  Future<void> initialize();
  Future<void> close();

  // --- BookRevision / SourceUnit / AnalysisChunk ---
  Future<BookRevision?> getLatestBookRevision(String bookId);
  Future<BookRevision?> getBookRevision(String revisionId);
  Future<void> saveBookRevisionWithUnits({
    required BookRevision revision,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  });
  Future<void> appendChapterUnitsAndChunks({
    required String bookRevisionId,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  });
  Future<List<SourceUnit>> getSourceUnits(String bookRevisionId, {bool activeOnly = true});
  Future<void> replaceUnitWithSubUnits(SourceUnit parent, List<SourceUnit> children);
  Future<List<AnalysisChunk>> getAnalysisChunks(String bookRevisionId);
  Future<void> replaceAnalysisChunks(String bookRevisionId, List<AnalysisChunk> chunks);

  // --- BookAudioConfig ---
  Future<BookAudioConfig?> getBookAudioConfig(String bookId);
  Future<void> saveBookAudioConfig(BookAudioConfig config);

  // --- Character / Alias / VoiceBinding / IdentityChange ---
  Future<List<ImmersiveCharacter>> getCharacters(String bookId);
  Future<List<AliasEvidence>> getAliasEvidences(String bookId);
  Future<List<VoiceBinding>> getVoiceBindings(String bookId);
  Future<VoiceBinding?> getVoiceBinding(String bookId, String characterId);
  Future<List<IdentityChange>> getIdentityChanges(String bookId);
  Future<void> saveCharacter(ImmersiveCharacter character);
  Future<void> saveAliasEvidence(AliasEvidence alias);
  Future<void> upsertVoiceBinding(VoiceBinding binding);
  Future<void> saveIdentityChange(IdentityChange change);

  // --- MemoryCheckpoint / AnalysisDraft / Allocation ---
  Future<MemoryCheckpoint?> getLatestCheckpoint(String bookId, String bookRevisionId);
  Future<List<MemoryCheckpoint>> getCheckpoints(String bookId, String bookRevisionId);
  Future<void> saveCheckpoint(MemoryCheckpoint checkpoint);
  Future<void> deleteCheckpointsAfter(String bookId, String bookRevisionId, int chunkOrder);

  Future<void> saveDraft(AnalysisDraft draft);
  Future<AnalysisDraft?> getDraftForChunk(
    String bookRevisionId,
    String chunkId,
    int analysisRunRevision,
  );
  Future<List<AnalysisDraft>> getValidDrafts(String bookId, String bookRevisionId);
  Future<void> updateDraftStatus(String draftId, String status);

  Future<List<Allocation>> getAllocations(String bookId, String bookRevisionId);
  Future<void> saveAllocations(List<Allocation> allocations);

  /// 原子提交单个分块的确认事务：同时写入角色、别名、绑定、分配决策、检查点，并推进前沿
  Future<bool> commitChunkConfirmationAtomically({
    required String bookId,
    required String bookRevisionId,
    required int expectedConfirmedChunkOrder,
    required int expectedRegistryRevision,
    required String draftId,
    required List<ImmersiveCharacter> newOrUpdatedCharacters,
    required List<AliasEvidence> newAliases,
    required List<VoiceBinding> newBindings,
    required List<Allocation> allocations,
    required MemoryCheckpoint newCheckpoint,
    required int newRegistryRevision,
  });

  // --- PlaybackManifest / AudioSegment ---
  Future<List<AudioSegment>> getAudioSegments(
    String bookId,
    String bookRevisionId, {
    int? manifestRevision,
  });
  Future<void> saveAudioSegments(
    String bookId,
    String bookRevisionId,
    int manifestRevision,
    List<AudioSegment> segments,
  );
  Future<void> updateAudioSegmentStatus({
    required String segmentId,
    required String status,
    String? errorMessage,
  });

  // --- AudioAsset ---
  Future<AudioAsset?> getAudioAsset(String requestKey);
  Future<List<AudioAsset>> listAllAudioAssets();
  Future<void> touchAudioAsset(String requestKey, int nowMs);
  Future<bool> markAssetEvictingIfValid(String requestKey);
  Future<void> deleteAudioAsset(String requestKey);
  Future<void> upsertAudioAsset(AudioAsset asset);

  // --- ImmersiveJob（租约 + 递增 fence + 执行代次）---
  Future<ImmersiveJob?> getJob(String jobKey);
  Future<List<ImmersiveJob>> listJobs({String? bookId, Set<String>? statuses});
  Future<ImmersiveJob> enqueueOrReviveJob(ImmersiveJob job, {bool reviveTerminal = false});
  Future<ImmersiveJob?> claimJob({
    required String jobKey,
    required String workerId,
    required int leaseSeconds,
    required int nowMs,
  });
  Future<bool> heartbeatJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required int leaseSeconds,
    required int nowMs,
  });
  Future<bool> completeJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required String newStatus,
    int? nextNotBeforeMs,
    String? errorMessage,
    required int nowMs,
  });
  Future<void> cancelQueuedJobsForBook(String bookId, {String? jobType, int? nowMs});

  /// 在单个事务内校验任务 owner/fence、写入 AudioAsset、更新任务 succeeded 并更新匹配清单段为 ready
  Future<AssetPublishResult> publishTtsAssetAtomically({
    required String jobKey,
    required String workerId,
    required int fence,
    required AudioAsset asset,
    required int nowMs,
  });

  // --- PlaybackCursor ---
  Future<PlaybackCursor?> getPlaybackCursor(String bookId);
  Future<void> savePlaybackCursor(PlaybackCursor cursor);

  /// 崩溃恢复：回收过期租约任务回 queued/retry_wait，返回受影响任务数
  Future<int> recoverExpiredLeases(int nowMs);

  /// 重建编排：清空指定书籍的角色、分配、检查点、草稿、清单与任务，递增修订版本（保留音色池配置与全局音频缓存）
  Future<void> resetBookArrangement(String bookId, {required int nowMs});

  /// 导出全部书籍的轻量沉浸式档案（每本书的配音覆盖、角色表、别名证据、手动音色锁定与身份合并记录）
  Future<Map<String, Map<String, dynamic>>> exportAllBookImmersiveProfiles();

  /// 双向合并导入来自云端的书籍沉浸式档案（人工锁定音色优先、其余按更新时间取较新）
  Future<bool> mergeAllBookImmersiveProfiles(
    Map<String, Map<String, dynamic>> remoteProfiles,
  );
}

/// 基于 sqflite 的真实 SQLite WAL 持久化实现（全表主键与索引严格大小写敏感 BINARY）
class SqliteImmersiveStateStore implements ImmersiveStateStore {
  final String databasePath;
  Database? _db;

  SqliteImmersiveStateStore(this.databasePath);

  Database get _database {
    final db = _db;
    if (db == null) throw StateError('Immersive SQLite 数据库尚未初始化');
    return db;
  }

  @override
  Future<void> initialize() async {
    if (_db != null) return;
    final dir = Directory(p.dirname(databasePath));
    await dir.create(recursive: true);
    _db = await openDatabase(
      databasePath,
      version: 1,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.rawQuery('PRAGMA synchronous = NORMAL');
      },
      onCreate: (db, version) async {
        await _createSchema(db);
      },
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE book_revisions (
        revision_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        source_file_hash TEXT NOT NULL COLLATE BINARY,
        normalized_text_hash TEXT NOT NULL COLLATE BINARY,
        parser_version TEXT NOT NULL COLLATE BINARY,
        chapter_count INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_book_revisions_book ON book_revisions(book_id, created_at_ms DESC)',
    );

    await db.execute('''
      CREATE TABLE source_units (
        unit_id TEXT PRIMARY KEY COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        chapter_index INTEGER NOT NULL,
        chapter_id TEXT NOT NULL COLLATE BINARY,
        paragraph_index INTEGER NOT NULL,
        global_order INTEGER NOT NULL,
        start_offset INTEGER NOT NULL,
        end_offset INTEGER NOT NULL,
        text TEXT NOT NULL,
        parent_unit_id TEXT COLLATE BINARY,
        active INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_source_units_rev_order ON source_units(book_revision_id, global_order, start_offset)',
    );

    await db.execute('''
      CREATE TABLE analysis_chunks (
        chunk_id TEXT PRIMARY KEY COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        chapter_index INTEGER NOT NULL,
        chapter_id TEXT NOT NULL COLLATE BINARY,
        chunk_order INTEGER NOT NULL,
        target_unit_ids_json TEXT NOT NULL,
        context_before_ids_json TEXT NOT NULL,
        context_after_ids_json TEXT NOT NULL,
        start_global_order INTEGER NOT NULL,
        end_global_order INTEGER NOT NULL,
        planner_version TEXT NOT NULL COLLATE BINARY,
        estimated_tokens INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_analysis_chunks_rev ON analysis_chunks(book_revision_id, chunk_order)',
    );

    await db.execute('''
      CREATE TABLE book_audio_configs (
        book_id TEXT PRIMARY KEY COLLATE BINARY,
        selected_voice_profile_ids_json TEXT NOT NULL,
        narrator_voice_profile_id TEXT NOT NULL COLLATE BINARY,
        allow_voice_reuse INTEGER NOT NULL,
        reserve_narrator_for_non_dialogue INTEGER NOT NULL,
        cast_revision INTEGER NOT NULL,
        registry_revision INTEGER NOT NULL,
        manifest_revision INTEGER NOT NULL,
        analysis_run_revision INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE characters (
        character_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        canonical_name TEXT NOT NULL,
        gender TEXT NOT NULL COLLATE BINARY,
        first_seen_unit_id TEXT NOT NULL COLLATE BINARY,
        status TEXT NOT NULL COLLATE BINARY,
        merged_into_character_id TEXT COLLATE BINARY,
        evidence_unit_ids_json TEXT NOT NULL,
        traits_summary TEXT NOT NULL,
        version INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_characters_book ON characters(book_id)');

    await db.execute('''
      CREATE TABLE alias_evidences (
        alias_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        character_id TEXT NOT NULL COLLATE BINARY,
        alias_text TEXT NOT NULL,
        scope_type TEXT NOT NULL COLLATE BINARY,
        scope_key TEXT NOT NULL COLLATE BINARY,
        evidence_unit_id TEXT NOT NULL COLLATE BINARY,
        status TEXT NOT NULL COLLATE BINARY
      )
    ''');
    await db.execute('CREATE INDEX idx_alias_book ON alias_evidences(book_id)');

    await db.execute('''
      CREATE TABLE voice_bindings (
        book_id TEXT NOT NULL COLLATE BINARY,
        character_id TEXT NOT NULL COLLATE BINARY,
        voice_profile_id TEXT NOT NULL COLLATE BINARY,
        binding_revision INTEGER NOT NULL,
        manual_locked INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY (book_id, character_id)
      )
    ''');

    await db.execute('''
      CREATE TABLE identity_changes (
        change_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        change_type TEXT NOT NULL COLLATE BINARY,
        old_mapping_json TEXT NOT NULL,
        new_mapping_json TEXT NOT NULL,
        affected_scope_json TEXT NOT NULL,
        operator_type TEXT NOT NULL COLLATE BINARY,
        evidence_unit_ids_json TEXT NOT NULL,
        undone INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE memory_checkpoints (
        checkpoint_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        confirmed_chunk_order INTEGER NOT NULL,
        confirmed_through_global_order INTEGER NOT NULL,
        parent_checkpoint_id TEXT COLLATE BINARY,
        context_hash TEXT NOT NULL COLLATE BINARY,
        active_scene_character_ids_json TEXT NOT NULL,
        recent_dialogue_turns_json TEXT NOT NULL,
        registry_revision INTEGER NOT NULL,
        chapter_summary TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_checkpoints_book_rev ON memory_checkpoints(book_id, book_revision_id, confirmed_chunk_order DESC)',
    );

    await db.execute('''
      CREATE TABLE analysis_drafts (
        draft_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        chunk_id TEXT NOT NULL COLLATE BINARY,
        chunk_order INTEGER NOT NULL,
        analysis_run_revision INTEGER NOT NULL,
        snapshot_registry_revision INTEGER NOT NULL,
        cast_revision INTEGER NOT NULL,
        payload_json TEXT NOT NULL,
        validation_status TEXT NOT NULL COLLATE BINARY,
        created_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_drafts_rev_chunk ON analysis_drafts(book_revision_id, chunk_id, analysis_run_revision)',
    );

    await db.execute('''
      CREATE TABLE allocations (
        allocation_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        chunk_id TEXT NOT NULL COLLATE BINARY,
        chapter_index INTEGER NOT NULL,
        order_in_book INTEGER NOT NULL,
        source_unit_ids_json TEXT NOT NULL,
        kind TEXT NOT NULL COLLATE BINARY,
        speaker_ref TEXT COLLATE BINARY,
        original_speaker_ref TEXT COLLATE BINARY,
        allocation_status TEXT NOT NULL COLLATE BINARY,
        speaker_resolution TEXT NOT NULL COLLATE BINARY,
        effective_voice_profile_id TEXT COLLATE BINARY,
        fallback_voice_profile_id TEXT COLLATE BINARY,
        evidence_unit_ids_json TEXT NOT NULL,
        evidence_type TEXT NOT NULL COLLATE BINARY,
        allocation_version INTEGER NOT NULL,
        conflict_note TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_allocations_book_rev ON allocations(book_id, book_revision_id, order_in_book)',
    );

    await db.execute('''
      CREATE TABLE audio_segments (
        segment_id TEXT PRIMARY KEY COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        manifest_revision INTEGER NOT NULL,
        chapter_index INTEGER NOT NULL,
        chapter_id TEXT NOT NULL COLLATE BINARY,
        segment_order INTEGER NOT NULL,
        source_unit_ids_json TEXT NOT NULL,
        start_global_order INTEGER NOT NULL,
        end_global_order INTEGER NOT NULL,
        start_paragraph_index INTEGER NOT NULL,
        start_char_offset INTEGER NOT NULL,
        end_paragraph_index INTEGER NOT NULL,
        end_char_offset INTEGER NOT NULL,
        spoken_text TEXT NOT NULL,
        kind TEXT NOT NULL COLLATE BINARY,
        speaker_ref TEXT COLLATE BINARY,
        speaker_display_name TEXT NOT NULL,
        voice_profile_id TEXT NOT NULL COLLATE BINARY,
        binding_revision INTEGER NOT NULL,
        render_spec_hash TEXT NOT NULL COLLATE BINARY,
        request_key TEXT NOT NULL COLLATE BINARY,
        status TEXT NOT NULL COLLATE BINARY,
        error_message TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_audio_segments_manifest ON audio_segments(book_id, book_revision_id, manifest_revision, segment_order)',
    );
    await db.execute(
      'CREATE INDEX idx_audio_segments_reqkey ON audio_segments(request_key)',
    );

    await db.execute('''
      CREATE TABLE audio_assets (
        request_key TEXT PRIMARY KEY COLLATE BINARY,
        content_sha256 TEXT NOT NULL COLLATE BINARY,
        file_path TEXT NOT NULL,
        format TEXT NOT NULL COLLATE BINARY,
        duration_ms INTEGER NOT NULL,
        byte_size INTEGER NOT NULL,
        verify_status TEXT NOT NULL COLLATE BINARY,
        last_accessed_at_ms INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE jobs (
        job_key TEXT PRIMARY KEY COLLATE BINARY,
        job_type TEXT NOT NULL COLLATE BINARY,
        book_id TEXT NOT NULL COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        status TEXT NOT NULL COLLATE BINARY,
        priority INTEGER NOT NULL,
        attempt INTEGER NOT NULL,
        execution_generation INTEGER NOT NULL,
        fence INTEGER NOT NULL,
        lease_owner TEXT COLLATE BINARY,
        lease_expires_at_ms INTEGER,
        not_before_ms INTEGER,
        dependency_key TEXT COLLATE BINARY,
        input_version TEXT NOT NULL COLLATE BINARY,
        payload_json TEXT NOT NULL,
        error_message TEXT,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_jobs_status_prio ON jobs(status, priority, created_at_ms)',
    );

    await db.execute('''
      CREATE TABLE playback_cursors (
        book_id TEXT PRIMARY KEY COLLATE BINARY,
        book_revision_id TEXT NOT NULL COLLATE BINARY,
        chapter_index INTEGER NOT NULL,
        chapter_id TEXT NOT NULL COLLATE BINARY,
        paragraph_index INTEGER NOT NULL,
        character_offset INTEGER NOT NULL,
        segment_id TEXT COLLATE BINARY,
        audio_request_key TEXT COLLATE BINARY,
        audio_content_sha256 TEXT COLLATE BINARY,
        position_in_segment_ms INTEGER NOT NULL,
        playback_rate REAL NOT NULL,
        user_paused INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
  }

  @override
  Future<BookRevision?> getLatestBookRevision(String bookId) async {
    final rows = await _database.query(
      'book_revisions',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at_ms DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : BookRevision.fromRow(rows.first);
  }

  @override
  Future<BookRevision?> getBookRevision(String revisionId) async {
    final rows = await _database.query(
      'book_revisions',
      where: 'revision_id = ?',
      whereArgs: [revisionId],
      limit: 1,
    );
    return rows.isEmpty ? null : BookRevision.fromRow(rows.first);
  }

  @override
  Future<void> saveBookRevisionWithUnits({
    required BookRevision revision,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  }) async {
    await _database.transaction((txn) async {
      await txn.insert(
        'book_revisions',
        revision.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      for (final u in units) {
        batch.insert(
          'source_units',
          u.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final c in chunks) {
        batch.insert(
          'analysis_chunks',
          c.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> appendChapterUnitsAndChunks({
    required String bookRevisionId,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  }) async {
    await _database.transaction((txn) async {
      final batch = txn.batch();
      for (final u in units) {
        batch.insert(
          'source_units',
          u.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final c in chunks) {
        batch.insert(
          'analysis_chunks',
          c.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<List<SourceUnit>> getSourceUnits(
    String bookRevisionId, {
    bool activeOnly = true,
  }) async {
    final rows = await _database.query(
      'source_units',
      where: activeOnly
          ? 'book_revision_id = ? AND active = 1'
          : 'book_revision_id = ?',
      whereArgs: [bookRevisionId],
      orderBy: 'global_order ASC, start_offset ASC',
    );
    return rows.map(SourceUnit.fromRow).toList();
  }

  @override
  Future<void> replaceUnitWithSubUnits(
    SourceUnit parent,
    List<SourceUnit> children,
  ) async {
    await _database.transaction((txn) async {
      await txn.update(
        'source_units',
        {'active': 0},
        where: 'unit_id = ?',
        whereArgs: [parent.unitId],
      );
      for (final c in children) {
        await txn.insert(
          'source_units',
          c.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<List<AnalysisChunk>> getAnalysisChunks(String bookRevisionId) async {
    final rows = await _database.query(
      'analysis_chunks',
      where: 'book_revision_id = ?',
      whereArgs: [bookRevisionId],
      orderBy: 'chunk_order ASC',
    );
    return rows.map(AnalysisChunk.fromRow).toList();
  }

  @override
  Future<void> replaceAnalysisChunks(
    String bookRevisionId,
    List<AnalysisChunk> chunks,
  ) async {
    await _database.transaction((txn) async {
      await txn.delete(
        'analysis_chunks',
        where: 'book_revision_id = ?',
        whereArgs: [bookRevisionId],
      );
      final batch = txn.batch();
      for (final c in chunks) {
        batch.insert(
          'analysis_chunks',
          c.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<BookAudioConfig?> getBookAudioConfig(String bookId) async {
    final rows = await _database.query(
      'book_audio_configs',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isEmpty ? null : BookAudioConfig.fromRow(rows.first);
  }

  @override
  Future<void> saveBookAudioConfig(BookAudioConfig config) async {
    await _database.insert(
      'book_audio_configs',
      config.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<ImmersiveCharacter>> getCharacters(String bookId) async {
    final rows = await _database.query(
      'characters',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'updated_at_ms ASC',
    );
    return rows.map(ImmersiveCharacter.fromRow).toList();
  }

  @override
  Future<List<AliasEvidence>> getAliasEvidences(String bookId) async {
    final rows = await _database.query(
      'alias_evidences',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    return rows.map(AliasEvidence.fromRow).toList();
  }

  @override
  Future<List<VoiceBinding>> getVoiceBindings(String bookId) async {
    final rows = await _database.query(
      'voice_bindings',
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
    return rows.map(VoiceBinding.fromRow).toList();
  }

  @override
  Future<VoiceBinding?> getVoiceBinding(
    String bookId,
    String characterId,
  ) async {
    final rows = await _database.query(
      'voice_bindings',
      where: 'book_id = ? AND character_id = ?',
      whereArgs: [bookId, characterId],
      limit: 1,
    );
    return rows.isEmpty ? null : VoiceBinding.fromRow(rows.first);
  }

  @override
  Future<List<IdentityChange>> getIdentityChanges(String bookId) async {
    final rows = await _database.query(
      'identity_changes',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(IdentityChange.fromRow).toList();
  }

  @override
  Future<void> saveCharacter(ImmersiveCharacter character) async {
    await _database.insert(
      'characters',
      character.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> saveAliasEvidence(AliasEvidence alias) async {
    await _database.insert(
      'alias_evidences',
      alias.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> upsertVoiceBinding(VoiceBinding binding) async {
    await _database.insert(
      'voice_bindings',
      binding.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> saveIdentityChange(IdentityChange change) async {
    await _database.insert(
      'identity_changes',
      change.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<MemoryCheckpoint?> getLatestCheckpoint(
    String bookId,
    String bookRevisionId,
  ) async {
    final rows = await _database.query(
      'memory_checkpoints',
      where: 'book_id = ? AND book_revision_id = ?',
      whereArgs: [bookId, bookRevisionId],
      orderBy: 'confirmed_chunk_order DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : MemoryCheckpoint.fromRow(rows.first);
  }

  @override
  Future<List<MemoryCheckpoint>> getCheckpoints(
    String bookId,
    String bookRevisionId,
  ) async {
    final rows = await _database.query(
      'memory_checkpoints',
      where: 'book_id = ? AND book_revision_id = ?',
      whereArgs: [bookId, bookRevisionId],
      orderBy: 'confirmed_chunk_order ASC',
    );
    return rows.map(MemoryCheckpoint.fromRow).toList();
  }

  @override
  Future<void> saveCheckpoint(MemoryCheckpoint checkpoint) async {
    await _database.insert(
      'memory_checkpoints',
      checkpoint.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteCheckpointsAfter(
    String bookId,
    String bookRevisionId,
    int chunkOrder,
  ) async {
    await _database.delete(
      'memory_checkpoints',
      where:
          'book_id = ? AND book_revision_id = ? AND confirmed_chunk_order > ?',
      whereArgs: [bookId, bookRevisionId, chunkOrder],
    );
  }

  @override
  Future<void> saveDraft(AnalysisDraft draft) async {
    await _database.insert(
      'analysis_drafts',
      draft.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<AnalysisDraft?> getDraftForChunk(
    String bookRevisionId,
    String chunkId,
    int analysisRunRevision,
  ) async {
    final rows = await _database.query(
      'analysis_drafts',
      where:
          'book_revision_id = ? AND chunk_id = ? AND analysis_run_revision = ?',
      whereArgs: [bookRevisionId, chunkId, analysisRunRevision],
      orderBy: 'created_at_ms DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : AnalysisDraft.fromRow(rows.first);
  }

  @override
  Future<List<AnalysisDraft>> getValidDrafts(
    String bookId,
    String bookRevisionId,
  ) async {
    final rows = await _database.query(
      'analysis_drafts',
      where:
          'book_id = ? AND book_revision_id = ? AND validation_status = ?',
      whereArgs: [bookId, bookRevisionId, 'valid'],
      orderBy: 'chunk_order ASC',
    );
    return rows.map(AnalysisDraft.fromRow).toList();
  }

  @override
  Future<void> updateDraftStatus(String draftId, String status) async {
    await _database.update(
      'analysis_drafts',
      {'validation_status': status},
      where: 'draft_id = ?',
      whereArgs: [draftId],
    );
  }

  @override
  Future<List<Allocation>> getAllocations(
    String bookId,
    String bookRevisionId,
  ) async {
    final rows = await _database.query(
      'allocations',
      where: 'book_id = ? AND book_revision_id = ?',
      whereArgs: [bookId, bookRevisionId],
      orderBy: 'order_in_book ASC',
    );
    return rows.map(Allocation.fromRow).toList();
  }

  @override
  Future<void> saveAllocations(List<Allocation> allocations) async {
    await _database.transaction((txn) async {
      final batch = txn.batch();
      for (final a in allocations) {
        batch.insert(
          'allocations',
          a.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<bool> commitChunkConfirmationAtomically({
    required String bookId,
    required String bookRevisionId,
    required int expectedConfirmedChunkOrder,
    required int expectedRegistryRevision,
    required String draftId,
    required List<ImmersiveCharacter> newOrUpdatedCharacters,
    required List<AliasEvidence> newAliases,
    required List<VoiceBinding> newBindings,
    required List<Allocation> allocations,
    required MemoryCheckpoint newCheckpoint,
    required int newRegistryRevision,
  }) async {
    return _database.transaction((txn) async {
      // 短事务内再次校验连续前沿和角色版本，防止并发盲写
      final cfgRows = await txn.query(
        'book_audio_configs',
        where: 'book_id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (cfgRows.isEmpty) return false;
      final currentRegRev = cfgRows.first['registry_revision'] as int;
      if (currentRegRev != expectedRegistryRevision) return false;

      final cpRows = await txn.query(
        'memory_checkpoints',
        where: 'book_id = ? AND book_revision_id = ?',
        whereArgs: [bookId, bookRevisionId],
        orderBy: 'confirmed_chunk_order DESC',
        limit: 1,
      );
      final currentConfirmedOrder = cpRows.isEmpty
          ? -1
          : (cpRows.first['confirmed_chunk_order'] as int);
      if (currentConfirmedOrder != expectedConfirmedChunkOrder) return false;

      for (final ch in newOrUpdatedCharacters) {
        await txn.insert(
          'characters',
          ch.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final al in newAliases) {
        await txn.insert(
          'alias_evidences',
          al.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final vb in newBindings) {
        await txn.insert(
          'voice_bindings',
          vb.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      for (final a in allocations) {
        await txn.insert(
          'allocations',
          a.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.insert(
        'memory_checkpoints',
        newCheckpoint.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'analysis_drafts',
        {'validation_status': 'committed'},
        where: 'draft_id = ?',
        whereArgs: [draftId],
      );
      if (newRegistryRevision != currentRegRev) {
        await txn.update(
          'book_audio_configs',
          {'registry_revision': newRegistryRevision},
          where: 'book_id = ?',
          whereArgs: [bookId],
        );
      }
      return true;
    });
  }

  @override
  Future<List<AudioSegment>> getAudioSegments(
    String bookId,
    String bookRevisionId, {
    int? manifestRevision,
  }) async {
    int? targetRev = manifestRevision;
    if (targetRev == null) {
      final cfg = await getBookAudioConfig(bookId);
      targetRev = cfg?.manifestRevision ?? 1;
    }
    final rows = await _database.query(
      'audio_segments',
      where:
          'book_id = ? AND book_revision_id = ? AND manifest_revision = ?',
      whereArgs: [bookId, bookRevisionId, targetRev],
      orderBy: 'segment_order ASC',
    );
    return rows.map(AudioSegment.fromRow).toList();
  }

  @override
  Future<void> saveAudioSegments(
    String bookId,
    String bookRevisionId,
    int manifestRevision,
    List<AudioSegment> segments,
  ) async {
    await _database.transaction((txn) async {
      await txn.delete(
        'audio_segments',
        where:
            'book_id = ? AND book_revision_id = ? AND manifest_revision = ?',
        whereArgs: [bookId, bookRevisionId, manifestRevision],
      );
      final batch = txn.batch();
      for (final s in segments) {
        batch.insert(
          'audio_segments',
          s.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  @override
  Future<void> updateAudioSegmentStatus({
    required String segmentId,
    required String status,
    String? errorMessage,
  }) async {
    await _database.update(
      'audio_segments',
      {'status': status, 'error_message': errorMessage},
      where: 'segment_id = ?',
      whereArgs: [segmentId],
    );
  }

  @override
  Future<AudioAsset?> getAudioAsset(String requestKey) async {
    final rows = await _database.query(
      'audio_assets',
      where: 'request_key = ?',
      whereArgs: [requestKey],
      limit: 1,
    );
    return rows.isEmpty ? null : AudioAsset.fromRow(rows.first);
  }

  @override
  Future<List<AudioAsset>> listAllAudioAssets() async {
    final rows = await _database.query(
      'audio_assets',
      orderBy: 'last_accessed_at_ms ASC',
    );
    return rows.map(AudioAsset.fromRow).toList();
  }

  @override
  Future<void> touchAudioAsset(String requestKey, int nowMs) async {
    await _database.update(
      'audio_assets',
      {'last_accessed_at_ms': nowMs},
      where: 'request_key = ? AND verify_status = ?',
      whereArgs: [requestKey, 'valid'],
    );
  }

  @override
  Future<bool> markAssetEvictingIfValid(String requestKey) async {
    final count = await _database.update(
      'audio_assets',
      {'verify_status': 'evicting'},
      where: 'request_key = ? AND verify_status = ?',
      whereArgs: [requestKey, 'valid'],
    );
    return count == 1;
  }

  @override
  Future<void> deleteAudioAsset(String requestKey) async {
    await _database.delete(
      'audio_assets',
      where: 'request_key = ?',
      whereArgs: [requestKey],
    );
  }

  @override
  Future<void> upsertAudioAsset(AudioAsset asset) async {
    await _database.insert(
      'audio_assets',
      asset.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<ImmersiveJob?> getJob(String jobKey) async {
    final rows = await _database.query(
      'jobs',
      where: 'job_key = ?',
      whereArgs: [jobKey],
      limit: 1,
    );
    return rows.isEmpty ? null : ImmersiveJob.fromRow(rows.first);
  }

  @override
  Future<List<ImmersiveJob>> listJobs({
    String? bookId,
    Set<String>? statuses,
  }) async {
    final whereParts = <String>[];
    final args = <Object?>[];
    if (bookId != null) {
      whereParts.add('book_id = ?');
      args.add(bookId);
    }
    if (statuses != null && statuses.isNotEmpty) {
      final placeholders = List.filled(statuses.length, '?').join(',');
      whereParts.add('status IN ($placeholders)');
      args.addAll(statuses);
    }
    final rows = await _database.query(
      'jobs',
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'priority ASC, created_at_ms ASC',
    );
    return rows.map(ImmersiveJob.fromRow).toList();
  }

  @override
  Future<ImmersiveJob> enqueueOrReviveJob(
    ImmersiveJob job, {
    bool reviveTerminal = false,
  }) async {
    return _database.transaction((txn) async {
      final rows = await txn.query(
        'jobs',
        where: 'job_key = ?',
        whereArgs: [job.jobKey],
        limit: 1,
      );
      if (rows.isEmpty) {
        await txn.insert('jobs', job.toRow());
        return job;
      }
      final existing = ImmersiveJob.fromRow(rows.first);
      final isTerminal =
          existing.status == ImmersiveJobStatus.succeeded ||
          existing.status == ImmersiveJobStatus.cancelled ||
          existing.status == ImmersiveJobStatus.failed ||
          existing.status == ImmersiveJobStatus.blocked;
      if (reviveTerminal && isTerminal) {
        // 复用逻辑任务、原子递增执行代次并重置本轮尝试预算（满足 A21）
        final revived = existing.copyWith(
          status: ImmersiveJobStatus.queued,
          priority: job.priority < existing.priority ? job.priority : existing.priority,
          attempt: 0,
          executionGeneration: existing.executionGeneration + 1,
          leaseOwner: null,
          leaseExpiresAtMs: null,
          notBeforeMs: null,
          payloadJson: job.payloadJson,
          errorMessage: null,
          updatedAtMs: job.updatedAtMs,
        );
        await txn.update(
          'jobs',
          revived.toRow(),
          where: 'job_key = ?',
          whereArgs: [job.jobKey],
        );
        return revived;
      }
      if (job.priority < existing.priority &&
          existing.status == ImmersiveJobStatus.queued) {
        final promoted = existing.copyWith(
          priority: job.priority,
          updatedAtMs: job.updatedAtMs,
        );
        await txn.update(
          'jobs',
          promoted.toRow(),
          where: 'job_key = ?',
          whereArgs: [job.jobKey],
        );
        return promoted;
      }
      return existing;
    });
  }

  @override
  Future<ImmersiveJob?> claimJob({
    required String jobKey,
    required String workerId,
    required int leaseSeconds,
    required int nowMs,
  }) async {
    return _database.transaction((txn) async {
      final rows = await txn.query(
        'jobs',
        where: 'job_key = ?',
        whereArgs: [jobKey],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final job = ImmersiveJob.fromRow(rows.first);
      final canClaim =
          job.status == ImmersiveJobStatus.queued ||
          (job.status == ImmersiveJobStatus.retryWait &&
              (job.notBeforeMs ?? 0) <= nowMs) ||
          (job.status == ImmersiveJobStatus.running &&
              (job.leaseExpiresAtMs ?? 0) <= nowMs);
      if (!canClaim) return null;

      final claimed = job.copyWith(
        status: ImmersiveJobStatus.running,
        attempt: job.attempt + 1,
        fence: job.fence + 1,
        leaseOwner: workerId,
        leaseExpiresAtMs: nowMs + leaseSeconds * 1000,
        updatedAtMs: nowMs,
      );
      await txn.update(
        'jobs',
        claimed.toRow(),
        where: 'job_key = ? AND fence = ?',
        whereArgs: [jobKey, job.fence],
      );
      return claimed;
    });
  }

  @override
  Future<bool> heartbeatJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required int leaseSeconds,
    required int nowMs,
  }) async {
    final updated = await _database.update(
      'jobs',
      {
        'lease_expires_at_ms': nowMs + leaseSeconds * 1000,
        'updated_at_ms': nowMs,
      },
      where:
          'job_key = ? AND status = ? AND lease_owner = ? AND fence = ?',
      whereArgs: [jobKey, ImmersiveJobStatus.running, workerId, fence],
    );
    return updated == 1;
  }

  @override
  Future<bool> completeJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required String newStatus,
    int? nextNotBeforeMs,
    String? errorMessage,
    required int nowMs,
  }) async {
    final updated = await _database.update(
      'jobs',
      {
        'status': newStatus,
        'lease_owner': null,
        'lease_expires_at_ms': null,
        'not_before_ms': nextNotBeforeMs,
        'error_message': errorMessage,
        'updated_at_ms': nowMs,
      },
      where: 'job_key = ? AND lease_owner = ? AND fence = ?',
      whereArgs: [jobKey, workerId, fence],
    );
    return updated == 1;
  }

  @override
  Future<void> cancelQueuedJobsForBook(
    String bookId, {
    String? jobType,
    int? nowMs,
  }) async {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final where = jobType == null
        ? 'book_id = ? AND status IN (?, ?)'
        : 'book_id = ? AND job_type = ? AND status IN (?, ?)';
    final args = jobType == null
        ? [bookId, ImmersiveJobStatus.queued, ImmersiveJobStatus.retryWait]
        : [bookId, jobType, ImmersiveJobStatus.queued, ImmersiveJobStatus.retryWait];
    await _database.update(
      'jobs',
      {'status': ImmersiveJobStatus.cancelled, 'updated_at_ms': ts},
      where: where,
      whereArgs: args,
    );
  }

  @override
  Future<AssetPublishResult> publishTtsAssetAtomically({
    required String jobKey,
    required String workerId,
    required int fence,
    required AudioAsset asset,
    required int nowMs,
  }) async {
    return _database.transaction((txn) async {
      final rows = await txn.query(
        'jobs',
        where: 'job_key = ?',
        whereArgs: [jobKey],
        limit: 1,
      );
      if (rows.isEmpty) {
        return const AssetPublishResult(published: false, reason: '任务不存在');
      }
      final job = ImmersiveJob.fromRow(rows.first);
      if (job.status != ImmersiveJobStatus.running ||
          job.leaseOwner != workerId ||
          job.fence != fence ||
          (job.leaseExpiresAtMs ?? 0) < nowMs) {
        return const AssetPublishResult(
          published: false,
          reason: '失去租约或 fence 已过期，禁止旧 worker 回写',
        );
      }

      await txn.insert(
        'audio_assets',
        asset.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.update(
        'jobs',
        {
          'status': ImmersiveJobStatus.succeeded,
          'lease_owner': null,
          'lease_expires_at_ms': null,
          'error_message': null,
          'updated_at_ms': nowMs,
        },
        where: 'job_key = ? AND fence = ?',
        whereArgs: [jobKey, fence],
      );
      // 仅更新 request_key 匹配的清单段为 ready（清单已换版本的不受影响）
      await txn.update(
        'audio_segments',
        {'status': AudioSegmentStatus.ready, 'error_message': null},
        where: 'request_key = ?',
        whereArgs: [asset.requestKey],
      );
      return const AssetPublishResult(published: true, reason: 'ok');
    });
  }

  @override
  Future<PlaybackCursor?> getPlaybackCursor(String bookId) async {
    final rows = await _database.query(
      'playback_cursors',
      where: 'book_id = ?',
      whereArgs: [bookId],
      limit: 1,
    );
    return rows.isEmpty ? null : PlaybackCursor.fromRow(rows.first);
  }

  @override
  Future<void> savePlaybackCursor(PlaybackCursor cursor) async {
    await _database.insert(
      'playback_cursors',
      cursor.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<int> recoverExpiredLeases(int nowMs) async {
    return _database.update(
      'jobs',
      {
        'status': ImmersiveJobStatus.queued,
        'lease_owner': null,
        'lease_expires_at_ms': null,
        'updated_at_ms': nowMs,
      },
      where: 'status = ? AND lease_expires_at_ms <= ?',
      whereArgs: [ImmersiveJobStatus.running, nowMs],
    );
  }

  @override
  Future<void> resetBookArrangement(String bookId, {required int nowMs}) async {
    await _database.transaction((txn) async {
      for (final table in const [
        'characters',
        'alias_evidences',
        'voice_bindings',
        'identity_changes',
        'memory_checkpoints',
        'analysis_drafts',
        'allocations',
        'audio_segments',
        'jobs',
        'source_units',
        'analysis_chunks',
        'book_revisions',
      ]) {
        await txn.delete(table, where: 'book_id = ?', whereArgs: [bookId]);
      }
      final cfgRows = await txn.query(
        'book_audio_configs',
        where: 'book_id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (cfgRows.isNotEmpty) {
        final cfg = BookAudioConfig.fromRow(cfgRows.first);
        final updated = cfg.copyWith(
          analysisRunRevision: cfg.analysisRunRevision + 1,
          manifestRevision: cfg.manifestRevision + 1,
          registryRevision: cfg.registryRevision + 1,
          updatedAtMs: nowMs,
        );
        await txn.insert(
          'book_audio_configs',
          updated.toRow(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  @override
  Future<Map<String, Map<String, dynamic>>>
  exportAllBookImmersiveProfiles() async {
    final db = _database;
    final cfgRows = await db.query('book_audio_configs');
    final charRows = await db.query('characters', orderBy: 'character_id ASC');
    final aliasRows = await db.query('alias_evidences', orderBy: 'alias_id ASC');
    final bindRows = await db.query(
      'voice_bindings',
      orderBy: 'book_id ASC, character_id ASC',
    );
    final changeRows = await db.query('identity_changes', orderBy: 'change_id ASC');

    final bookIds = <String>{};
    for (final r in [...cfgRows, ...charRows, ...bindRows]) {
      final id = r['book_id']?.toString();
      if (id != null && id.isNotEmpty) bookIds.add(id);
    }

    final result = <String, Map<String, dynamic>>{};
    final sortedIds = bookIds.toList()..sort();
    for (final bookId in sortedIds) {
      final cfgs = cfgRows.where((r) => r['book_id'] == bookId).toList();
      final chars = charRows.where((r) => r['book_id'] == bookId).toList();
      final aliases = aliasRows.where((r) => r['book_id'] == bookId).toList();
      final binds = bindRows.where((r) => r['book_id'] == bookId).toList();
      final changes = changeRows.where((r) => r['book_id'] == bookId).toList();
      if (cfgs.isEmpty && chars.isEmpty && binds.isEmpty) continue;
      result[bookId] = {
        'version': 1,
        'book_id': bookId,
        if (cfgs.isNotEmpty)
          'book_audio_config': Map<String, dynamic>.from(cfgs.first),
        'characters': chars.map((r) => Map<String, dynamic>.from(r)).toList(),
        'aliases': aliases.map((r) => Map<String, dynamic>.from(r)).toList(),
        'voice_bindings': binds.map((r) => Map<String, dynamic>.from(r)).toList(),
        'identity_changes':
            changes.map((r) => Map<String, dynamic>.from(r)).toList(),
      };
    }
    return result;
  }

  @override
  Future<bool> mergeAllBookImmersiveProfiles(
    Map<String, Map<String, dynamic>> remoteProfiles,
  ) async {
    var changed = false;
    await _database.transaction((txn) async {
      for (final entry in remoteProfiles.entries) {
        final bookId = entry.key;
        final profile = entry.value;

        // 1. 合并本书配音覆盖（按 updated_at_ms 取较新）
        final rawCfg = profile['book_audio_config'];
        if (rawCfg is Map) {
          final incoming = BookAudioConfig.fromRow(
            Map<String, Object?>.from(rawCfg),
          );
          final existingRows = await txn.query(
            'book_audio_configs',
            where: 'book_id = ?',
            whereArgs: [bookId],
            limit: 1,
          );
          if (existingRows.isEmpty ||
              incoming.updatedAtMs >
                  BookAudioConfig.fromRow(existingRows.first).updatedAtMs) {
            await txn.insert(
              'book_audio_configs',
              incoming.toRow(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
            changed = true;
          }
        }

        // 2. 合并角色列表（同 character_id 按 updated_at_ms 取较新）
        final rawChars = profile['characters'];
        if (rawChars is List) {
          for (final item in rawChars.whereType<Map>()) {
            final incoming = ImmersiveCharacter.fromRow(
              Map<String, Object?>.from(item),
            );
            final existingRows = await txn.query(
              'characters',
              where: 'character_id = ?',
              whereArgs: [incoming.characterId],
              limit: 1,
            );
            if (existingRows.isEmpty ||
                incoming.updatedAtMs >
                    ImmersiveCharacter.fromRow(existingRows.first).updatedAtMs) {
              await txn.insert(
                'characters',
                incoming.toRow(),
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              changed = true;
            }
          }
        }

        // 3. 合并别名证据（按 alias_id 补齐）
        final rawAliases = profile['aliases'];
        if (rawAliases is List) {
          for (final item in rawAliases.whereType<Map>()) {
            final incoming = AliasEvidence.fromRow(
              Map<String, Object?>.from(item),
            );
            final existingRows = await txn.query(
              'alias_evidences',
              where: 'alias_id = ?',
              whereArgs: [incoming.aliasId],
              limit: 1,
            );
            if (existingRows.isEmpty) {
              await txn.insert(
                'alias_evidences',
                incoming.toRow(),
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              changed = true;
            }
          }
        }

        // 4. 合并音色绑定（人工手动锁定 manualLocked=true 优先；同级别按 updated_at_ms 取较新）
        final rawBinds = profile['voice_bindings'];
        if (rawBinds is List) {
          for (final item in rawBinds.whereType<Map>()) {
            final incoming = VoiceBinding.fromRow(
              Map<String, Object?>.from(item),
            );
            final existingRows = await txn.query(
              'voice_bindings',
              where: 'book_id = ? AND character_id = ?',
              whereArgs: [incoming.bookId, incoming.characterId],
              limit: 1,
            );
            var shouldReplace = existingRows.isEmpty;
            if (!shouldReplace) {
              final local = VoiceBinding.fromRow(existingRows.first);
              if (incoming.manualLocked && !local.manualLocked) {
                shouldReplace = true;
              } else if (incoming.manualLocked == local.manualLocked &&
                  incoming.updatedAtMs > local.updatedAtMs) {
                shouldReplace = true;
              }
            }
            if (shouldReplace) {
              await txn.insert(
                'voice_bindings',
                incoming.toRow(),
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              changed = true;
            }
          }
        }

        // 5. 合并身份变更记录（按 change_id 补齐）
        final rawChanges = profile['identity_changes'];
        if (rawChanges is List) {
          for (final item in rawChanges.whereType<Map>()) {
            final incoming = IdentityChange.fromRow(
              Map<String, Object?>.from(item),
            );
            final existingRows = await txn.query(
              'identity_changes',
              where: 'change_id = ?',
              whereArgs: [incoming.changeId],
              limit: 1,
            );
            if (existingRows.isEmpty) {
              await txn.insert(
                'identity_changes',
                incoming.toRow(),
                conflictAlgorithm: ConflictAlgorithm.replace,
              );
              changed = true;
            }
          }
        }
      }
    });
    return changed;
  }
}

/// 等价事务语义的内存状态存储（供单元与并发测试使用，保证大小写敏感、唯一约束、fence/租约原子性）
class InMemoryImmersiveStateStore implements ImmersiveStateStore {
  final Map<String, BookRevision> _revisions = {};
  final Map<String, SourceUnit> _units = {};
  final Map<String, AnalysisChunk> _chunks = {};
  final Map<String, BookAudioConfig> _bookConfigs = {};
  final Map<String, ImmersiveCharacter> _characters = {};
  final Map<String, AliasEvidence> _aliases = {};
  final Map<String, VoiceBinding> _bindings = {}; // '$bookId\u0000$characterId'
  final Map<String, IdentityChange> _changes = {};
  final Map<String, MemoryCheckpoint> _checkpoints = {};
  final Map<String, AnalysisDraft> _drafts = {};
  final Map<String, Allocation> _allocations = {};
  final Map<String, AudioSegment> _segments = {};
  final Map<String, AudioAsset> _assets = {};
  final Map<String, ImmersiveJob> _jobs = {};
  final Map<String, PlaybackCursor> _cursors = {};

  @override
  Future<void> initialize() async {}

  @override
  Future<void> close() async {}

  @override
  Future<BookRevision?> getLatestBookRevision(String bookId) async {
    final matching = _revisions.values.where((r) => r.bookId == bookId).toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return matching.isEmpty ? null : matching.first;
  }

  @override
  Future<BookRevision?> getBookRevision(String revisionId) async =>
      _revisions[revisionId];

  @override
  Future<void> saveBookRevisionWithUnits({
    required BookRevision revision,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  }) async {
    _revisions[revision.revisionId] = revision;
    for (final u in units) {
      _units[u.unitId] = u;
    }
    for (final c in chunks) {
      _chunks[c.chunkId] = c;
    }
  }

  @override
  Future<void> appendChapterUnitsAndChunks({
    required String bookRevisionId,
    required List<SourceUnit> units,
    required List<AnalysisChunk> chunks,
  }) async {
    for (final u in units) {
      _units[u.unitId] = u;
    }
    for (final c in chunks) {
      _chunks[c.chunkId] = c;
    }
  }

  @override
  Future<List<SourceUnit>> getSourceUnits(
    String bookRevisionId, {
    bool activeOnly = true,
  }) async {
    final list = _units.values
        .where((u) => u.bookRevisionId == bookRevisionId && (!activeOnly || u.active))
        .toList()
      ..sort((a, b) {
        final cmp = a.globalOrder.compareTo(b.globalOrder);
        return cmp != 0 ? cmp : a.startOffset.compareTo(b.startOffset);
      });
    return list;
  }

  @override
  Future<void> replaceUnitWithSubUnits(
    SourceUnit parent,
    List<SourceUnit> children,
  ) async {
    _units[parent.unitId] = SourceUnit(
      unitId: parent.unitId,
      bookRevisionId: parent.bookRevisionId,
      bookId: parent.bookId,
      chapterIndex: parent.chapterIndex,
      chapterId: parent.chapterId,
      paragraphIndex: parent.paragraphIndex,
      globalOrder: parent.globalOrder,
      startOffset: parent.startOffset,
      endOffset: parent.endOffset,
      text: parent.text,
      parentUnitId: parent.parentUnitId,
      active: false,
    );
    for (final c in children) {
      _units[c.unitId] = c;
    }
  }

  @override
  Future<List<AnalysisChunk>> getAnalysisChunks(String bookRevisionId) async {
    final list = _chunks.values
        .where((c) => c.bookRevisionId == bookRevisionId)
        .toList()
      ..sort((a, b) => a.chunkOrder.compareTo(b.chunkOrder));
    return list;
  }

  @override
  Future<void> replaceAnalysisChunks(
    String bookRevisionId,
    List<AnalysisChunk> chunks,
  ) async {
    _chunks.removeWhere((_, c) => c.bookRevisionId == bookRevisionId);
    for (final c in chunks) {
      _chunks[c.chunkId] = c;
    }
  }

  @override
  Future<BookAudioConfig?> getBookAudioConfig(String bookId) async =>
      _bookConfigs[bookId];

  @override
  Future<void> saveBookAudioConfig(BookAudioConfig config) async {
    _bookConfigs[config.bookId] = config;
  }

  @override
  Future<List<ImmersiveCharacter>> getCharacters(String bookId) async {
    final list = _characters.values.where((c) => c.bookId == bookId).toList()
      ..sort((a, b) => a.updatedAtMs.compareTo(b.updatedAtMs));
    return list;
  }

  @override
  Future<List<AliasEvidence>> getAliasEvidences(String bookId) async =>
      _aliases.values.where((a) => a.bookId == bookId).toList();

  @override
  Future<List<VoiceBinding>> getVoiceBindings(String bookId) async =>
      _bindings.values.where((b) => b.bookId == bookId).toList();

  @override
  Future<VoiceBinding?> getVoiceBinding(
    String bookId,
    String characterId,
  ) async => _bindings['$bookId\u0000$characterId'];

  @override
  Future<List<IdentityChange>> getIdentityChanges(String bookId) async {
    final list = _changes.values.where((c) => c.bookId == bookId).toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return list;
  }

  @override
  Future<void> saveCharacter(ImmersiveCharacter character) async {
    _characters[character.characterId] = character;
  }

  @override
  Future<void> saveAliasEvidence(AliasEvidence alias) async {
    _aliases[alias.aliasId] = alias;
  }

  @override
  Future<void> upsertVoiceBinding(VoiceBinding binding) async {
    _bindings['${binding.bookId}\u0000${binding.characterId}'] = binding;
  }

  @override
  Future<void> saveIdentityChange(IdentityChange change) async {
    _changes[change.changeId] = change;
  }

  @override
  Future<MemoryCheckpoint?> getLatestCheckpoint(
    String bookId,
    String bookRevisionId,
  ) async {
    final list = await getCheckpoints(bookId, bookRevisionId);
    return list.isEmpty ? null : list.last;
  }

  @override
  Future<List<MemoryCheckpoint>> getCheckpoints(
    String bookId,
    String bookRevisionId,
  ) async {
    final list = _checkpoints.values
        .where(
          (cp) => cp.bookId == bookId && cp.bookRevisionId == bookRevisionId,
        )
        .toList()
      ..sort((a, b) => a.confirmedChunkOrder.compareTo(b.confirmedChunkOrder));
    return list;
  }

  @override
  Future<void> saveCheckpoint(MemoryCheckpoint checkpoint) async {
    _checkpoints[checkpoint.checkpointId] = checkpoint;
  }

  @override
  Future<void> deleteCheckpointsAfter(
    String bookId,
    String bookRevisionId,
    int chunkOrder,
  ) async {
    _checkpoints.removeWhere(
      (_, cp) =>
          cp.bookId == bookId &&
          cp.bookRevisionId == bookRevisionId &&
          cp.confirmedChunkOrder > chunkOrder,
    );
  }

  @override
  Future<void> saveDraft(AnalysisDraft draft) async {
    _drafts[draft.draftId] = draft;
  }

  @override
  Future<AnalysisDraft?> getDraftForChunk(
    String bookRevisionId,
    String chunkId,
    int analysisRunRevision,
  ) async {
    final list = _drafts.values
        .where(
          (d) =>
              d.bookRevisionId == bookRevisionId &&
              d.chunkId == chunkId &&
              d.analysisRunRevision == analysisRunRevision,
        )
        .toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<AnalysisDraft>> getValidDrafts(
    String bookId,
    String bookRevisionId,
  ) async {
    final list = _drafts.values
        .where(
          (d) =>
              d.bookId == bookId &&
              d.bookRevisionId == bookRevisionId &&
              d.validationStatus == 'valid',
        )
        .toList()
      ..sort((a, b) => a.chunkOrder.compareTo(b.chunkOrder));
    return list;
  }

  @override
  Future<void> updateDraftStatus(String draftId, String status) async {
    final d = _drafts[draftId];
    if (d == null) return;
    _drafts[draftId] = AnalysisDraft(
      draftId: d.draftId,
      bookId: d.bookId,
      bookRevisionId: d.bookRevisionId,
      chunkId: d.chunkId,
      chunkOrder: d.chunkOrder,
      analysisRunRevision: d.analysisRunRevision,
      snapshotRegistryRevision: d.snapshotRegistryRevision,
      castRevision: d.castRevision,
      payloadJson: d.payloadJson,
      validationStatus: status,
      createdAtMs: d.createdAtMs,
    );
  }

  @override
  Future<List<Allocation>> getAllocations(
    String bookId,
    String bookRevisionId,
  ) async {
    final list = _allocations.values
        .where((a) => a.bookId == bookId && a.bookRevisionId == bookRevisionId)
        .toList()
      ..sort((a, b) => a.orderInBook.compareTo(b.orderInBook));
    return list;
  }

  @override
  Future<void> saveAllocations(List<Allocation> allocations) async {
    for (final a in allocations) {
      _allocations[a.allocationId] = a;
    }
  }

  @override
  Future<bool> commitChunkConfirmationAtomically({
    required String bookId,
    required String bookRevisionId,
    required int expectedConfirmedChunkOrder,
    required int expectedRegistryRevision,
    required String draftId,
    required List<ImmersiveCharacter> newOrUpdatedCharacters,
    required List<AliasEvidence> newAliases,
    required List<VoiceBinding> newBindings,
    required List<Allocation> allocations,
    required MemoryCheckpoint newCheckpoint,
    required int newRegistryRevision,
  }) async {
    final cfg = _bookConfigs[bookId];
    if (cfg == null || cfg.registryRevision != expectedRegistryRevision) {
      return false;
    }
    final latest = await getLatestCheckpoint(bookId, bookRevisionId);
    final currentOrder = latest?.confirmedChunkOrder ?? -1;
    if (currentOrder != expectedConfirmedChunkOrder) return false;

    for (final c in newOrUpdatedCharacters) {
      _characters[c.characterId] = c;
    }
    for (final a in newAliases) {
      _aliases[a.aliasId] = a;
    }
    for (final b in newBindings) {
      _bindings['${b.bookId}\u0000${b.characterId}'] = b;
    }
    for (final a in allocations) {
      _allocations[a.allocationId] = a;
    }
    _checkpoints[newCheckpoint.checkpointId] = newCheckpoint;
    await updateDraftStatus(draftId, 'committed');
    if (newRegistryRevision != cfg.registryRevision) {
      _bookConfigs[bookId] = cfg.copyWith(
        registryRevision: newRegistryRevision,
      );
    }
    return true;
  }

  @override
  Future<List<AudioSegment>> getAudioSegments(
    String bookId,
    String bookRevisionId, {
    int? manifestRevision,
  }) async {
    final rev = manifestRevision ?? _bookConfigs[bookId]?.manifestRevision ?? 1;
    final list = _segments.values
        .where(
          (s) =>
              s.bookId == bookId &&
              s.bookRevisionId == bookRevisionId &&
              s.manifestRevision == rev,
        )
        .toList()
      ..sort((a, b) => a.segmentOrder.compareTo(b.segmentOrder));
    return list;
  }

  @override
  Future<void> saveAudioSegments(
    String bookId,
    String bookRevisionId,
    int manifestRevision,
    List<AudioSegment> segments,
  ) async {
    _segments.removeWhere(
      (_, s) =>
          s.bookId == bookId &&
          s.bookRevisionId == bookRevisionId &&
          s.manifestRevision == manifestRevision,
    );
    for (final s in segments) {
      _segments[s.segmentId] = s;
    }
  }

  @override
  Future<void> updateAudioSegmentStatus({
    required String segmentId,
    required String status,
    String? errorMessage,
  }) async {
    final s = _segments[segmentId];
    if (s == null) return;
    _segments[segmentId] = s.copyWith(
      status: status,
      errorMessage: errorMessage,
    );
  }

  @override
  Future<AudioAsset?> getAudioAsset(String requestKey) async =>
      _assets[requestKey];

  @override
  Future<List<AudioAsset>> listAllAudioAssets() async {
    final list = _assets.values.toList()
      ..sort((a, b) => a.lastAccessedAtMs.compareTo(b.lastAccessedAtMs));
    return list;
  }

  @override
  Future<void> touchAudioAsset(String requestKey, int nowMs) async {
    final a = _assets[requestKey];
    if (a == null || a.verifyStatus != 'valid') return;
    _assets[requestKey] = a.copyWith(lastAccessedAtMs: nowMs);
  }

  @override
  Future<bool> markAssetEvictingIfValid(String requestKey) async {
    final a = _assets[requestKey];
    if (a == null || a.verifyStatus != 'valid') return false;
    _assets[requestKey] = a.copyWith(verifyStatus: 'evicting');
    return true;
  }

  @override
  Future<void> deleteAudioAsset(String requestKey) async {
    _assets.remove(requestKey);
  }

  @override
  Future<void> upsertAudioAsset(AudioAsset asset) async {
    _assets[asset.requestKey] = asset;
  }

  @override
  Future<ImmersiveJob?> getJob(String jobKey) async => _jobs[jobKey];

  @override
  Future<List<ImmersiveJob>> listJobs({
    String? bookId,
    Set<String>? statuses,
  }) async {
    final list = _jobs.values
        .where(
          (j) =>
              (bookId == null || j.bookId == bookId) &&
              (statuses == null || statuses.contains(j.status)),
        )
        .toList()
      ..sort((a, b) {
        final cmp = a.priority.compareTo(b.priority);
        return cmp != 0 ? cmp : a.createdAtMs.compareTo(b.createdAtMs);
      });
    return list;
  }

  @override
  Future<ImmersiveJob> enqueueOrReviveJob(
    ImmersiveJob job, {
    bool reviveTerminal = false,
  }) async {
    final existing = _jobs[job.jobKey];
    if (existing == null) {
      _jobs[job.jobKey] = job;
      return job;
    }
    final isTerminal =
        existing.status == ImmersiveJobStatus.succeeded ||
        existing.status == ImmersiveJobStatus.cancelled ||
        existing.status == ImmersiveJobStatus.failed ||
        existing.status == ImmersiveJobStatus.blocked;
    if (reviveTerminal && isTerminal) {
      final revived = existing.copyWith(
        status: ImmersiveJobStatus.queued,
        priority: job.priority < existing.priority ? job.priority : existing.priority,
        attempt: 0,
        executionGeneration: existing.executionGeneration + 1,
        leaseOwner: null,
        leaseExpiresAtMs: null,
        notBeforeMs: null,
        payloadJson: job.payloadJson,
        errorMessage: null,
        updatedAtMs: job.updatedAtMs,
      );
      _jobs[job.jobKey] = revived;
      return revived;
    }
    if (job.priority < existing.priority &&
        existing.status == ImmersiveJobStatus.queued) {
      final promoted = existing.copyWith(
        priority: job.priority,
        updatedAtMs: job.updatedAtMs,
      );
      _jobs[job.jobKey] = promoted;
      return promoted;
    }
    return existing;
  }

  @override
  Future<ImmersiveJob?> claimJob({
    required String jobKey,
    required String workerId,
    required int leaseSeconds,
    required int nowMs,
  }) async {
    final job = _jobs[jobKey];
    if (job == null) return null;
    final canClaim =
        job.status == ImmersiveJobStatus.queued ||
        (job.status == ImmersiveJobStatus.retryWait &&
            (job.notBeforeMs ?? 0) <= nowMs) ||
        (job.status == ImmersiveJobStatus.running &&
            (job.leaseExpiresAtMs ?? 0) <= nowMs);
    if (!canClaim) return null;
    final claimed = job.copyWith(
      status: ImmersiveJobStatus.running,
      attempt: job.attempt + 1,
      fence: job.fence + 1,
      leaseOwner: workerId,
      leaseExpiresAtMs: nowMs + leaseSeconds * 1000,
      updatedAtMs: nowMs,
    );
    _jobs[jobKey] = claimed;
    return claimed;
  }

  @override
  Future<bool> heartbeatJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required int leaseSeconds,
    required int nowMs,
  }) async {
    final job = _jobs[jobKey];
    if (job == null ||
        job.status != ImmersiveJobStatus.running ||
        job.leaseOwner != workerId ||
        job.fence != fence) {
      return false;
    }
    _jobs[jobKey] = job.copyWith(
      leaseExpiresAtMs: nowMs + leaseSeconds * 1000,
      updatedAtMs: nowMs,
    );
    return true;
  }

  @override
  Future<bool> completeJob({
    required String jobKey,
    required String workerId,
    required int fence,
    required String newStatus,
    int? nextNotBeforeMs,
    String? errorMessage,
    required int nowMs,
  }) async {
    final job = _jobs[jobKey];
    if (job == null || job.leaseOwner != workerId || job.fence != fence) {
      return false;
    }
    _jobs[jobKey] = job.copyWith(
      status: newStatus,
      leaseOwner: null,
      leaseExpiresAtMs: null,
      notBeforeMs: nextNotBeforeMs,
      errorMessage: errorMessage,
      updatedAtMs: nowMs,
    );
    return true;
  }

  @override
  Future<void> cancelQueuedJobsForBook(
    String bookId, {
    String? jobType,
    int? nowMs,
  }) async {
    final ts = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    for (final entry in _jobs.entries.toList()) {
      final j = entry.value;
      if (j.bookId == bookId &&
          (jobType == null || j.jobType == jobType) &&
          (j.status == ImmersiveJobStatus.queued ||
              j.status == ImmersiveJobStatus.retryWait)) {
        _jobs[entry.key] = j.copyWith(
          status: ImmersiveJobStatus.cancelled,
          updatedAtMs: ts,
        );
      }
    }
  }

  @override
  Future<AssetPublishResult> publishTtsAssetAtomically({
    required String jobKey,
    required String workerId,
    required int fence,
    required AudioAsset asset,
    required int nowMs,
  }) async {
    final job = _jobs[jobKey];
    if (job == null) {
      return const AssetPublishResult(published: false, reason: '任务不存在');
    }
    if (job.status != ImmersiveJobStatus.running ||
        job.leaseOwner != workerId ||
        job.fence != fence ||
        (job.leaseExpiresAtMs ?? 0) < nowMs) {
      return const AssetPublishResult(
        published: false,
        reason: '失去租约或 fence 已过期，禁止旧 worker 回写',
      );
    }
    _assets[asset.requestKey] = asset;
    _jobs[jobKey] = job.copyWith(
      status: ImmersiveJobStatus.succeeded,
      leaseOwner: null,
      leaseExpiresAtMs: null,
      errorMessage: null,
      updatedAtMs: nowMs,
    );
    for (final entry in _segments.entries.toList()) {
      if (entry.value.requestKey == asset.requestKey) {
        _segments[entry.key] = entry.value.copyWith(
          status: AudioSegmentStatus.ready,
          errorMessage: null,
        );
      }
    }
    return const AssetPublishResult(published: true, reason: 'ok');
  }

  @override
  Future<PlaybackCursor?> getPlaybackCursor(String bookId) async =>
      _cursors[bookId];

  @override
  Future<void> savePlaybackCursor(PlaybackCursor cursor) async {
    _cursors[cursor.bookId] = cursor;
  }

  @override
  Future<int> recoverExpiredLeases(int nowMs) async {
    var count = 0;
    for (final entry in _jobs.entries.toList()) {
      final j = entry.value;
      if (j.status == ImmersiveJobStatus.running &&
          (j.leaseExpiresAtMs ?? 0) <= nowMs) {
        _jobs[entry.key] = j.copyWith(
          status: ImmersiveJobStatus.queued,
          leaseOwner: null,
          leaseExpiresAtMs: null,
          updatedAtMs: nowMs,
        );
        count++;
      }
    }
    return count;
  }

  @override
  Future<void> resetBookArrangement(String bookId, {required int nowMs}) async {
    _revisions.removeWhere((_, v) => v.bookId == bookId);
    _units.removeWhere((_, v) => v.bookId == bookId);
    _chunks.removeWhere((_, v) => v.bookId == bookId);
    _characters.removeWhere((_, v) => v.bookId == bookId);
    _aliases.removeWhere((_, v) => v.bookId == bookId);
    _bindings.removeWhere((_, v) => v.bookId == bookId);
    _changes.removeWhere((_, v) => v.bookId == bookId);
    _checkpoints.removeWhere((_, v) => v.bookId == bookId);
    _drafts.removeWhere((_, v) => v.bookId == bookId);
    _allocations.removeWhere((_, v) => v.bookId == bookId);
    _segments.removeWhere((_, v) => v.bookId == bookId);
    _jobs.removeWhere((_, v) => v.bookId == bookId);
    final cfg = _bookConfigs[bookId];
    if (cfg != null) {
      _bookConfigs[bookId] = cfg.copyWith(
        analysisRunRevision: cfg.analysisRunRevision + 1,
        manifestRevision: cfg.manifestRevision + 1,
        registryRevision: cfg.registryRevision + 1,
        updatedAtMs: nowMs,
      );
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>>
  exportAllBookImmersiveProfiles() async {
    final bookIds = <String>{
      ..._bookConfigs.keys,
      for (final c in _characters.values) c.bookId,
      for (final b in _bindings.values) b.bookId,
    }.toList()
      ..sort();

    final result = <String, Map<String, dynamic>>{};
    for (final bookId in bookIds) {
      final cfg = _bookConfigs[bookId];
      final chars = _characters.values.where((c) => c.bookId == bookId).toList()
        ..sort((a, b) => a.characterId.compareTo(b.characterId));
      final aliases = _aliases.values.where((a) => a.bookId == bookId).toList()
        ..sort((a, b) => a.aliasId.compareTo(b.aliasId));
      final binds = _bindings.values.where((b) => b.bookId == bookId).toList()
        ..sort((a, b) => a.characterId.compareTo(b.characterId));
      final changes = _changes.values.where((c) => c.bookId == bookId).toList()
        ..sort((a, b) => a.changeId.compareTo(b.changeId));
      if (cfg == null && chars.isEmpty && binds.isEmpty) continue;
      result[bookId] = {
        'version': 1,
        'book_id': bookId,
        if (cfg != null)
          'book_audio_config': Map<String, dynamic>.from(cfg.toRow()),
        'characters':
            chars.map((c) => Map<String, dynamic>.from(c.toRow())).toList(),
        'aliases':
            aliases.map((a) => Map<String, dynamic>.from(a.toRow())).toList(),
        'voice_bindings':
            binds.map((b) => Map<String, dynamic>.from(b.toRow())).toList(),
        'identity_changes':
            changes.map((c) => Map<String, dynamic>.from(c.toRow())).toList(),
      };
    }
    return result;
  }

  @override
  Future<bool> mergeAllBookImmersiveProfiles(
    Map<String, Map<String, dynamic>> remoteProfiles,
  ) async {
    var changed = false;
    for (final entry in remoteProfiles.entries) {
      final bookId = entry.key;
      final profile = entry.value;

      final rawCfg = profile['book_audio_config'];
      if (rawCfg is Map) {
        final incoming = BookAudioConfig.fromRow(
          Map<String, Object?>.from(rawCfg),
        );
        final local = _bookConfigs[bookId];
        if (local == null || incoming.updatedAtMs > local.updatedAtMs) {
          _bookConfigs[bookId] = incoming;
          changed = true;
        }
      }

      final rawChars = profile['characters'];
      if (rawChars is List) {
        for (final item in rawChars.whereType<Map>()) {
          final incoming = ImmersiveCharacter.fromRow(
            Map<String, Object?>.from(item),
          );
          final local = _characters[incoming.characterId];
          if (local == null || incoming.updatedAtMs > local.updatedAtMs) {
            _characters[incoming.characterId] = incoming;
            changed = true;
          }
        }
      }

      final rawAliases = profile['aliases'];
      if (rawAliases is List) {
        for (final item in rawAliases.whereType<Map>()) {
          final incoming = AliasEvidence.fromRow(
            Map<String, Object?>.from(item),
          );
          if (!_aliases.containsKey(incoming.aliasId)) {
            _aliases[incoming.aliasId] = incoming;
            changed = true;
          }
        }
      }

      final rawBinds = profile['voice_bindings'];
      if (rawBinds is List) {
        for (final item in rawBinds.whereType<Map>()) {
          final incoming = VoiceBinding.fromRow(
            Map<String, Object?>.from(item),
          );
          final key = '${incoming.bookId}\u0000${incoming.characterId}';
          final local = _bindings[key];
          var shouldReplace = local == null;
          if (!shouldReplace) {
            if (incoming.manualLocked && !local.manualLocked) {
              shouldReplace = true;
            } else if (incoming.manualLocked == local.manualLocked &&
                incoming.updatedAtMs > local.updatedAtMs) {
              shouldReplace = true;
            }
          }
          if (shouldReplace) {
            _bindings[key] = incoming;
            changed = true;
          }
        }
      }

      final rawChanges = profile['identity_changes'];
      if (rawChanges is List) {
        for (final item in rawChanges.whereType<Map>()) {
          final incoming = IdentityChange.fromRow(
            Map<String, Object?>.from(item),
          );
          if (!_changes.containsKey(incoming.changeId)) {
            _changes[incoming.changeId] = incoming;
            changed = true;
          }
        }
      }
    }
    return changed;
  }
}

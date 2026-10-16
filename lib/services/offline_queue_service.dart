import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../models/recording_models.dart';

/// Persistent local database for recording-session/chunk-upload state.
/// This is deliberately NOT SharedPreferences (never suitable for
/// structured, growing, queryable data, and explicitly the wrong place for
/// anything resembling a video byte per the implementation brief) and does
/// NOT store video bytes itself -- only the local file *path* to each
/// segment, which lives in the app's documents directory (see
/// recording_engine.dart). Surviving app restart, network loss, and
/// backgrounding is the entire reason this exists: RecordingService reads
/// this table on startup to resume anything left in-flight.
class OfflineQueueService {
  static Database? _db;

  /// Overridable by tests so each test file opens its own physical
  /// database file instead of colliding on the shared production name
  /// (flutter test runs test files concurrently, and sqflite_common_ffi
  /// backs each distinct filename with a real file lock).
  static String databaseName = 'bodycam_recording_queue.db';

  /// Closes and forgets the cached database handle so the next call opens
  /// a fresh one. Used only by tests -- production code never calls this;
  /// the singleton is intentional there.
  static Future<void> resetForTesting() async {
    await _db?.close();
    _db = null;
  }

  static Future<Database> _open() async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, databaseName),
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE recording_sessions (
            local_session_id TEXT PRIMARY KEY,
            backend_session_id TEXT,
            device_identifier TEXT NOT NULL,
            trigger_type TEXT NOT NULL,
            lifecycle_state TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            site_id TEXT,
            nh_mode INTEGER NOT NULL DEFAULT 0,
            camera_lens TEXT NOT NULL DEFAULT 'back'
          )
        ''');
        await db.execute('''
          CREATE TABLE chunk_queue (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            local_session_id TEXT NOT NULL,
            backend_session_id TEXT,
            chunk_number INTEGER NOT NULL,
            local_file_path TEXT NOT NULL,
            duration_seconds REAL,
            is_last_chunk INTEGER NOT NULL DEFAULT 0,
            upload_state TEXT NOT NULL DEFAULT 'pending',
            retry_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            latitude REAL,
            longitude REAL,
            recorded_at TEXT,
            chunk_id TEXT,
            sha256 TEXT,
            size_bytes INTEGER,
            target TEXT,
            site_id TEXT,
            next_attempt_at INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            local_ack_at TEXT,
            UNIQUE(local_session_id, chunk_number)
          )
        ''');
      },
      // v1 -> v2: adds the GPS/timestamp-watermark columns (see
      // QueuedChunk's doc comment). A real device upgrading from a v1
      // install keeps its existing queued rows -- ALTER TABLE ADD COLUMN
      // is safe/non-destructive in SQLite, and the new columns are
      // nullable, so any chunk already queued before this upgrade simply
      // has no GPS/timestamp metadata (matching its real capture history --
      // it genuinely predates this feature).
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN latitude REAL');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN longitude REAL');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN recorded_at TEXT');
        }
        // v2 -> v3: Network Hopping. Identity + integrity for every chunk
        // (client chunk id, SHA-256), the target that accepted it, persisted
        // back-off, and per-recording site/mode. Additive and nullable /
        // defaulted, so rows queued by an older install keep working: a chunk
        // without an id/hash gets them computed from its file before its next
        // upload attempt.
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN chunk_id TEXT');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN sha256 TEXT');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN size_bytes INTEGER');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN target TEXT');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN site_id TEXT');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN next_attempt_at INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN last_error TEXT');
          await db.execute('ALTER TABLE chunk_queue ADD COLUMN local_ack_at TEXT');
          await db.execute('ALTER TABLE recording_sessions ADD COLUMN site_id TEXT');
          await db.execute('ALTER TABLE recording_sessions ADD COLUMN nh_mode INTEGER NOT NULL DEFAULT 0');
          await db.execute("ALTER TABLE recording_sessions ADD COLUMN camera_lens TEXT NOT NULL DEFAULT 'back'");
          // Chunks the OLD uploader parked as `failed` purely because it ran out of its 8 retries were never rejected by any
          // server and still have their files. Put them back in the queue with their metadata intact. Rows that failed for a
          // definitive reason were stored with a retry_count below the cap and stay failed (they are not retried blindly;
          // the operator can re-queue them from the Network Hopping screen).
          await db.execute("UPDATE chunk_queue SET upload_state = 'pending', retry_count = 0, next_attempt_at = 0, last_error = 'legacy_retry_exhausted_requeued' WHERE upload_state = 'failed' AND retry_count >= 8");
        }
      },
    );
    return _db!;
  }

  // --- Recording sessions ---------------------------------------------------

  static Future<void> upsertSession(LocalRecordingSession session) async {
    final db = await _open();
    await db.insert('recording_sessions', session.toDb(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<List<LocalRecordingSession>> unfinishedSessions() async {
    final db = await _open();
    final rows = await db.query(
      'recording_sessions',
      where: 'lifecycle_state NOT IN (?, ?, ?)',
      whereArgs: ['completed', 'cancelled', 'idle'],
    );
    return rows.map(LocalRecordingSession.fromDb).toList();
  }

  static Future<LocalRecordingSession?> getSession(String localSessionId) async {
    final db = await _open();
    final rows = await db.query('recording_sessions', where: 'local_session_id = ?', whereArgs: [localSessionId]);
    if (rows.isEmpty) return null;
    return LocalRecordingSession.fromDb(rows.first);
  }

  // --- Chunk queue -----------------------------------------------------------

  static Future<int> enqueueChunk(QueuedChunk chunk) async {
    final db = await _open();
    return db.insert('chunk_queue', chunk.toDb(), conflictAlgorithm: ConflictAlgorithm.abort);
  }

  static Future<void> updateChunkState(
    int id, {
    required String uploadState,
    int? retryCount,
    String? backendSessionId,
    String? target,
    int? nextAttemptAt,
    String? lastError,
    bool clearLastError = false,
    DateTime? localAckAt,
  }) async {
    final db = await _open();
    await db.update(
      'chunk_queue',
      {
        'upload_state': uploadState,
        if (retryCount != null) 'retry_count': retryCount,
        if (backendSessionId != null) 'backend_session_id': backendSessionId,
        if (target != null) 'target': target,
        if (nextAttemptAt != null) 'next_attempt_at': nextAttemptAt,
        if (lastError != null) 'last_error': lastError,
        if (clearLastError) 'last_error': null,
        if (localAckAt != null) 'local_ack_at': localAckAt.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Persists the chunk's identity and integrity data (computed once, before
  /// the first upload attempt; never changed afterwards).
  static Future<void> setChunkIdentity(int id, {required String chunkId, required String sha256, required int sizeBytes}) async {
    final db = await _open();
    await db.update('chunk_queue', {'chunk_id': chunkId, 'sha256': sha256, 'size_bytes': sizeBytes}, where: 'id = ?', whereArgs: [id]);
  }

  /// Chunks that still have to be sent somewhere: pending, mid-upload, or
  /// (legacy) failed-by-retry-cap rows. EXCLUDES chunks already accepted by a
  /// site receiver ([QueuedChunk.stateLocalAcked]) and permanently rejected
  /// ones ([QueuedChunk.stateFailed]).
  static Future<List<QueuedChunk>> unsentChunks({String? localSessionId}) async {
    final db = await _open();
    final states = [QueuedChunk.statePending, QueuedChunk.stateUploading];
    final rows = await db.query(
      'chunk_queue',
      where: 'upload_state IN (?, ?)${localSessionId != null ? ' AND local_session_id = ?' : ''}',
      whereArgs: [...states, if (localSessionId != null) localSessionId],
      orderBy: 'local_session_id ASC, chunk_number ASC',
    );
    return rows.map(QueuedChunk.fromDb).toList();
  }

  /// Chunks stored on a site receiver but not yet confirmed by the control
  /// room. Their local files MUST be kept.
  static Future<List<QueuedChunk>> awaitingCentralChunks({String? localSessionId}) async {
    final db = await _open();
    final rows = await db.query(
      'chunk_queue',
      where: 'upload_state = ?${localSessionId != null ? ' AND local_session_id = ?' : ''}',
      whereArgs: [QueuedChunk.stateLocalAcked, if (localSessionId != null) localSessionId],
      orderBy: 'local_session_id ASC, chunk_number ASC',
    );
    return rows.map(QueuedChunk.fromDb).toList();
  }

  /// Number of chunks per upload_state across the whole queue (operational screen).
  static Future<Map<String, int>> countsByState() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT upload_state AS s, COUNT(*) AS n FROM chunk_queue GROUP BY upload_state');
    return {for (final r in rows) r['s'] as String: r['n'] as int};
  }

  /// Total bytes of segment files whose upload has not been confirmed centrally.
  static Future<int> unconfirmedBytes() async {
    final db = await _open();
    final rows = await db.rawQuery('SELECT COALESCE(SUM(size_bytes), 0) AS b FROM chunk_queue WHERE upload_state != ?', [QueuedChunk.stateUploaded]);
    return (rows.first['b'] as num?)?.toInt() ?? 0;
  }

  /// Operator action: puts permanently rejected chunks back in the queue (e.g.
  /// after the cause of a conflict was resolved). Never deletes anything.
  static Future<int> requeueFailed() async {
    final db = await _open();
    return db.update(
      'chunk_queue',
      {'upload_state': QueuedChunk.statePending, 'next_attempt_at': 0, 'last_error': null},
      // Damaged or missing local files cannot be fixed by sending them again: they stay failed until the file is restored.
      where: "upload_state = ? AND COALESCE(last_error, '') NOT IN ('local_file_corrupt', 'local_file_missing')",
      whereArgs: [QueuedChunk.stateFailed],
    );
  }

  /// Failed chunks (newest first) so the operator can see WHICH evidence needs attention and why.
  static Future<List<QueuedChunk>> failedChunks({int limit = 20}) async {
    final db = await _open();
    final rows = await db.query('chunk_queue', where: 'upload_state = ?', whereArgs: [QueuedChunk.stateFailed], orderBy: 'id DESC', limit: limit);
    return rows.map(QueuedChunk.fromDb).toList();
  }

  /// The receiver reported chunks it does not have: sends this recording's
  /// receiver-acknowledged chunks again (their files are still on the phone).
  static Future<int> requeueReceiverAcked(String localSessionId) async {
    final db = await _open();
    return db.update(
      'chunk_queue',
      {'upload_state': QueuedChunk.statePending, 'next_attempt_at': 0, 'last_error': 'receiver_missing_chunk'},
      where: 'local_session_id = ? AND upload_state = ? AND target = ?',
      whereArgs: [localSessionId, QueuedChunk.stateLocalAcked, 'receiver'],
    );
  }

  /// Makes every waiting chunk eligible for an immediate attempt (used by
  /// "Sync now" and when a better route appears).
  static Future<void> clearBackoff() async {
    final db = await _open();
    await db.update('chunk_queue', {'next_attempt_at': 0}, where: 'upload_state IN (?, ?)', whereArgs: [QueuedChunk.statePending, QueuedChunk.stateLocalAcked]);
  }

  /// All chunks not yet confirmed uploaded, for a specific session or (when
  /// [localSessionId] is null) across every session -- used both by the
  /// live uploader and by startup recovery.
  static Future<List<QueuedChunk>> pendingChunks({String? localSessionId}) async {
    final db = await _open();
    final rows = await db.query(
      'chunk_queue',
      where: localSessionId != null ? 'upload_state != ? AND local_session_id = ?' : 'upload_state != ?',
      whereArgs: localSessionId != null ? [QueuedChunk.stateUploaded, localSessionId] : [QueuedChunk.stateUploaded],
      orderBy: 'chunk_number ASC',
    );
    return rows.map(QueuedChunk.fromDb).toList();
  }

  static Future<List<QueuedChunk>> allChunksForSession(String localSessionId) async {
    final db = await _open();
    final rows = await db.query('chunk_queue', where: 'local_session_id = ?', whereArgs: [localSessionId], orderBy: 'chunk_number ASC');
    return rows.map(QueuedChunk.fromDb).toList();
  }

  static Future<void> setBackendSessionIdForSession(String localSessionId, String backendSessionId) async {
    final db = await _open();
    await db.update('chunk_queue', {'backend_session_id': backendSessionId}, where: 'local_session_id = ?', whereArgs: [localSessionId]);
    await db.update('recording_sessions', {'backend_session_id': backendSessionId}, where: 'local_session_id = ?', whereArgs: [localSessionId]);
  }
}

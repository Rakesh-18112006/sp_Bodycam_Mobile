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
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE recording_sessions (
            local_session_id TEXT PRIMARY KEY,
            backend_session_id TEXT,
            device_identifier TEXT NOT NULL,
            trigger_type TEXT NOT NULL,
            lifecycle_state TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT
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

  static Future<void> updateChunkState(int id, {required String uploadState, int? retryCount, String? backendSessionId}) async {
    final db = await _open();
    await db.update(
      'chunk_queue',
      {
        'upload_state': uploadState,
        if (retryCount != null) 'retry_count': retryCount,
        if (backendSessionId != null) 'backend_session_id': backendSessionId,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
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

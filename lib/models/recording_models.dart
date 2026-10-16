/// Mirrors backend/app/models.py::RecordingTriggerType exactly -- lowercase
/// snake_case string values, never invented.
enum TriggerType {
  emergencyButton('emergency_button'),
  manual('manual'),
  remote('remote');

  final String wire;
  const TriggerType(this.wire);
  static TriggerType fromWire(String value) => values.firstWhere((v) => v.wire == value, orElse: () => TriggerType.manual);
}

/// Mirrors backend/app/models.py::RecordingStatus (server-side recording
/// session status) -- NOT the same thing as the client-only
/// RecordingLifecycleState below, which also tracks local states
/// (STARTING, OFFLINE, ...) the backend has no concept of.
enum RecordingStatus {
  recording('recording'),
  completed('completed'),
  cancelled('cancelled'),
  failed('failed');

  final String wire;
  const RecordingStatus(this.wire);
  static RecordingStatus fromWire(String value) => values.firstWhere((v) => v.wire == value, orElse: () => RecordingStatus.failed);
}

/// Mirrors backend/app/schemas.py::RecordingSessionResponse exactly.
class RecordingSessionResponse {
  final String id;
  final String constableId;
  final String deviceId;
  final TriggerType triggerType;
  final RecordingStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? incidentId;
  final DateTime createdAt;
  final int chunkCount;
  final int? highestChunkNumber;
  final List<int> missingChunkNumbers;
  // "not_ready" | "building" | "ready" | "failed" -- mirrors
  // backend/app/schemas.py::RecordingSessionResponse.playable_status
  // exactly. "ready" is the only value for which GET /recordings/{id}/play
  // will actually return media.
  final String playableStatus;
  // "front" | "back" -- the lens actually used for this whole session (set
  // once at /recordings/start). Shown on the Recording Details screen and
  // matches the "CAMERA: ..." text the backend burns into this
  // recording's video frames (see _burn_watermark_best_effort).
  final String cameraLensDirection;

  RecordingSessionResponse({
    required this.id,
    required this.constableId,
    required this.deviceId,
    required this.triggerType,
    required this.status,
    required this.startedAt,
    required this.endedAt,
    required this.incidentId,
    required this.createdAt,
    required this.chunkCount,
    required this.highestChunkNumber,
    required this.missingChunkNumbers,
    this.playableStatus = 'not_ready',
    this.cameraLensDirection = 'back',
  });

  factory RecordingSessionResponse.fromJson(Map<String, dynamic> json) => RecordingSessionResponse(
        id: json['id'] as String,
        constableId: json['constable_id'] as String,
        deviceId: json['device_id'] as String,
        triggerType: TriggerType.fromWire(json['trigger_type'] as String),
        status: RecordingStatus.fromWire(json['status'] as String),
        startedAt: DateTime.parse(json['started_at'] as String),
        endedAt: json['ended_at'] == null ? null : DateTime.parse(json['ended_at'] as String),
        incidentId: json['incident_id'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        chunkCount: json['chunk_count'] as int? ?? 0,
        highestChunkNumber: json['highest_chunk_number'] as int?,
        missingChunkNumbers: (json['missing_chunk_numbers'] as List<dynamic>? ?? const []).map((e) => e as int).toList(),
        playableStatus: json['playable_status'] as String? ?? 'not_ready',
        cameraLensDirection: json['camera_lens_direction'] as String? ?? 'back',
      );
}

/// Mirrors backend/app/schemas.py::VideoChunkResponse exactly.
class VideoChunkResponse {
  final String id;
  final String recordingSessionId;
  final int chunkNumber;
  final int? fileSize;
  final double? durationSeconds;
  final String? fileHash;
  final String? mimeType;
  final bool isLastChunk;
  final String uploadStatus;
  final DateTime createdAt;
  // SHA-256 of the bytes exactly as the phone sent them (the preserved
  // original). Network Hopping uses it to confirm the control room holds
  // identical content before the phone deletes its local copy. Null for
  // chunks stored by an older backend.
  final String? originalHash;

  VideoChunkResponse({
    required this.id,
    required this.recordingSessionId,
    required this.chunkNumber,
    required this.fileSize,
    required this.durationSeconds,
    required this.fileHash,
    required this.mimeType,
    required this.isLastChunk,
    required this.uploadStatus,
    required this.createdAt,
    this.originalHash,
  });

  factory VideoChunkResponse.fromJson(Map<String, dynamic> json) => VideoChunkResponse(
        id: json['id'] as String,
        recordingSessionId: json['recording_session_id'] as String,
        chunkNumber: json['chunk_number'] as int,
        fileSize: json['file_size'] as int?,
        durationSeconds: (json['duration_seconds'] as num?)?.toDouble(),
        fileHash: json['file_hash'] as String?,
        mimeType: json['mime_type'] as String?,
        isLastChunk: json['is_last_chunk'] as bool,
        uploadStatus: json['upload_status'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        originalHash: json['original_hash'] as String?,
      );
}

/// Mirrors backend/app/schemas.py::RecordingManifestResponse exactly.
class RecordingManifestResponse {
  final String recordingSessionId;
  final RecordingStatus status;
  final List<VideoChunkResponse> chunks;
  final int? highestChunkNumber;
  final List<int> missingChunkNumbers;
  final bool isComplete;

  RecordingManifestResponse({
    required this.recordingSessionId,
    required this.status,
    required this.chunks,
    required this.highestChunkNumber,
    required this.missingChunkNumbers,
    required this.isComplete,
  });

  factory RecordingManifestResponse.fromJson(Map<String, dynamic> json) => RecordingManifestResponse(
        recordingSessionId: json['recording_session_id'] as String,
        status: RecordingStatus.fromWire(json['status'] as String),
        chunks: (json['chunks'] as List<dynamic>).map((e) => VideoChunkResponse.fromJson(e as Map<String, dynamic>)).toList(),
        highestChunkNumber: json['highest_chunk_number'] as int?,
        missingChunkNumbers: (json['missing_chunk_numbers'] as List<dynamic>? ?? const []).map((e) => e as int).toList(),
        isComplete: json['is_complete'] as bool,
      );
}

/// Client-only lifecycle for the in-progress recording UI/state machine.
/// The backend only ever sees RecordingStatus (recording/completed/
/// cancelled/failed) -- these extra states (STARTING, UPLOADING, OFFLINE,
/// ...) exist purely so the UI and RecordingService can represent
/// in-progress/local-only conditions the backend has no concept of.
enum RecordingLifecycleState {
  idle,
  starting,
  startFailed,
  recording,
  // Camera capture is deliberately, proactively paused because the app
  // left the foreground -- the CURRENT segment was already gracefully
  // finalized and queued for upload (a real, valid, non-final chunk of
  // the SAME recording session), and a new segment starts the instant the
  // app returns to the foreground (see RecordingService.resumeFromBackground).
  // Distinct from [offline] (camera still running, only the network is
  // down) and from [uploading]/[completing] (an explicit stop is in
  // progress) -- this state means capture itself is paused, nothing else.
  backgroundPaused,
  uploading,
  offline,
  completing,
  completeFailed,
  completed,
  cancelled,
}

/// Local-only queue row for a recorded segment awaiting/undergoing upload.
/// Persisted in sqflite (see offline_queue_service.dart) so it survives app
/// restart -- this is metadata only; the actual segment bytes live in a
/// regular file under the app's documents directory, never inside the DB
/// or SharedPreferences.
class QueuedChunk {
  final int? id; // sqflite autoincrement row id, null before insert
  final String localSessionId; // client-generated UUID for this recording attempt
  final String? backendSessionId; // RecordingSessionResponse.id, set once /recordings/start succeeds
  final int chunkNumber;
  final String localFilePath;
  final double? durationSeconds;
  final bool isLastChunk;
  final String uploadState; // pending | uploading | uploaded | failed
  final int retryCount;
  final DateTime createdAt;
  // Real GPS fix (from LocationService.lastFix, captured the moment this
  // segment finished -- see RecordingService._handleSegmentReady) and the
  // segment's own actual start time, both persisted here so they survive
  // offline queueing/retry/app-restart and are sent to the backend with
  // this exact chunk whenever it eventually uploads (see
  // chunk_uploader.dart). Null latitude/longitude means GPS was genuinely
  // unavailable at capture time -- never a fabricated coordinate.
  final double? latitude;
  final double? longitude;
  final DateTime? recordedAt;

  // --- Network Hopping / integrity fields (queue schema v3) ----------------
  // Client-generated chunk identity, stable across every retry and target.
  final String? chunkId;
  // SHA-256 of the segment file, computed on the phone before the first
  // upload attempt. The receiver and the control room both verify it.
  final String? sha256;
  final int? sizeBytes;
  // Where this chunk was last accepted: 'receiver' | 'central'.
  final String? target;
  final String? siteId;
  // Epoch milliseconds before which this chunk must not be retried
  // (persisted exponential back-off; survives app restarts).
  final int nextAttemptAt;
  final String? lastError;
  final DateTime? localAckAt;

  static const statePending = 'pending';
  static const stateUploading = 'uploading';
  // Accepted and durably stored by the site receiver, NOT yet confirmed by the
  // control room. The local file is kept in this state.
  static const stateLocalAcked = 'local_acked';
  // Confirmed by the control room (direct upload, or reconciled against the
  // central manifest). Only now may the local file be deleted.
  static const stateUploaded = 'uploaded';
  // Permanently rejected (conflict, corruption, forbidden). The local file is
  // preserved. Network failures NEVER put a chunk here.
  static const stateFailed = 'failed';

  QueuedChunk({
    this.id,
    required this.localSessionId,
    required this.backendSessionId,
    required this.chunkNumber,
    required this.localFilePath,
    required this.durationSeconds,
    required this.isLastChunk,
    required this.uploadState,
    required this.retryCount,
    required this.createdAt,
    this.latitude,
    this.longitude,
    this.recordedAt,
    this.chunkId,
    this.sha256,
    this.sizeBytes,
    this.target,
    this.siteId,
    this.nextAttemptAt = 0,
    this.lastError,
    this.localAckAt,
  });

  QueuedChunk copyWith({
    int? id,
    String? backendSessionId,
    String? uploadState,
    int? retryCount,
    String? chunkId,
    String? sha256,
    int? sizeBytes,
    String? target,
    int? nextAttemptAt,
    String? lastError,
    DateTime? localAckAt,
  }) =>
      QueuedChunk(
        id: id ?? this.id,
        localSessionId: localSessionId,
        backendSessionId: backendSessionId ?? this.backendSessionId,
        chunkNumber: chunkNumber,
        localFilePath: localFilePath,
        durationSeconds: durationSeconds,
        isLastChunk: isLastChunk,
        uploadState: uploadState ?? this.uploadState,
        retryCount: retryCount ?? this.retryCount,
        createdAt: createdAt,
        latitude: latitude,
        longitude: longitude,
        recordedAt: recordedAt,
        chunkId: chunkId ?? this.chunkId,
        sha256: sha256 ?? this.sha256,
        sizeBytes: sizeBytes ?? this.sizeBytes,
        target: target ?? this.target,
        siteId: siteId,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        lastError: lastError ?? this.lastError,
        localAckAt: localAckAt ?? this.localAckAt,
      );

  Map<String, dynamic> toDb() => {
        if (id != null) 'id': id,
        'local_session_id': localSessionId,
        'backend_session_id': backendSessionId,
        'chunk_number': chunkNumber,
        'local_file_path': localFilePath,
        'duration_seconds': durationSeconds,
        'is_last_chunk': isLastChunk ? 1 : 0,
        'upload_state': uploadState,
        'retry_count': retryCount,
        'created_at': createdAt.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'recorded_at': recordedAt?.toIso8601String(),
        'chunk_id': chunkId,
        'sha256': sha256,
        'size_bytes': sizeBytes,
        'target': target,
        'site_id': siteId,
        'next_attempt_at': nextAttemptAt,
        'last_error': lastError,
        'local_ack_at': localAckAt?.toIso8601String(),
      };

  factory QueuedChunk.fromDb(Map<String, dynamic> row) => QueuedChunk(
        id: row['id'] as int,
        localSessionId: row['local_session_id'] as String,
        backendSessionId: row['backend_session_id'] as String?,
        chunkNumber: row['chunk_number'] as int,
        localFilePath: row['local_file_path'] as String,
        durationSeconds: (row['duration_seconds'] as num?)?.toDouble(),
        isLastChunk: (row['is_last_chunk'] as int) == 1,
        uploadState: row['upload_state'] as String,
        retryCount: row['retry_count'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
        latitude: (row['latitude'] as num?)?.toDouble(),
        longitude: (row['longitude'] as num?)?.toDouble(),
        recordedAt: row['recorded_at'] == null ? null : DateTime.parse(row['recorded_at'] as String),
        chunkId: row['chunk_id'] as String?,
        sha256: row['sha256'] as String?,
        sizeBytes: row['size_bytes'] as int?,
        target: row['target'] as String?,
        siteId: row['site_id'] as String?,
        nextAttemptAt: (row['next_attempt_at'] as int?) ?? 0,
        lastError: row['last_error'] as String?,
        localAckAt: row['local_ack_at'] == null ? null : DateTime.parse(row['local_ack_at'] as String),
      );
}

/// Local-only record of a recording attempt, persisted so app restart can
/// discover an in-progress/interrupted recording and resume it (see
/// RecordingService.recoverOnStartup).
class LocalRecordingSession {
  final String localSessionId;
  final String? backendSessionId;
  final String deviceIdentifier;
  final TriggerType triggerType;
  final String lifecycleState; // RecordingLifecycleState.name
  final DateTime startedAt;
  final DateTime? endedAt;
  // Network Hopping: the site this recording belongs to (null in Online mode)
  // and the lens used (needed to register the recording with a receiver).
  final String? siteId;
  final bool networkHopping;
  final String cameraLens;

  LocalRecordingSession({
    required this.localSessionId,
    required this.backendSessionId,
    required this.deviceIdentifier,
    required this.triggerType,
    required this.lifecycleState,
    required this.startedAt,
    required this.endedAt,
    this.siteId,
    this.networkHopping = false,
    this.cameraLens = 'back',
  });

  LocalRecordingSession copyWith({String? backendSessionId, String? lifecycleState, DateTime? endedAt}) => LocalRecordingSession(
        localSessionId: localSessionId,
        backendSessionId: backendSessionId ?? this.backendSessionId,
        deviceIdentifier: deviceIdentifier,
        triggerType: triggerType,
        lifecycleState: lifecycleState ?? this.lifecycleState,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        siteId: siteId,
        networkHopping: networkHopping,
        cameraLens: cameraLens,
      );

  Map<String, dynamic> toDb() => {
        'local_session_id': localSessionId,
        'backend_session_id': backendSessionId,
        'device_identifier': deviceIdentifier,
        'trigger_type': triggerType.wire,
        'lifecycle_state': lifecycleState,
        'started_at': startedAt.toIso8601String(),
        'ended_at': endedAt?.toIso8601String(),
        'site_id': siteId,
        'nh_mode': networkHopping ? 1 : 0,
        'camera_lens': cameraLens,
      };

  factory LocalRecordingSession.fromDb(Map<String, dynamic> row) => LocalRecordingSession(
        localSessionId: row['local_session_id'] as String,
        backendSessionId: row['backend_session_id'] as String?,
        deviceIdentifier: row['device_identifier'] as String,
        triggerType: TriggerType.fromWire(row['trigger_type'] as String),
        lifecycleState: row['lifecycle_state'] as String,
        startedAt: DateTime.parse(row['started_at'] as String),
        endedAt: row['ended_at'] == null ? null : DateTime.parse(row['ended_at'] as String),
        siteId: row['site_id'] as String?,
        networkHopping: ((row['nh_mode'] as int?) ?? 0) == 1,
        cameraLens: (row['camera_lens'] as String?) ?? 'back',
      );
}

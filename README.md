# police_body_cam

Flutter/Android client for the body-camera backend in `../backend`. Two
independent features live side by side here:

- **Recording** (`recording_service.dart`, `recording_engine.dart`,
  `chunk_uploader.dart`, `offline_queue_service.dart`) -- captures real
  video+audio to disk and uploads it as evidence via
  `POST /recordings/...`. This is the body-camera feature.
- **Live streaming** (`live_stream_service.dart`) -- an ephemeral LiveKit
  WebRTC view, never recorded or stored. A separate feature; a live view
  is never presented as recorded evidence.

## Running

```
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8000   # Android emulator (default if omitted)
flutter run --dart-define=API_BASE_URL=http://192.168.1.50:8000  # physical device on your LAN
flutter build apk --dart-define=API_BASE_URL=https://bodycam.example.gov  # real deployment
```

`API_BASE_URL` is never hardcoded (see `lib/services/api_client.dart`).
There is no default that points at a specific developer's machine.

## Recording segmentation (read before touching `recording_engine.dart`)

Chunks are **not** produced by slicing bytes out of one big MP4 -- that
produces files no player can open. Instead, the Android camera's own
recorder is stopped and restarted every `segmentDuration` (default 20s).
Each stop/start cycle yields one fully finalized, independently playable
MP4 (video+audio). The honest cost: there is a real, typically
100-400ms, device-dependent gap in the recorded timeline at each segment
boundary while the camera pipeline tears down and re-initializes. This is
not seamless frame-accurate capture -- it's a sequence of independently
verifiable evidence segments with a known, auditable gap between them,
which is an accepted trade-off for chunked, resumable upload rather than
a hidden defect.

## Known limitations (do not claim these work without re-verifying on a real device)

- **Volume-button emergency trigger only works while the app is
  foregrounded and has input focus** (`MainActivity.kt`'s
  `dispatchKeyEvent`). It does NOT fire with the screen off or the app
  backgrounded/killed. True system-wide hardware-key interception in
  those states requires an AccessibilityService, which is not implemented
  here. The in-app "EMERGENCY RECORD" button always works regardless of
  this limitation and is the primary trigger.
- **Background recording survives backgrounding/screen-off, but not a
  full force-kill/swipe-away.** The Android foreground service
  (`foreground_service.dart`) keeps the process alive through normal
  backgrounding; it cannot resurrect a fully killed process. On next
  launch, `RecordingService.recoverOnStartup()` resumes uploading
  whatever was already captured -- no silent data loss, but the in-flight
  segment at the moment of the kill is lost (it was never finalized into
  a valid MP4).
- **Continuous GPS reporting while merely backgrounded (no active
  recording) is not guaranteed.** `ACCESS_BACKGROUND_LOCATION` is
  deliberately not requested (it requires a distinct Play Store
  disclosure flow, out of scope here) -- location reporting is reliable
  in the foreground and during an active recording (the foreground
  service declares the `location` service type), but may be throttled by
  the OS otherwise.
- **None of the above has been verified on a real Android device** as
  part of this implementation pass -- only `flutter analyze`/`flutter
  test`/`flutter build apk` were run. See the delivery report for the
  exact PASS/FAIL/NOT TESTED breakdown.

## Testing

```
flutter test
```

Runs against `package:http/testing.dart`'s `MockClient` (no real backend)
and `sqflite_common_ffi` (no real Android device) -- see `test/services/`
and `test/models/`. Camera/microphone/foreground-service/GPS behavior is
explicitly NOT covered by these tests; it requires a physical device.

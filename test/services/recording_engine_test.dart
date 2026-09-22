// RecordingEngine tests exercised against a MOCKED native MethodChannel
// (com.policebodycam.recording) rather than real CameraX/hardware -- no
// Android device is available in this environment. What these tests
// genuinely verify is the Dart-side half of the contract between this
// engine and NativeRecordingManager.kt, specifically the fix for a REAL,
// physically-reproduced evidence-loss bug (see that Kotlin file's and this
// file's own doc comments): stop() must not let its caller proceed until
// the final segment has actually been produced AND fully enqueued, no
// matter how quickly (or in what order) the native side's platform-channel
// messages happen to arrive.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:police_body_cam/services/recording_engine.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  final String rootPath;
  _FakePathProviderPlatform(this.rootPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.policebodycam.recording');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('bodycam_engine_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempRoot.path);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// Simulates a native->Dart call arriving on the recording channel --
  /// the officially-supported way to exercise a MethodChannel's registered
  /// setMethodCallHandler from a plain `flutter test` (no real platform).
  Future<void> simulateNativeCall(MethodCall call) async {
    final data = channel.codec.encodeMethodCall(call);
    final completer = Completer<void>();
    await messenger.handlePlatformMessage(channel.name, data, (_) => completer.complete());
    await completer.future;
  }

  group('stop() final-segment ordering (regression: chunk loss during remote STOP)', () {
    test('stop() does not complete until the final segment has been fully enqueued, even when native resolves "stop" immediately', () async {
      final enqueueOrder = <String>[];
      final enqueuedChunkNumbers = <int>[];

      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          // Reproduces the OLD buggy native behavior on purpose: resolve
          // "stop" immediately, THEN deliver "segmentReady" for the final
          // segment slightly later -- exactly the ordering that physically
          // lost a chunk on a real device. If this test passes, it proves
          // engine.stop() no longer trusts that resolution alone.
          unawaited(Future<void>.delayed(const Duration(milliseconds: 15), () {
            simulateNativeCall(const MethodCall('segmentReady', {
              'chunkNumber': 16,
              'path': '/fake/segment_000016.mp4',
              'durationSeconds': 1.9,
              'isLastChunk': true,
              'startedAtMillis': 0,
            }));
          }));
          return null;
        }
        return null;
      });

      final engine = RecordingEngine(
        onSegmentReady: (segment) async {
          enqueueOrder.add('enqueue-start:${segment.chunkNumber}');
          // Simulates the real, non-instant work RecordingService._handleSegmentReady
          // actually awaits (OfflineQueueService.enqueueChunk's DB write).
          await Future<void>.delayed(const Duration(milliseconds: 10));
          enqueuedChunkNumbers.add(segment.chunkNumber);
          enqueueOrder.add('enqueue-done:${segment.chunkNumber}');
        },
        onError: (_) {},
      );

      await engine.start(localSessionId: 'regression-test');
      final stopFuture = engine.stop();
      enqueueOrder.add('stop-called');

      await stopFuture;
      enqueueOrder.add('stop-completed');

      expect(enqueuedChunkNumbers, contains(16), reason: 'the final chunk must be enqueued before stop() ever returns');
      expect(
        enqueueOrder.indexOf('enqueue-done:16'),
        lessThan(enqueueOrder.indexOf('stop-completed')),
        reason: 'stop() completed before the final segment finished enqueuing -- this is the exact race that lost real evidence footage',
      );
    });

    test('a final segment reported via recordingError (finalize failed) still unblocks a pending stop() instead of hanging forever', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          unawaited(Future<void>.delayed(const Duration(milliseconds: 10), () {
            simulateNativeCall(const MethodCall('recordingError', 'segment 3 finalize error code=1: boom'));
          }));
          return null;
        }
        return null;
      });

      final errors = <Object>[];
      final engine = RecordingEngine(onSegmentReady: (_) async {}, onError: errors.add);

      await engine.start(localSessionId: 'error-test');
      await engine.stop().timeout(
        const Duration(seconds: 2),
        onTimeout: () => fail('stop() hung -- a failed finalize of the final segment must still resolve a pending stop()'),
      );

      expect(errors, isNotEmpty);
    });

    test('normal (non-final) segment events do not resolve a pending stop early', () async {
      final resolvedBeforeFinal = <bool>[];

      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          unawaited(() async {
            // A normal mid-recording segment first (isLastChunk: false) --
            // must NOT unblock stop() -- then the real final one.
            await simulateNativeCall(const MethodCall('segmentReady', {
              'chunkNumber': 1,
              'path': '/fake/segment_000001.mp4',
              'durationSeconds': 20.0,
              'isLastChunk': false,
              'startedAtMillis': 0,
            }));
            resolvedBeforeFinal.add(false); // if stop() already returned by now, the test below catches it
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await simulateNativeCall(const MethodCall('segmentReady', {
              'chunkNumber': 2,
              'path': '/fake/segment_000002.mp4',
              'durationSeconds': 3.0,
              'isLastChunk': true,
              'startedAtMillis': 0,
            }));
          }());
          return null;
        }
        return null;
      });

      final ready = <int>[];
      final engine = RecordingEngine(onSegmentReady: (s) async => ready.add(s.chunkNumber), onError: (_) {});
      await engine.start(localSessionId: 'ordering-test');
      await engine.stop();

      expect(ready, [1, 2], reason: 'both segments must have been delivered, in order, by the time stop() returns');
    });

    test('repeated stop() calls remain safe and both resolve once the final segment arrives', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'started': true};
        if (call.method == 'stop') {
          unawaited(Future<void>.delayed(const Duration(milliseconds: 10), () {
            simulateNativeCall(const MethodCall('segmentReady', {
              'chunkNumber': 5,
              'path': '/fake/segment_000005.mp4',
              'durationSeconds': 2.0,
              'isLastChunk': true,
              'startedAtMillis': 0,
            }));
          }));
          return null;
        }
        return null;
      });

      final engine = RecordingEngine(onSegmentReady: (_) async {}, onError: (_) {});
      await engine.start(localSessionId: 'idempotent-test');

      final first = engine.stop();
      final second = engine.stop(); // fired before the first has resolved -- must not hang or double-invoke native "stop" incorrectly
      await Future.wait([first, second]).timeout(const Duration(seconds: 2));

      expect(engine.isRecording, isFalse);
    });

    test('normal segment rotation (no stop requested) is unaffected by the fix', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'start') return {'started': true};
        return null;
      });

      final ready = <int>[];
      final engine = RecordingEngine(onSegmentReady: (s) async => ready.add(s.chunkNumber), onError: (_) {});
      await engine.start(localSessionId: 'rotation-test');

      await simulateNativeCall(const MethodCall('segmentReady', {
        'chunkNumber': 1,
        'path': '/fake/segment_000001.mp4',
        'durationSeconds': 20.0,
        'isLastChunk': false,
        'startedAtMillis': 0,
      }));

      expect(ready, [1]);
      expect(engine.isRecording, isTrue, reason: 'a non-final segment must never flip isRecording off');
    });
  });
}

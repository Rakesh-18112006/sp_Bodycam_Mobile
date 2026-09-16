// Regression tests for a real physical-device-reproduced CRITICAL bug
// (Redmi Note 10 Pro / OPPO CPH2751, Wi-Fi toggled off then back on while
// recording): CommandListenerService's reconnect logic could schedule
// MULTIPLE overlapping reconnect timers for a single failure (the stream's
// onDone/onError handler AND the outer catch block each independently
// called _scheduleReconnect(), and _scheduleReconnect() itself overwrote
// _reconnectTimer without cancelling the previous one). Each surviving
// timer went on to open its own new socket without closing any sibling's
// socket. Reproduced on real hardware: 16-32 concurrent WebSocket
// connections from ONE phone within ~5 seconds, which exhausted the
// backend's SQLAlchemy connection pool (QueuePool limit of size 5 overflow
// 10 reached) and made the backend unresponsive to every other client
// until it was manually restarted.
//
// These tests exercise the actual CommandListenerService class (not just
// the underlying web_socket_channel library, unlike the earlier
// websocket_ready_test.dart) via two small, precedented testing seams
// added alongside the fix -- channelConnector and reconnectDelayFor --
// which mirror the existing ApiClient.httpClient/networkTimeout pattern
// already used elsewhere in this codebase for testability. Production
// code never overrides either.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/services/command_listener_service.dart';

class _FakeStore implements TokenStore {
  @override
  Future<void> delete(String key) async {}
  @override
  Future<String?> read(String key) async => 'test-token';
  @override
  Future<void> write(String key, String value) async {}
}

/// A minimal, fully-controllable fake WebSocketChannel. [readyOutcome]
/// decides whether `channel.ready` resolves (a successful handshake) or
/// throws (a rejected/failed connection); [autoCloseStream], if true,
/// closes the stream (triggering onDone) shortly after construction to
/// simulate a connection that drops immediately after being accepted.
class _FakeChannel with StreamChannelMixin implements WebSocketChannel {
  final _controller = StreamController<dynamic>();
  final _readyCompleter = Completer<void>();
  int closeCalls = 0;

  _FakeChannel({required bool readySucceeds, bool autoCloseStream = false}) {
    if (readySucceeds) {
      _readyCompleter.complete();
    } else {
      _readyCompleter.completeError(StateError('fake connect failure'));
    }
    if (autoCloseStream) {
      scheduleMicrotask(() => _controller.close());
    }
  }

  void emitError() => _controller.addError(StateError('fake stream error'));
  void emitDone() => _controller.close();
  void emitMessage(String m) => _controller.add(m);

  @override
  Stream get stream => _controller.stream;
  @override
  Future<void> get ready => _readyCompleter.future;
  @override
  WebSocketSink get sink => _FakeSink(this);
  @override
  String? get protocol => null;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class _FakeSink implements WebSocketSink {
  final _FakeChannel _owner;
  _FakeSink(this._owner);
  @override
  Future close([int? closeCode, String? closeReason]) async {
    _owner.closeCalls++;
  }

  @override
  void add(dynamic event) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future addStream(Stream stream) async {}
  @override
  Future get done => Future.value();
}

void main() {
  setUp(() {
    ApiClient.tokenStore = _FakeStore();
    // Shrink the real 1s/2s/4s/8s/15s backoff to milliseconds so these
    // tests run in well under a second instead of tens of real seconds.
    CommandListenerService.reconnectDelayFor = (retryCount) => Duration(milliseconds: (1 << retryCount).clamp(1, 15) * 10);
  });

  tearDown(() {
    CommandListenerService.channelConnector = WebSocketChannel.connect;
    CommandListenerService.reconnectDelayFor = (retryCount) => Duration(seconds: (1 << retryCount).clamp(1, 15));
  });

  CommandListenerService newService() => CommandListenerService(
        deviceId: 'device-1',
        onCommand: (_, _) {},
        onUnknownCommand: (_) {},
      );

  test('a connection that fails BOTH via stream error and via ready throwing schedules only ONE reconnect attempt', () async {
    var connectCount = 0;
    final channels = <_FakeChannel>[];
    CommandListenerService.channelConnector = (uri) {
      connectCount++;
      // Fails both ways at once -- exactly the dual-failure-path scenario
      // that used to double-schedule reconnects.
      final c = _FakeChannel(readySucceeds: false, autoCloseStream: true);
      channels.add(c);
      return c;
    };

    final service = newService();
    await service.start();
    // Let the first (failed) attempt's callbacks and the resulting
    // reconnect timer settle.
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(connectCount, 1, reason: 'exactly one connection attempt for the initial failure');

    // Wait just past the first backoff delay (10ms at retryCount=0) but
    // well before the SECOND backoff delay (20ms at retryCount=1) could
    // also elapse -- if the bug were present, TWO (or more) reconnect
    // timers would have been scheduled from the single failure, so this
    // narrow window would already show more than 2 attempts.
    await Future<void>.delayed(const Duration(milliseconds: 16));
    expect(connectCount, 2, reason: 'the single failure must result in exactly one scheduled reconnect, not a branching storm');

    service.stop();
  });

  test('reconnect replaces the previous channel -- the old one is closed, never left alive', () async {
    final channels = <_FakeChannel>[];
    CommandListenerService.channelConnector = (uri) {
      final c = _FakeChannel(readySucceeds: true);
      channels.add(c);
      return c;
    };

    final service = newService();
    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(channels, hasLength(1));

    // Simulate the live connection dropping (server closed it).
    channels.first.emitDone();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(channels.length, greaterThanOrEqualTo(2), reason: 'a reconnect attempt must have been made');
    expect(channels.first.closeCalls, 1, reason: 'the superseded channel must be closed exactly once when replaced');

    service.stop();
  });

  test('a successful reconnect cancels any pending reconnect work -- status settles on connected, not stuck reconnecting', () async {
    var attempt = 0;
    CommandListenerService.channelConnector = (uri) {
      attempt++;
      // First attempt fails outright; second succeeds.
      return _FakeChannel(readySucceeds: attempt > 1, autoCloseStream: attempt == 1);
    };

    final statuses = <CommandChannelStatus>[];
    final service = CommandListenerService(
      deviceId: 'device-1',
      onCommand: (_, _) {},
      onUnknownCommand: (_) {},
      onStatusChanged: statuses.add,
    );
    await service.start();
    // First attempt fails, reconnect scheduled (~10ms), second attempt
    // succeeds -- give it time to settle.
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(service.status, CommandChannelStatus.connected);
    expect(statuses.last, CommandChannelStatus.connected);

    service.stop();
  });

  test('stop() prevents any further reconnect, even one already scheduled', () async {
    var connectCount = 0;
    CommandListenerService.channelConnector = (uri) {
      connectCount++;
      return _FakeChannel(readySucceeds: false, autoCloseStream: true);
    };

    final service = newService();
    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(connectCount, 1);

    service.stop(); // a reconnect timer is pending at this point -- stop() must cancel it
    final countAtStop = connectCount;

    // Wait well past when the pending (and any further) reconnect would
    // have fired if stop() failed to cancel it.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(connectCount, countAtStop, reason: 'a disposed/stopped service must never reconnect itself');
    expect(service.status, CommandChannelStatus.disconnected);
  });

  test('backoff grows monotonically (1x, 2x, 4x, 8x, ...) across consecutive real failures, never resetting mid-storm', () async {
    final attemptTimes = <DateTime>[];
    CommandListenerService.channelConnector = (uri) {
      attemptTimes.add(DateTime.now());
      return _FakeChannel(readySucceeds: false, autoCloseStream: true);
    };

    final service = newService();
    await service.start();
    // 5 failures at 10/20/40/80/150ms (per the x10ms test scale) sum to
    // ~300ms; give it comfortably more.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    service.stop();

    expect(attemptTimes.length, greaterThanOrEqualTo(4), reason: 'expected multiple sequential retries within the window');
    final gaps = <int>[
      for (var i = 1; i < attemptTimes.length; i++) attemptTimes[i].difference(attemptTimes[i - 1]).inMilliseconds,
    ];
    // Each gap should be roughly non-decreasing (allow scheduling jitter)
    // -- this is what "linear backoff, not exponential branching" looks
    // like from the outside: attempts spread out over time instead of
    // clustering within a few milliseconds of each other.
    for (var i = 1; i < gaps.length; i++) {
      expect(gaps[i], greaterThanOrEqualTo(gaps[i - 1] - 5), reason: 'gap between attempt ${i + 1} and ${i + 2} regressed -- backoff is not monotonic');
    }
  });

  test('rapid repeated disconnect signals for the SAME connection do not create parallel reconnect attempts', () async {
    var connectCount = 0;
    final channels = <_FakeChannel>[];
    CommandListenerService.channelConnector = (uri) {
      connectCount++;
      final c = _FakeChannel(readySucceeds: true);
      channels.add(c);
      return c;
    };

    final service = newService();
    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(connectCount, 1);

    // Fire both onError AND onDone for the same live channel in rapid
    // succession -- exactly race B/C from the fix's design notes.
    channels.first.emitError();
    channels.first.emitDone();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // Only ONE reconnect should have been scheduled for this single dead
    // connection, so only one new attempt appears after the backoff delay.
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(connectCount, 2, reason: 'dual onError+onDone for one dead socket must still produce exactly one reconnect');

    service.stop();
  });

  test('start() called again while already connected does not open a second channel', () async {
    var connectCount = 0;
    CommandListenerService.channelConnector = (uri) {
      connectCount++;
      return _FakeChannel(readySucceeds: true);
    };

    final service = newService();
    await service.start();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(connectCount, 1);

    await service.start(); // redundant call while already connected
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(connectCount, 1, reason: 'a redundant start() while already connected must not open a competing channel');

    service.stop();
  });
}

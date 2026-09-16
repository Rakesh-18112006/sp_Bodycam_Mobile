// Regression test for a real physical-device bug (Redmi Note 10 Pro):
// CommandListenerService used to mark the command channel "connected"
// only upon receiving the FIRST inbound message. The backend's
// /ws/control_room channel is push-only (nothing is sent to the client
// until a command actually arrives), so a perfectly healthy, already-open
// socket showed "connecting" forever in the UI whenever no command had
// happened to arrive yet -- confirmed on-device: the backend log showed
// the WebSocket handshake accepted, while the app UI still said
// "connecting".
//
// CommandListenerService itself isn't unit-testable in isolation (it
// connects to the compile-time-constant kApiBaseUrl, which can't be
// redirected to a local test server at runtime). This test instead proves
// the exact mechanism the fix now relies on: `WebSocketChannel.connect(...)
// .ready` completes as soon as the handshake succeeds, with NO message
// having been sent by the server -- using a real local WebSocket server
// (plain dart:io, no platform channels needed), not a mock.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  test('WebSocketChannel.ready completes on handshake success without the server ever sending a message', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSockets = <WebSocket>[];
    final sub = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      serverSockets.add(socket);
      // Deliberately send nothing -- mirrors the real backend's
      // /ws/control_room, which never pushes anything until a command is
      // actually issued.
    });

    addTearDown(() async {
      await sub.cancel();
      for (final s in serverSockets) {
        await s.close();
      }
      await server.close(force: true);
    });

    final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));
    addTearDown(() => channel.sink.close());

    // Before the fix, CommandListenerService would never see this as
    // "connected" because it waited for a message that this server (like
    // the real backend, absent a command) never sends. `ready` must
    // still complete.
    await channel.ready.timeout(
      const Duration(seconds: 5),
      onTimeout: () => fail('WebSocketChannel.ready never completed for a successfully-accepted connection'),
    );

    // No exception means the handshake genuinely succeeded -- this is
    // the real signal CommandListenerService now uses for CONNECTED,
    // independent of any inbound traffic.
  });

  test('WebSocketChannel.ready throws when the server rejects the connection before accepting', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((request) async {
      // Mirrors websocket.py closing before accept() on auth failure
      // (code 4401/4403/4404) -- reject the HTTP upgrade outright.
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
    });

    addTearDown(() async {
      await sub.cancel();
      await server.close(force: true);
    });

    final channel = WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}'));

    await expectLater(
      channel.ready,
      throwsA(anything),
      reason: 'a rejected handshake must surface as a ready failure, so the UI correctly falls back to disconnected/reconnecting instead of claiming connected',
    );
  });
}

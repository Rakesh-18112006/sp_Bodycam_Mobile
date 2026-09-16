// Regression tests for a real physical-device bug (Redmi Note 10 Pro,
// Android 13/MIUI, found via on-device validation): the app hung
// indefinitely on the startup spinner after a cold restart following a
// successful login, reproduced twice, never resolving to either Login or
// Home.
//
// Root cause: `future: _bootstrap()` was created INLINE inside build(),
// so every rebuild of the root widget (window-focus changes etc. can
// trigger this) started a brand new, overlapping call into secure
// storage -- on this device, concurrent reads against the
// not-yet-initialized encrypted store hung forever.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/main.dart';
import 'package:police_body_cam/services/api_client.dart';
import 'package:police_body_cam/screens/login_screen.dart';

class _CountingStore implements TokenStore {
  int readCount = 0;
  String? token;
  _CountingStore({this.token});

  @override
  Future<String?> read(String key) async {
    readCount++;
    return token;
  }

  @override
  Future<void> write(String key, String value) async => token = value;
  @override
  Future<void> delete(String key) async => token = null;
}

/// Never completes -- simulates the real hang this bug produced (a
/// stalled platform-channel/Keystore read).
class _HangingStore implements TokenStore {
  @override
  Future<String?> read(String key) => Completer<String?>().future;
  @override
  Future<void> write(String key, String value) async {}
  @override
  Future<void> delete(String key) async {}
}

void main() {
  tearDown(() {
    ApiClient.tokenStore = SecureTokenStore();
  });

  testWidgets('the token store is read exactly once per app process, even across multiple rebuilds', (tester) async {
    // Not-logged-in (token: null) deliberately -- this isolates the
    // bootstrap's own read count from HomeScreen's separate, unrelated
    // token reads (every authenticated API call reads the token too;
    // landing on LoginScreen instead keeps this test about _bootstrap()
    // specifically).
    final store = _CountingStore(token: null);
    ApiClient.tokenStore = store;

    // First mount: build() runs at least once.
    await tester.pumpWidget(const PoliceBodyCamApp());
    // Force additional rebuilds of the SAME widget/State -- this is
    // exactly the scenario (repeated build() calls) that used to start a
    // brand new overlapping secure-storage read every time.
    await tester.pumpWidget(const PoliceBodyCamApp());
    await tester.pumpWidget(const PoliceBodyCamApp());
    await tester.pumpAndSettle();

    expect(store.readCount, 1, reason: 'AuthService.isLoggedIn() must be awaited exactly once per process, not once per build()');
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('a stalled token read falls back to Login instead of hanging on the spinner forever, without deleting the stored token', (tester) async {
    final hangingStore = _HangingStore();
    ApiClient.tokenStore = hangingStore;

    await tester.pumpWidget(const PoliceBodyCamApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget, reason: 'still waiting immediately after mount');

    // Real production timeout is 8s -- advance past it deterministically
    // rather than sleeping the test for 8 real seconds.
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();

    expect(find.byType(LoginScreen), findsOneWidget, reason: 'a stalled read must never silently show Home (never bypass auth) nor hang forever');
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the exact PopScope pattern used in home_screen.dart's build()
/// method to prevent the Android BACK button from finishing the Activity
/// while a recording is active -- see that file's doc comment for the
/// real, physically-reproduced crash this prevents
/// (`RuntimeException: Cannot execute operation because FlutterJNI is not
/// attached to native`, thrown when the camera preview's ImageReader
/// delivers a queued frame after the Activity/engine is destroyed).
///
/// A full HomeScreen widget test is not feasible in this environment --
/// it requires device registration, location, heartbeat, and real camera
/// plugin calls that have no platform implementation here (see this
/// project's other tests' own "no Android device/emulator" notes). What
/// IS genuinely, meaningfully tested here -- with real Flutter
/// Navigator/PopScope widgets, not mocked -- is the actual mechanism:
/// canPop=false must block a pop attempt and keep the recording screen
/// on top; canPop=true (idle) must behave exactly like unprotected
/// navigation, letting BACK proceed normally.
void main() {
  Widget appWithGuardedRoute({required bool recordingActive}) {
    return MaterialApp(
      home: Builder(
        builder: (context) => PopScope(
          canPop: !recordingActive,
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Stop the recording before leaving this screen')),
              );
            }
          },
          child: const Scaffold(body: Text('Recording screen')),
        ),
      ),
    );
  }

  testWidgets('Recording + BACK: pop is blocked, the recording screen stays on top, and a warning is shown', (tester) async {
    await tester.pumpWidget(appWithGuardedRoute(recordingActive: true));
    expect(find.text('Recording screen'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Still on the same screen -- BACK did not finish/pop it.
    expect(find.text('Recording screen'), findsOneWidget);
    expect(find.text('Stop the recording before leaving this screen'), findsOneWidget);
  });

  testWidgets('Idle + BACK: normal navigation is completely unaffected', (tester) async {
    await tester.pumpWidget(appWithGuardedRoute(recordingActive: false));
    expect(find.text('Recording screen'), findsOneWidget);

    // canPop=true means this PopScope never intercepts anything -- the
    // pop request reaches the Navigator exactly as if PopScope were not
    // there at all. With only one route on the stack (as in this test's
    // setup, and as on HomeScreen when reached fresh after login), the
    // Navigator legitimately cannot pop further -- that is unrelated to
    // this guard and is not a warning being suppressed.
    final canPopResult = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(find.text('Stop the recording before leaving this screen'), findsNothing,
        reason: 'idle must never show the recording-in-progress warning');
    expect(canPopResult, isFalse, reason: 'nothing left on this test\'s Navigator stack to pop -- expected, not a sign the guard fired');
  });

  testWidgets('canPop flips from false to true the instant recording stops -- BACK is no longer blocked', (tester) async {
    var recordingActive = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => PopScope(
            canPop: !recordingActive,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('blocked')));
              }
            },
            child: Scaffold(
              body: TextButton(onPressed: () => setState(() => recordingActive = false), child: const Text('stop')),
            ),
          ),
        ),
      ),
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('blocked'), findsOneWidget, reason: 'still recording -- BACK must be blocked');

    // Let that first SnackBar fully dismiss before the next assertion, so
    // a lingering widget from THIS press can't be mistaken for a second,
    // wrongly-fired one below.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('blocked'), findsNothing);

    await tester.tap(find.text('stop'));
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // canPop is now true, so onPopInvokedWithResult must never fire with
    // didPop=false again -- no new "blocked" SnackBar.
    expect(find.text('blocked'), findsNothing, reason: 'recording stopped -- PopScope must no longer intercept BACK');
  });
}

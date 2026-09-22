import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/auth_service.dart';
import 'services/recording_service.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme/app_theme.dart';

/// Root navigator key so the centralized 401 handler (see
/// HomeScreen._installGlobalUnauthorizedHandler) can return to the login
/// screen from anywhere -- a background heartbeat/upload/location call,
/// not just a user-initiated tap -- without needing a BuildContext of its
/// own (implementation brief §20: "Do this centrally rather than
/// duplicating logic in every screen").
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> forceLogoutAndReturnToLogin() async {
  await AuthService.logout();
  rootNavigatorKey.currentState?.pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => const LoginScreen()),
    (route) => false,
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required once, before runApp(), for the notification's START/STOP
  // RECORDING button to actually route to the app's background task
  // handler instead of only opening the app -- physical device testing
  // found button presses were falling back to a plain "open the app" tap
  // and throwing MissingPluginException(...flutter_foreground_task/background)
  // without this (see ForegroundRecordingService's doc comment for the
  // full explanation).
  FlutterForegroundTask.initCommunicationPort();
  runApp(const PoliceBodyCamApp());
}

class PoliceBodyCamApp extends StatefulWidget {
  const PoliceBodyCamApp({super.key});

  @override
  State<PoliceBodyCamApp> createState() => _PoliceBodyCamAppState();
}

class _PoliceBodyCamAppState extends State<PoliceBodyCamApp> {
  /// ROOT CAUSE of a real physical-device bug (Redmi Note 10 Pro, Android
  /// 13/MIUI, found via on-device validation): this Future used to be
  /// created inline as `future: _bootstrap()` directly in build(). Flutter
  /// can and does call build() more than once for a widget that is still
  /// the same logical screen (window-focus changes, metrics changes,
  /// etc.), and each call created a BRAND NEW Future, i.e. a brand new
  /// overlapping call into secure storage. On this device, two concurrent
  /// reads against the same not-yet-initialized EncryptedSharedPreferences
  /// entry hung forever, stranding the user on the startup spinner with no
  /// way back to Login or Home. Computing the Future exactly once here,
  /// cached for the lifetime of this State, guarantees isLoggedIn() is
  /// only ever awaited a single time per app process.
  late final Future<bool> _bootstrapFuture = _bootstrap();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Police Body Camera',
      theme: buildAppTheme(),
      home: FutureBuilder<bool>(
        future: _bootstrapFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return snapshot.data! ? const HomeScreen() : const LoginScreen();
        },
      ),
    );
  }

  /// Runs startup recording recovery (implementation brief §12) BEFORE
  /// deciding which screen to show -- a still-logged-in constable whose
  /// app was killed mid-recording should have their queued chunks resume
  /// uploading as early as possible, not only once they happen to open
  /// the home screen and manually start a new recording.
  Future<bool> _bootstrap() async {
    // Defense-in-depth safety net (NOT the fix for the hang above -- see
    // the class doc comment). Even with a single cached read, a stalled
    // platform channel/Keystore call must never strand the user on the
    // spinner forever. On timeout this launch is treated as "not logged
    // in" -- Login is shown and the user can sign back in -- but the
    // stored token itself is never touched/deleted, so a transient
    // startup problem can never destroy a valid session.
    bool loggedIn;
    try {
      loggedIn = await AuthService.isLoggedIn().timeout(const Duration(seconds: 8));
    } on TimeoutException {
      loggedIn = false;
    }
    if (loggedIn) {
      // Fire-and-forget: recovery must never block showing the UI, and a
      // slow/offline recovery attempt should not look like a frozen splash
      // screen.
      // ignore: unawaited_futures
      RecordingService.recoverOnStartup(onRecovered: (msg) => debugPrint('[recovery] $msg'));
    }
    return loggedIn;
  }
}

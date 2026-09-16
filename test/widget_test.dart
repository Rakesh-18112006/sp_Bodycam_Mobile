import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:police_body_cam/main.dart';

void main() {
  testWidgets('App boots to a spinner while checking login state', (WidgetTester tester) async {
    await tester.pumpWidget(const PoliceBodyCamApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Flush the bootstrap's pending safety-net timeout timer (see
    // main.dart's _bootstrap) before the test ends -- otherwise
    // flutter_test's leaked-timer check fails even though the app itself
    // is behaving correctly (this is a real, dart:async Timer now, unlike
    // before the timeout safety net existed).
    await tester.pumpAndSettle(const Duration(seconds: 9));
  });
}

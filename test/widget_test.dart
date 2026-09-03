import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:police_body_cam/main.dart';

void main() {
  testWidgets('App boots to a spinner while checking login state', (WidgetTester tester) async {
    await tester.pumpWidget(const PoliceBodyCamApp());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}

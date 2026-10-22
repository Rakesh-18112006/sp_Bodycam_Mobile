import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:police_body_cam/models/network_alert_models.dart';
import 'package:police_body_cam/widgets/network_alert_host.dart';

NetworkAlert _alert(String id, {String title = 'FIRE', String severity = 'emergency'}) => NetworkAlert(
      alertId: id,
      siteId: 's',
      siteName: 'Huawei Building',
      title: title,
      message: 'Evacuate the building',
      severity: severity,
      createdAt: DateTime.now(),
    );

void main() {
  testWidgets('the alert screen is a full-screen red surface with the title, message and an ACKNOWLEDGE button', (tester) async {
    String? acked;
    await tester.pumpWidget(MaterialApp(
      home: NetworkAlertScreen(alerts: [_alert('a1'), _alert('a2', title: 'DRILL')], onAcknowledge: (id) async => acked = id),
    ));
    final material = tester.widget<Material>(find.byKey(const Key('network-alert-screen')));
    expect(material.color, alertColor('emergency'));
    expect((material.color!.r * 255).round(), greaterThan(180));
    expect((material.color!.g * 255).round(), lessThan(60)); // clearly red
    expect(tester.getSize(find.byKey(const Key('network-alert-screen'))), tester.view.physicalSize / tester.view.devicePixelRatio);
    expect(find.text('FIRE'), findsOneWidget);
    expect(find.text('Evacuate the building'), findsOneWidget);
    expect(find.text('1 more alert waiting'), findsOneWidget);
    await tester.tap(find.byKey(const Key('network-alert-ack')));
    await tester.pump();
    expect(acked, 'a1');
    await tester.pumpWidget(const SizedBox()); // dispose the haptic timer
  });
}

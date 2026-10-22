import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/network_alert_models.dart';
import '../services/network_alert_service.dart';

/// Wraps the whole app (MaterialApp.builder). While the server has an unacknowledged alert for a network the officer is
/// logged in to, the entire screen turns red on top of whatever screen is showing, until the person acknowledges it or the
/// control room clears it. Recording and uploads keep running underneath; only the UI is covered.
class NetworkAlertHost extends StatelessWidget {
  final Widget child;
  final NetworkAlertService? service; // injectable for tests
  const NetworkAlertHost({super.key, required this.child, this.service});

  @override
  Widget build(BuildContext context) {
    final svc = service ?? NetworkAlertService.instance;
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final alerts = svc.activeAlerts;
        return Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (alerts.isNotEmpty) Positioned.fill(child: NetworkAlertScreen(alerts: alerts, onAcknowledge: svc.acknowledge)),
          ],
        );
      },
    );
  }
}

/// Every severity is a red screen; the shade only helps tell them apart (the severity is also written on the screen).
Color alertColor(String severity) {
  switch (severity) {
    case 'info':
      return const Color(0xFFB71C1C);
    case 'warning':
      return const Color(0xFFC62828);
    case 'emergency':
      return const Color(0xFFD50000);
    default:
      return const Color(0xFFD32F2F);
  }
}

/// Full-screen red alert. Shows the newest alert; if several are active, says how many more wait behind it.
class NetworkAlertScreen extends StatefulWidget {
  final List<NetworkAlert> alerts;
  final Future<void> Function(String alertId) onAcknowledge;
  const NetworkAlertScreen({super.key, required this.alerts, required this.onAcknowledge});

  @override
  State<NetworkAlertScreen> createState() => _NetworkAlertScreenState();
}

class _NetworkAlertScreenState extends State<NetworkAlertScreen> {
  Timer? _buzz;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    HapticFeedback.heavyImpact();
    _buzz = Timer.periodic(const Duration(milliseconds: 1500), (_) => HapticFeedback.heavyImpact());
  }

  @override
  void dispose() {
    _buzz?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.alerts.first;
    final more = widget.alerts.length - 1;
    return Material(
      key: const Key('network-alert-screen'),
      color: alertColor(a.severity),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.warning_amber_rounded, size: 96, color: Colors.white),
              const SizedBox(height: 16),
              Text(
                '${a.severity.toUpperCase()} ALERT${a.siteName == null ? '' : ' · ${a.siteName}'}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 1.2),
              ),
              const SizedBox(height: 12),
              Text(a.title, key: const Key('network-alert-title'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900)),
              if (a.message.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(a.message, key: const Key('network-alert-message'), textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20)),
              ],
              const Spacer(),
              if (more > 0) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text('$more more alert${more == 1 ? '' : 's'} waiting', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70))),
              FilledButton(
                key: const Key('network-alert-ack'),
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: alertColor(a.severity), padding: const EdgeInsets.symmetric(vertical: 18)),
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        await widget.onAcknowledge(a.alertId);
                        if (mounted) setState(() => _busy = false);
                      },
                child: const Text('ACKNOWLEDGE', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

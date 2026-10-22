import 'package:flutter/material.dart';
import '../services/network_alert_service.dart';
import '../theme/app_theme.dart';

/// Log in to / out of a building network (for example the Huawei HG532d building). While logged in, alerts the control room
/// raises for that network turn this phone's screen red until acknowledged.
class NetworkLoginScreen extends StatefulWidget {
  const NetworkLoginScreen({super.key});
  @override
  State<NetworkLoginScreen> createState() => _NetworkLoginScreenState();
}

class _NetworkLoginScreenState extends State<NetworkLoginScreen> {
  final _svc = NetworkAlertService.instance;
  final _codeCtl = TextEditingController();
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _svc.refreshNetworks();
  }

  @override
  void dispose() {
    _codeCtl.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() action, {String? ok}) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final problem = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = problem ?? ok;
    });
  }

  String _channelText(AlertChannelStatus s) {
    switch (s) {
      case AlertChannelStatus.connected:
        return 'Alert channel connected';
      case AlertChannelStatus.connecting:
        return 'Connecting to the alert channel…';
      case AlertChannelStatus.disconnected:
        return 'Alert channel offline. Retrying. Alerts raised meanwhile are fetched when it reconnects.';
      case AlertChannelStatus.stopped:
        return 'Alert channel stopped';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network login')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _svc,
          builder: (context, _) {
            final connected = _svc.status == AlertChannelStatus.connected;
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(color: connected ? AppColors.successBg : AppColors.warningBg, borderRadius: BorderRadius.circular(AppRadii.sm)),
                  child: Row(children: [
                    Icon(connected ? Icons.check_circle : Icons.info_outline, size: 18, color: connected ? AppColors.success : AppColors.warning),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_channelText(_svc.status))),
                  ]),
                ),
                const SizedBox(height: AppSpacing.lg),
                Text('Your networks', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                if (_svc.networks.isEmpty)
                  Text(_svc.lastError == null ? 'No networks are assigned to you. Ask the control room, or enter a network code below.' : 'Could not load networks: ${_svc.lastError}'),
                for (final n in _svc.networks)
                  Card(
                    child: ListTile(
                      leading: Icon(n.loggedIn ? Icons.wifi : Icons.wifi_off, color: n.loggedIn ? AppColors.success : AppColors.textSecondary),
                      title: Text(n.siteName),
                      subtitle: Text('${n.siteCode} · ${n.loggedIn ? 'logged in' : 'not logged in'}'),
                      trailing: n.loggedIn
                          ? OutlinedButton(key: Key('logout-${n.siteCode}'), onPressed: _busy ? null : () => _run(() => _svc.logout(n.siteCode), ok: 'Logged out of ${n.siteName}'), child: const Text('Log out'))
                          : FilledButton(key: Key('login-${n.siteCode}'), onPressed: _busy ? null : () => _run(() => _svc.login(n.siteCode), ok: 'Logged in to ${n.siteName}'), child: const Text('Log in')),
                    ),
                  ),
                const SizedBox(height: AppSpacing.lg),
                Text('Log in with a network code', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _codeCtl,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Network code', hintText: 'HUAWEI-HG532D', border: OutlineInputBorder()),
                ),
                const SizedBox(height: AppSpacing.sm),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () {
                          final code = _codeCtl.text.trim();
                          if (code.isEmpty) return;
                          _run(() => _svc.login(code), ok: 'Logged in to $code');
                        },
                  child: const Text('Log in to network'),
                ),
                if (_message != null) Padding(padding: const EdgeInsets.only(top: AppSpacing.md), child: Text(_message!)),
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'While you are logged in to a network, alerts from the control room for that network turn this screen red until you acknowledge them. '
                  'Alerts need this phone to reach the server; ones raised while it is offline appear when it reconnects.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

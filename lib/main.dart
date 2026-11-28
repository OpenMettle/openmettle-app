import 'package:material_ui/material_ui.dart';

import 'api/browser_client.dart';
import 'api/client.dart';

void main() {
  runApp(OpenMettleApp(client: createBrowserClient()));
}

class OpenMettleApp extends StatelessWidget {
  const OpenMettleApp({super.key, required this.client});

  final SessionClient client;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenMettle',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF155A5B)),
      home: _SessionScreen(client: client),
    );
  }
}

enum _Phase {
  checking,
  loading,
  signedOut,
  signingIn,
  signInFailed,
  sessionUnavailable,
  capabilitiesUnavailable,
  signedIn,
  signingOut,
  signOutFailed,
  signedOutAfterLogout,
}

class _SessionScreen extends StatefulWidget {
  const _SessionScreen({required this.client});

  final SessionClient client;

  @override
  State<_SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<_SessionScreen> {
  final _primaryFocus = FocusNode();
  final _signOutFocus = FocusNode();
  late final AppLifecycleListener _lifecycle;
  _Phase _phase = _Phase.checking;
  int _request = 0;
  bool _recheckOnShow = false;
  List<Capability> _capabilities = const [];

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onHide: _hide, onShow: _resume);
    _recheckOnShow =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden;
    if (!_recheckOnShow) _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _primaryFocus.dispose();
    _signOutFocus.dispose();
    super.dispose();
  }

  void _hide() {
    switch (_phase) {
      case _Phase.checking:
      case _Phase.loading:
      case _Phase.capabilitiesUnavailable:
      case _Phase.signedIn:
      case _Phase.signingIn:
        // Discard an in-flight read or handoff before revalidating on return.
        _recheckOnShow = true;
        _request++;
        _show(_Phase.checking);
      default:
        break;
    }
  }

  void _resume() {
    if (!_recheckOnShow) return;
    _recheckOnShow = false;
    _load();
  }

  bool get _canSignOut =>
      _phase == _Phase.loading ||
      _phase == _Phase.sessionUnavailable ||
      _phase == _Phase.capabilitiesUnavailable ||
      _phase == _Phase.signedIn;

  void _refresh() {
    if (_phase == _Phase.signedIn ||
        _phase == _Phase.signingIn ||
        _phase == _Phase.sessionUnavailable ||
        _phase == _Phase.capabilitiesUnavailable) {
      _load();
    }
  }

  bool _isCurrent(int request) => mounted && request == _request;

  void _show(_Phase phase, {List<Capability> capabilities = const []}) {
    if (!mounted) return;
    setState(() {
      _phase = phase;
      _capabilities = capabilities;
    });
  }

  void _restoreFocus(bool hadFocus) {
    if (!hadFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _primaryFocus.context != null) {
        _primaryFocus.requestFocus();
      }
    });
  }

  Future<void> _load() async {
    final request = ++_request;
    final restoreFocus = _primaryFocus.hasFocus;
    _show(_Phase.checking);
    try {
      final signedIn = await widget.client.checkSession();
      if (!_isCurrent(request)) return;
      if (!signedIn) {
        _show(_Phase.signedOut);
        return;
      }
      _show(_Phase.loading);
      final capabilities = await widget.client.capabilities();
      if (_isCurrent(request)) {
        _show(_Phase.signedIn, capabilities: capabilities);
      }
    } on SessionExpired {
      if (_isCurrent(request)) _show(_Phase.signedOut);
    } catch (_) {
      if (_isCurrent(request)) {
        _show(
          _phase == _Phase.loading
              ? _Phase.capabilitiesUnavailable
              : _Phase.sessionUnavailable,
        );
      }
    } finally {
      if (_isCurrent(request)) _restoreFocus(restoreFocus);
    }
  }

  Future<void> _signIn() async {
    if (_phase != _Phase.signedOut &&
        _phase != _Phase.signedOutAfterLogout &&
        _phase != _Phase.signInFailed) {
      return;
    }
    final request = ++_request;
    final restoreFocus = _primaryFocus.hasFocus;
    _show(_Phase.signingIn);
    try {
      await widget.client.signIn();
    } catch (_) {
      if (_isCurrent(request)) {
        _show(_Phase.signInFailed);
        _restoreFocus(restoreFocus);
      }
    }
  }

  Future<void> _signOut() async {
    if (!_canSignOut && _phase != _Phase.signOutFailed) return;
    _request++;
    final restoreFocus = _primaryFocus.hasFocus || _signOutFocus.hasFocus;
    _show(_Phase.signingOut);
    try {
      await widget.client.signOut();
      _show(_Phase.signedOutAfterLogout);
    } on SessionExpired {
      _show(_Phase.signedOutAfterLogout);
    } catch (_) {
      _show(_Phase.signOutFailed);
    } finally {
      _restoreFocus(restoreFocus);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = switch (_phase) {
      _Phase.checking => 'Checking your session…',
      _Phase.loading => 'Loading capabilities…',
      _Phase.signedOut => 'Sign in to view your capabilities.',
      _Phase.signingIn => 'Opening sign-in…',
      _Phase.signInFailed => 'Could not open sign-in.',
      _Phase.sessionUnavailable => 'Could not check your session.',
      _Phase.capabilitiesUnavailable => 'Could not load capabilities.',
      _Phase.signedIn => 'Signed in',
      _Phase.signingOut => 'Signing out…',
      _Phase.signOutFailed => 'Could not confirm sign-out.',
      _Phase.signedOutAfterLogout => 'Signed out',
    };

    final action = switch (_phase) {
      _Phase.signedOut || _Phase.signedOutAfterLogout => ('Sign in', _signIn),
      _Phase.signInFailed => ('Retry sign-in', _signIn),
      _Phase.signingIn => ('Check session', _refresh),
      _Phase.sessionUnavailable ||
      _Phase.capabilitiesUnavailable => ('Retry', _refresh),
      _Phase.signedIn => ('Refresh', _refresh),
      _Phase.signOutFailed => ('Retry sign out', _signOut),
      _ => null,
    };

    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Semantics(
                  header: true,
                  child: Text('OpenMettle', style: textTheme.headlineMedium),
                ),
                const SizedBox(height: 12),
                Semantics(liveRegion: true, child: Text(status)),
                if (action != null || _canSignOut) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (action != null)
                        FilledButton(
                          focusNode: _primaryFocus,
                          onPressed: action.$2,
                          child: Text(action.$1),
                        ),
                      if (_canSignOut)
                        OutlinedButton(
                          focusNode: _signOutFocus,
                          onPressed: _signOut,
                          child: const Text('Sign out'),
                        ),
                    ],
                  ),
                ],
                if (_phase == _Phase.signedIn) ...[
                  const SizedBox(height: 32),
                  Semantics(
                    header: true,
                    child: Text('Capabilities', style: textTheme.titleLarge),
                  ),
                  const SizedBox(height: 8),
                  if (_capabilities.isEmpty)
                    const Text('No capabilities were reported.')
                  else
                    for (final capability in _capabilities)
                      _CapabilityCard(capability: capability),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.capability});

  final Capability capability;

  @override
  Widget build(BuildContext context) {
    final authorization = switch (capability.authorization) {
      true => 'Allowed',
      false => 'Denied',
      null => 'Unknown',
    };
    final readiness = switch (capability.readiness) {
      'ready' => 'Ready',
      'degraded' => 'Degraded',
      'unavailable' => 'Unavailable',
      'unknown' => 'Unknown',
      null => 'Not reported',
      _ => 'Unrecognized',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                capability.id,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text('Kind · ${capability.kind}'),
            const SizedBox(height: 8),
            Text(
              'Installation · ${capability.installed ? 'Installed' : 'Not installed'}',
            ),
            Text('Authorization · $authorization'),
            Text('Readiness · $readiness'),
          ],
        ),
      ),
    );
  }
}

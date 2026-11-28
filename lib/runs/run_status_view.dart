import 'package:material_ui/material_ui.dart';

import 'run_replay.dart';

/// Read-only status for a single run in the caller's current session.
class RunStatusView extends StatefulWidget {
  const RunStatusView({
    super.key,
    required this.source,
    required this.runId,
    this.resumeOnForeground = true,
    this.onAccessLost,
  });

  final RunReplaySource source;
  final String runId;

  /// Set to false when the parent revalidates the session and remounts this
  /// view after foregrounding. The view still pauses immediately on hide.
  final bool resumeOnForeground;
  final ValueChanged<RunReplayPhase>? onAccessLost;

  @override
  State<RunStatusView> createState() => _RunStatusViewState();
}

class _RunStatusViewState extends State<RunStatusView>
    with WidgetsBindingObserver {
  late RunReplayController _replay;
  late bool _visible;

  @override
  void initState() {
    super.initState();
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _visible = switch (binding.lifecycleState) {
      AppLifecycleState.hidden ||
      AppLifecycleState.paused ||
      AppLifecycleState.detached => false,
      _ => true,
    };
    _openRun();
  }

  void _openRun() {
    _replay = RunReplayController(source: widget.source, runId: widget.runId);
    _replay.addListener(_reportAccessLoss);
    if (_visible) _replay.start();
  }

  void _reportAccessLoss() {
    final phase = _replay.phase;
    if (phase == RunReplayPhase.unauthenticated ||
        phase == RunReplayPhase.inaccessible) {
      widget.onAccessLost?.call(phase);
    }
  }

  @override
  void didUpdateWidget(RunStatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source, widget.source) ||
        oldWidget.runId != widget.runId) {
      _replay.dispose();
      _openRun();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive) return;
    final visible = state == AppLifecycleState.resumed;
    if (visible == _visible) return;
    _visible = visible;
    if (!visible) {
      _replay.pause();
    } else if (!widget.resumeOnForeground) {
      return;
    } else if (_replay.phase == RunReplayPhase.idle) {
      _replay.start();
    } else {
      _replay.resume();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _replay.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _replay,
      builder: (context, _) {
        final status = switch (_replay.phase) {
          RunReplayPhase.idle ||
          RunReplayPhase.loading => 'Checking run status…',
          RunReplayPhase.connecting => 'Connecting to run updates…',
          RunReplayPhase.live => 'Following run updates',
          RunReplayPhase.reconnecting => 'Reconnecting…',
          RunReplayPhase.complete => 'Run ended',
          RunReplayPhase.paused => 'Run updates paused',
          RunReplayPhase.unauthenticated => 'Sign in again to view this run.',
          RunReplayPhase.inaccessible => 'This run is unavailable.',
          RunReplayPhase.unavailable => 'Could not update this run.',
        };
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Semantics(
              header: true,
              child: Text(
                'Run status',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
            const SizedBox(height: 12),
            Semantics(liveRegion: true, child: Text(status)),
            if (_replay.state case final state?) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(_label(state))),
            ],
            if (_replay.phase == RunReplayPhase.unavailable)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                  onPressed: _replay.retry,
                  child: const Text('Retry'),
                ),
              ),
          ],
        );
      },
    );
  }

  static String _label(String state) => switch (state) {
    'queued' => 'Queued',
    'running' => 'Running',
    'waiting' => 'Waiting',
    'cancelling' => 'Cancelling',
    'succeeded' => 'Succeeded',
    'failed' => 'Failed',
    'cancelled' => 'Cancelled',
    'interrupted' => 'Interrupted',
    _ => 'Unrecognized run state',
  };
}

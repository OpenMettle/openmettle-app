import 'dart:async';

import 'package:flutter/foundation.dart';

import 'run_wire.dart';

abstract interface class RunReplaySource {
  /// Report expected request failures with [RunReplayFailure].
  Future<RunSnapshot> snapshot(String runId);

  /// Replay after [cursor]. Cancelling the subscription must release the stream.
  /// A normal EOF may be a disconnect. Report HTTP 204 as
  /// [RunReplayFailure.terminalAtCursor] and core's 400 `invalid_cursor` as
  /// [RunReplayFailure.invalidCursor]. Report session and access refusals
  /// separately from temporary transport failures.
  Stream<RunReplayEvent> events(String runId, String cursor);
}

enum RunReplayFailure implements Exception {
  invalidCursor,
  unauthenticated,
  forbidden,
  notFound,
  unavailable,
  terminalAtCursor,
}

enum RunReplayPhase {
  idle,
  loading,
  connecting,
  live,
  reconnecting,
  paused,
  complete,
  unauthenticated,
  inaccessible,
  unavailable,
}

class RunReplayController extends ChangeNotifier {
  RunReplayController({required RunReplaySource source, required this.runId})
    : _source = source;

  static const _retryDelays = [
    Duration(milliseconds: 250),
    Duration(milliseconds: 500),
    Duration(seconds: 1),
  ];

  final RunReplaySource _source;
  final String runId;

  RunReplayPhase _phase = RunReplayPhase.idle;
  String? _state;
  BigInt? _sequence;
  String? _cursor;
  int _generation = 0;
  int _retries = 0;
  // A replacement snapshot can move backward. Receiving the same events
  // again must not grant an unlimited series of automatic cursor resets.
  BigInt? _lastProgress;
  bool _disposed = false;
  Timer? _timer;
  StreamSubscription<RunReplayEvent>? _subscription;
  Future<void>? _cancellation;

  RunReplayPhase get phase => _phase;
  String? get state => _state;
  BigInt? get sequence => _sequence;
  bool get isTerminal => _phase == RunReplayPhase.complete;

  void start() {
    if (!_disposed && _phase == RunReplayPhase.idle) {
      _refresh();
    }
  }

  void pause() {
    if (_disposed || _phase == RunReplayPhase.paused) return;
    _stop();
    _clearState();
    _publish(RunReplayPhase.paused);
  }

  void resume() {
    if (!_disposed && _phase == RunReplayPhase.paused) {
      _refresh();
    }
  }

  void retry() {
    if (_disposed) return;
    switch (_phase) {
      case RunReplayPhase.unavailable:
      case RunReplayPhase.unauthenticated:
      case RunReplayPhase.inaccessible:
        _refresh();
      default:
        break;
    }
  }

  void _refresh() {
    _stop();
    _clearState();
    _retries = 0;
    unawaited(_loadSnapshot(_generation));
  }

  bool _current(int generation) => !_disposed && _generation == generation;

  Future<void> _loadSnapshot(
    int generation, {
    bool terminalRequired = false,
  }) async {
    if (!_current(generation)) return;
    _publish(RunReplayPhase.loading);
    if (!_current(generation)) return;

    final RunSnapshot snapshot;
    try {
      // A source can refuse immediately while its view is mounting. Deliver
      // access-loss notifications after the current build in either case.
      snapshot = await Future.sync(() => _source.snapshot(runId));
    } catch (error) {
      if (_current(generation)) {
        _handleFailure(error, terminalRequired: terminalRequired);
      }
      return;
    }
    if (!_current(generation)) return;

    if (snapshot.runId != runId || (terminalRequired && !snapshot.isTerminal)) {
      _clearState();
      _publish(RunReplayPhase.unavailable);
      return;
    }

    _state = snapshot.state;
    _sequence = snapshot.sequence;
    _cursor = snapshot.cursor;
    _lastProgress ??= snapshot.sequence;
    if (snapshot.isTerminal) {
      _publish(RunReplayPhase.complete);
    } else {
      unawaited(_connect(generation));
    }
  }

  Future<void> _connect(int generation) async {
    if (!_current(generation)) return;
    _publish(RunReplayPhase.connecting);
    if (!_current(generation)) return;
    final cancellation = _cancellation;
    if (cancellation != null) {
      try {
        await cancellation.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        if (_current(generation)) {
          _clearState();
          _publish(RunReplayPhase.unavailable);
        }
        return;
      }
      if (!_current(generation)) return;
      _cancellation = null;
    }

    try {
      final subscription = _source
          .events(runId, _cursor!)
          .listen(
            (event) => _apply(generation, event),
            onError: (Object error) {
              if (_current(generation)) _handleFailure(error);
            },
            onDone: () {
              if (_current(generation)) {
                _subscription = null;
                _handleFailure(RunReplayFailure.unavailable);
              }
            },
          );
      if (_current(generation)) {
        _subscription = subscription;
      } else {
        unawaited(_cancel(subscription));
      }
    } catch (error) {
      if (_current(generation)) _handleFailure(error);
    }
  }

  void _apply(int generation, RunReplayEvent event) {
    if (!_current(generation)) return;
    if (event.runId != runId) {
      _handleFailure(const FormatException('Invalid run response'));
      return;
    }
    if (event.sequence <= _sequence!) return;

    _sequence = event.sequence;
    _cursor = event.cursor;
    if (event.sequence > _lastProgress!) {
      _lastProgress = event.sequence;
      _retries = 0;
    }
    _state = event.state ?? _state;
    if (event.isTerminal) {
      _stop();
      _publish(RunReplayPhase.complete);
    } else {
      _publish(RunReplayPhase.live);
    }
  }

  void _handleFailure(Object error, {bool terminalRequired = false}) {
    _stop();
    final generation = _generation;
    switch (error) {
      case RunReplayFailure.unauthenticated:
        _clearState();
        _publish(RunReplayPhase.unauthenticated);
      case RunReplayFailure.forbidden:
      case RunReplayFailure.notFound:
        _clearState();
        _publish(RunReplayPhase.inaccessible);
      case RunReplayFailure.terminalAtCursor when !terminalRequired:
        _clearState();
        unawaited(_loadSnapshot(generation, terminalRequired: true));
      case RunReplayFailure.invalidCursor when !terminalRequired:
      case RunReplayFailure.unavailable:
        if (error == RunReplayFailure.invalidCursor) {
          _clearState(keepRetryProgress: true);
        }
        if (_retries == _retryDelays.length) {
          _clearState();
          _publish(RunReplayPhase.unavailable);
          return;
        }
        _timer = Timer(_retryDelays[_retries++], () {
          _timer = null;
          if (!_current(generation)) return;
          if (_cursor == null) {
            unawaited(
              _loadSnapshot(generation, terminalRequired: terminalRequired),
            );
          } else {
            unawaited(_connect(generation));
          }
        });
        _publish(RunReplayPhase.reconnecting);
      default:
        _clearState();
        _publish(RunReplayPhase.unavailable);
    }
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) _cancellation = _cancel(subscription);
  }

  Future<void> _cancel(StreamSubscription<RunReplayEvent> subscription) async {
    try {
      await subscription.cancel();
    } catch (_) {
      // Cleanup failures cannot modify the current replay.
    }
  }

  void _clearState({bool keepRetryProgress = false}) {
    _state = null;
    _sequence = null;
    _cursor = null;
    if (!keepRetryProgress) _lastProgress = null;
  }

  void _publish(RunReplayPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    _clearState();
    super.dispose();
  }
}

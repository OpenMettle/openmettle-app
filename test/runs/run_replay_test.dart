import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/runs/run_replay.dart';
import 'package:openmettle_app/runs/run_wire.dart';

const _runId = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _conversationId = '0f0e0d0c-0b0a-4908-8706-050403020101';
const _time = '2026-11-20T09:00:01.000000Z';

RunSnapshot _snapshot({
  String cursor = 'snapshot_cursor',
  String sequence = '1',
  String state = 'queued',
}) => RunSnapshot.parse(
  jsonEncode({
    'run_id': _runId,
    'conversation_id': _conversationId,
    'last_sequence': sequence,
    'resume_cursor': cursor,
    'state': state,
    'created_at': _time,
    'terminal': null,
  }),
  runId: _runId,
);

Future<RunReplayEvent> _event(
  WidgetTester tester,
  String sequence,
  String type,
  String cursor, {
  int version = 1,
}) async {
  final data = jsonEncode({
    'run_id': _runId,
    'sequence': sequence,
    'type': type,
    'type_version': version,
    'occurred_at': _time,
    'data': <String, Object?>{},
  });
  return (await tester.runAsync(
    () => decodeRunEvents(
      Stream.value(utf8.encode('id: $cursor\ndata: $data\n\n')),
      runId: _runId,
    ).single,
  ))!;
}

class _ReplaySource implements RunReplaySource {
  final snapshots = <Completer<RunSnapshot>>[];
  final cursors = <String>[];
  final streams = <StreamController<RunReplayEvent>>[];
  final cancelled = <int>[];
  Completer<void>? cancellation;

  @override
  Future<RunSnapshot> snapshot(String runId) {
    expectSync(runId, _runId);
    final result = Completer<RunSnapshot>();
    snapshots.add(result);
    return result.future;
  }

  @override
  Stream<RunReplayEvent> events(String runId, String cursor) {
    expectSync(runId, _runId);
    final index = streams.length;
    final stream = StreamController<RunReplayEvent>(
      onCancel: () async {
        cancelled.add(index);
        await cancellation?.future;
      },
    );
    cursors.add(cursor);
    streams.add(stream);
    return stream.stream;
  }
}

void main() {
  late _ReplaySource source;
  late RunReplayController replay;

  setUp(() {
    source = _ReplaySource();
    replay = RunReplayController(source: source, runId: _runId);
  });

  tearDown(() {
    replay.dispose();
  });

  testWidgets('replays only after the last applied event', (tester) async {
    replay.start();
    expect(replay.phase, RunReplayPhase.loading);
    expect(source.cursors, isEmpty);
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    expect(source.cursors, ['snapshot_cursor']);

    final started = await _event(tester, '4', 'run.started', 'started_cursor');
    final unknownType = await _event(tester, '5', 'run.note', 'unknown_cursor');
    final unseen = await _event(
      tester,
      '9007199254740993',
      'run.succeeded',
      'future_cursor',
      version: 2,
    );
    source.streams.single
      ..add(started)
      ..add(unknownType)
      ..add(unseen)
      ..add(started);
    await tester.pump();
    expect(replay.state, 'running');
    expect(replay.sequence, BigInt.parse('9007199254740993'));
    expect(replay.phase, RunReplayPhase.live);

    unawaited(source.streams.single.close());
    await tester.pump();
    expect(replay.phase, RunReplayPhase.reconnecting);
    await tester.pump(const Duration(milliseconds: 249));
    expect(source.cursors, ['snapshot_cursor']);
    await tester.pump(const Duration(milliseconds: 1));
    expect(source.cursors, ['snapshot_cursor', 'future_cursor']);

    source.streams.last.add(
      await _event(
        tester,
        '9007199254740994',
        'run.succeeded',
        'terminal_cursor',
      ),
    );
    await tester.pump();
    expect(replay.phase, RunReplayPhase.complete);
    expect(replay.state, 'succeeded');
    expect(source.cancelled, [0, 1]);
    await tester.pump(const Duration(seconds: 2));
    expect(source.streams, hasLength(2));
  });

  testWidgets('invalid cursors discard state and load a fresh snapshot', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot(sequence: '8'));
    await tester.pump();
    source.streams.single.addError(RunReplayFailure.invalidCursor);
    await tester.pump();
    expect(replay.state, isNull);
    expect(replay.sequence, isNull);
    expect(source.cancelled, [0]);
    await tester.pump(const Duration(milliseconds: 250));
    source.snapshots.last.complete(
      _snapshot(cursor: 'restored_cursor', sequence: '2', state: 'running'),
    );
    await tester.pump();
    expect(source.cursors, ['snapshot_cursor', 'restored_cursor']);
    expect(replay.sequence, BigInt.two);
  });

  testWidgets('repeated invalid cursors exhaust the same retry budget', (
    tester,
  ) async {
    replay.start();
    final repeatedEvent = await _event(tester, '2', 'run.started', 'once');
    for (final (index, milliseconds) in [250, 500, 1000].indexed) {
      source.snapshots.last.complete(_snapshot(cursor: 'snapshot_$index'));
      await tester.pump();
      source.streams.last.add(repeatedEvent);
      source.streams.last.addError(RunReplayFailure.invalidCursor);
      await tester.pump();
      expect(replay.phase, RunReplayPhase.reconnecting);
      expect(replay.state, isNull);
      await tester.pump(Duration(milliseconds: milliseconds));
    }
    source.snapshots.last.complete(_snapshot());
    await tester.pump();
    source.streams.last.addError(RunReplayFailure.invalidCursor);
    await tester.pump();
    expect(replay.phase, RunReplayPhase.unavailable);
    await tester.pump(const Duration(seconds: 2));
    expect(source.snapshots, hasLength(4));
    expect(source.streams, hasLength(4));
  });

  testWidgets('an already terminal snapshot never opens replay', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot(state: 'interrupted'));
    await tester.pump();
    expect(replay.phase, RunReplayPhase.complete);
    expect(replay.state, 'interrupted');
    expect(source.cursors, isEmpty);
  });

  testWidgets('204 refreshes terminal state without reopening replay', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    source.streams.single.addError(RunReplayFailure.terminalAtCursor);
    await tester.pump();
    expect(source.cancelled, [0]);
    expect(replay.phase, RunReplayPhase.loading);
    source.snapshots.last.complete(_snapshot(state: 'cancelled'));
    await tester.pump();
    expect(replay.state, 'cancelled');
    expect(replay.isTerminal, isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(source.streams, hasLength(1));
  });

  testWidgets('retries a temporary snapshot failure after 204', (tester) async {
    replay.start();
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    source.streams.single.addError(RunReplayFailure.terminalAtCursor);
    await tester.pump();
    source.snapshots.last.completeError(RunReplayFailure.unavailable);
    await tester.pump();
    expect(replay.state, isNull);
    expect(replay.phase, RunReplayPhase.reconnecting);
    await tester.pump(const Duration(milliseconds: 250));
    source.snapshots.last.complete(
      _snapshot(state: 'cancelled', sequence: '8'),
    );
    await tester.pump();
    expect(replay.phase, RunReplayPhase.complete);
    expect(replay.state, 'cancelled');
    expect(source.streams, hasLength(1));
  });

  testWidgets('204 never promotes a stale nonterminal state to complete', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot(state: 'running'));
    await tester.pump();
    source.streams.single.addError(RunReplayFailure.terminalAtCursor);
    await tester.pump();
    expect(replay.state, isNull);
    source.snapshots.last.complete(_snapshot(state: 'running'));
    await tester.pump();
    expect(replay.phase, RunReplayPhase.unavailable);
    expect(replay.state, isNull);
    expect(replay.isTerminal, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(source.snapshots, hasLength(2));
    expect(source.streams, hasLength(1));
  });

  testWidgets('malformed stream stops without retrying or retaining state', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    source.streams.single.addError(const FormatException('invalid event'));
    await tester.pump();
    expect(replay.phase, RunReplayPhase.unavailable);
    expect(replay.state, isNull);
    expect(replay.sequence, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(source.streams, hasLength(1));
  });

  for (final (failure, phase) in [
    (RunReplayFailure.unauthenticated, RunReplayPhase.unauthenticated),
    (RunReplayFailure.forbidden, RunReplayPhase.inaccessible),
    (RunReplayFailure.notFound, RunReplayPhase.inaccessible),
  ]) {
    testWidgets('$failure clears run data and stops replay', (tester) async {
      replay.start();
      source.snapshots.single.complete(_snapshot());
      await tester.pump();
      source.streams.single.addError(failure);
      await tester.pump();
      expect(replay.phase, phase);
      expect(replay.state, isNull);
      expect(replay.sequence, isNull);
      expect(source.cancelled, [0]);
      await tester.pump(const Duration(seconds: 2));
      expect(source.cursors, ['snapshot_cursor']);

      replay.retry();
      expect(source.snapshots, hasLength(2));
    });
  }

  testWidgets(
    'new progress refills the budget, duplicate-only retries exhaust it',
    (tester) async {
      replay.start();
      source.snapshots.single.complete(_snapshot());
      await tester.pump();
      for (var index = 0; index < 5; index++) {
        source.streams.last.add(
          await _event(tester, '${index + 2}', 'run.started', 'cursor_$index'),
        );
        unawaited(source.streams.last.close());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(source.cursors.last, 'cursor_$index');
      }
      final duplicate = await _event(
        tester,
        '6',
        'run.started',
        'duplicate_cursor',
      );
      for (final delay in [500, 1000]) {
        source.streams.last.add(duplicate);
        unawaited(source.streams.last.close());
        await tester.pump();
        await tester.pump(Duration(milliseconds: delay));
      }
      source.streams.last.add(duplicate);
      unawaited(source.streams.last.close());
      await tester.pump();
      expect(replay.phase, RunReplayPhase.unavailable);
      await tester.pump(const Duration(seconds: 2));
      expect(source.cursors, [
        'snapshot_cursor',
        'cursor_0',
        'cursor_1',
        'cursor_2',
        'cursor_3',
        'cursor_4',
        'cursor_4',
        'cursor_4',
      ]);
      replay.retry();
      expect(replay.phase, RunReplayPhase.loading);
      expect(replay.state, isNull);
      source.snapshots.last.complete(_snapshot(cursor: 'reauthorized_cursor'));
      await tester.pump();
      expect(source.cursors.last, 'reauthorized_cursor');
    },
  );

  testWidgets('pause and resume reject stale snapshots and cancel replay', (
    tester,
  ) async {
    replay.start();
    replay.pause();
    replay.resume();
    source.snapshots.last.complete(_snapshot(cursor: 'current_cursor'));
    await tester.pump();
    source.snapshots.first.completeError(RunReplayFailure.unauthenticated);
    await tester.pump();
    expect(source.cursors, ['current_cursor']);
    expect(replay.state, 'queued');

    source.streams.single.add(
      await _event(tester, '2', 'run.started', 'unapplied_cursor'),
    );
    replay.pause();
    await tester.pump();
    expect(replay.phase, RunReplayPhase.paused);
    expect(replay.state, isNull);
    expect(replay.sequence, isNull);
    expect(source.cancelled, [0]);

    replay.resume();
    source.snapshots.last.complete(_snapshot(cursor: 'resumed_cursor'));
    await tester.pump();
    expect(source.cursors, ['current_cursor', 'resumed_cursor']);
  });

  testWidgets('pause cancels pending reconnect and resumes from a snapshot', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    source.streams.single.addError(RunReplayFailure.unavailable);
    await tester.pump();
    replay.pause();
    await tester.pump(const Duration(seconds: 2));
    expect(source.streams, hasLength(1));
    replay.resume();
    expect(source.snapshots, hasLength(2));
  });

  testWidgets('resume waits for cancellation and fences a superseded stream', (
    tester,
  ) async {
    replay.start();
    source.snapshots.single.complete(_snapshot());
    await tester.pump();
    final cancellation = source.cancellation = Completer<void>();
    replay.pause();
    replay.resume();
    source.snapshots.last.complete(_snapshot(cursor: 'superseded_cursor'));
    await tester.pump();
    expect(source.cursors, ['snapshot_cursor']);

    replay.pause();
    replay.resume();
    source.snapshots.last.complete(_snapshot(cursor: 'current_cursor'));
    cancellation.complete();
    await tester.pump();
    expect(source.cursors, ['snapshot_cursor', 'current_cursor']);
  });

  testWidgets(
    'a stalled cancellation exposes retry without overlapping reads',
    (tester) async {
      replay.start();
      source.snapshots.single.complete(_snapshot());
      await tester.pump();
      final release = source.cancellation = Completer<void>();
      replay.pause();
      replay.resume();
      source.snapshots.last.complete(_snapshot());
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(replay.phase, RunReplayPhase.unavailable);
      expect(replay.state, isNull);
      expect(source.streams, hasLength(1));
      release.complete();
      replay.retry();
      source.snapshots.last.complete(_snapshot());
      await tester.pump();
      expect(source.streams, hasLength(2));
    },
  );

  testWidgets('dispose fences pending snapshots and cancels active streams', (
    tester,
  ) async {
    final pendingSource = _ReplaySource();
    final pending = RunReplayController(source: pendingSource, runId: _runId);
    pending.start();
    pending.dispose();
    pendingSource.snapshots.single.complete(_snapshot());
    await tester.pump();
    expect(pendingSource.cursors, isEmpty);

    final liveSource = _ReplaySource();
    final live = RunReplayController(source: liveSource, runId: _runId);
    live.start();
    liveSource.snapshots.single.complete(_snapshot());
    await tester.pump();
    live.dispose();
    expect(liveSource.cancelled, [0]);
    await tester.pump(const Duration(seconds: 2));
    expect(liveSource.cursors, ['snapshot_cursor']);
  });
}

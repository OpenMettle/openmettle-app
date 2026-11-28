import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:openmettle_app/runs/run_replay.dart';
import 'package:openmettle_app/runs/run_status_view.dart';
import 'package:openmettle_app/runs/run_wire.dart';

import '../qualification/run_reconnect_app.dart';

class _Fixture extends InterruptedRunFixture {
  final cursors = <String>[];
  int snapshots = 0;
  RunReplayFailure? failure;
  Completer<RunSnapshot>? pending;

  @override
  Future<RunSnapshot> snapshot(String runId) async {
    snapshots++;
    if (failure case final failure?) throw failure;
    return pending?.future ?? super.snapshot(runId);
  }

  @override
  Stream<RunReplayEvent> events(String runId, String cursor) {
    cursors.add(cursor);
    return super.events(runId, cursor);
  }
}

Widget _app(RunReplaySource source) => MaterialApp(
  home: Scaffold(
    body: RunStatusView(source: source, runId: fixtureRunId),
  ),
);

class _QuietFixture extends InterruptedRunFixture {
  final streams = <StreamController<List<int>>>[];
  int released = 0;

  @override
  Stream<RunReplayEvent> events(String runId, String cursor) {
    final bytes = StreamController<List<int>>(
      onCancel: () async {
        released++;
      },
    );
    streams.add(bytes);
    return decodeRunEvents(bytes.stream, runId: runId);
  }
}

void main() {
  testWidgets(
    'a replayed terminal and a broken tail cannot replace the fresh outcome',
    (tester) async {
      final source = _QuietFixture();
      await tester.pumpWidget(_app(source));
      await tester.pump();
      String terminal(String sequence, String type) {
        final event = jsonEncode({
          'run_id': fixtureRunId,
          'sequence': sequence,
          'type': type,
          'type_version': 1,
          'occurred_at': '2026-11-20T09:00:02.000000Z',
          'data': type == 'run.failed'
              ? {'reason': 'queue_expired'}
              : <String, String>{},
        });
        return 'id: cursor_$sequence\ndata: $event\n\n';
      }

      // Sequence 1 was already applied in the snapshot. All bytes, including
      // the malformed tail after sequence 2, arrive in the same input chunk.
      source.streams.single.add(
        utf8.encode(
          '${terminal('1', 'run.failed')}${terminal('2', 'run.succeeded')}data: {}\n\n',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Succeeded'), findsOneWidget);
      expect(find.text('Run ended'), findsOneWidget);
      expect(find.text('Failed'), findsNothing);
      expect(source.released, 1);
      unawaited(source.streams.single.close());
    },
  );

  testWidgets('backgrounding releases a quiet connection before resuming', (
    tester,
  ) async {
    final source = _QuietFixture();
    await tester.pumpWidget(_app(source));
    await tester.pump();
    expect(source.streams.single.hasListener, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(source.streams.single.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(source.streams, hasLength(2));
    expect(source.streams.last.hasListener, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(source.released, 2);
    for (final stream in source.streams) {
      unawaited(stream.close());
    }
  });

  testWidgets(
    'reconnects after a partial event and renders the confirmed outcome',
    (tester) async {
      final source = _Fixture();
      await tester.pumpWidget(_app(source));
      await tester.pump();
      expect(find.text('Queued'), findsOneWidget);
      expect(source.cursors, [queuedCursor]);

      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Running'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Reconnecting…'), findsOneWidget);
      expect(find.text('Cancelled'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      expect(source.cursors, [queuedCursor, runningCursor]);
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Run ended'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(source.snapshots, 1);
      expect(source.cursors, hasLength(2));

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      source.pending = Completer<RunSnapshot>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text('Checking run status…'), findsOneWidget);
      expect(find.text('Cancelled'), findsNothing);
      source.pending!.completeError(RunReplayFailure.notFound);
      await tester.pumpAndSettle();
      expect(find.text('This run is unavailable.'), findsOneWidget);
      expect(find.text('Cancelled'), findsNothing);
      expect(source.snapshots, 2);
    },
  );

  testWidgets('Retry rechecks access after automatic recovery stops', (
    tester,
  ) async {
    final source = _Fixture()..failure = RunReplayFailure.unavailable;
    await tester.pumpWidget(_app(source));
    await tester.pump();
    for (var attempt = 0; attempt < 3; attempt++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.pumpAndSettle();
    expect(find.text('Could not update this run.'), findsOneWidget);
    expect(source.snapshots, 4);
    source.failure = RunReplayFailure.notFound;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('This run is unavailable.'), findsOneWidget);
    expect(source.snapshots, 5);
    expect(source.cursors, isEmpty);
  });

  testWidgets('ignores the former session while a new source is active', (
    tester,
  ) async {
    final lateSnapshot = Completer<RunSnapshot>();
    final former = _Fixture()..pending = lateSnapshot;
    final current = _Fixture()..failure = RunReplayFailure.unauthenticated;
    await tester.pumpWidget(_app(former));
    await tester.pumpWidget(_app(current));
    await tester.pump();
    lateSnapshot.complete(await InterruptedRunFixture().snapshot(fixtureRunId));
    await tester.pump();
    expect(find.text('Sign in again to view this run.'), findsOneWidget);
    expect(find.text('Queued'), findsNothing);
    expect(former.cursors, isEmpty);
    expect(current.cursors, isEmpty);
  });
}

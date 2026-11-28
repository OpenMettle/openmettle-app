import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:openmettle_app/runs/run_replay.dart';
import 'package:openmettle_app/runs/run_status_view.dart';
import 'package:openmettle_app/runs/run_wire.dart';

// Standalone, offline Flutter target for the interrupted-event journey.
void main() {
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Run reconnect fixture')),
        body: RunStatusView(
          source: InterruptedRunFixture(),
          runId: fixtureRunId,
        ),
      ),
    ),
  );
}

const fixtureRunId = '0f0e0d0c-0b0a-4908-8706-050403020100';
const queuedCursor = 'cXVldWVk';
const runningCursor = 'cnVubmluZw';
const _cancelledCursor = 'Y2FuY2VsbGVk';
const _tick = Duration(milliseconds: 800);

class InterruptedRunFixture implements RunReplaySource {
  int _sequence = 1;

  @override
  Future<RunSnapshot> snapshot(String runId) async {
    if (runId != fixtureRunId) throw RunReplayFailure.notFound;
    return RunSnapshot.parse(
      jsonEncode({
        'run_id': runId,
        'conversation_id': '0f0e0d0c-0b0a-4908-8706-050403020101',
        'state': switch (_sequence) {
          1 => 'queued',
          2 => 'running',
          _ => 'cancelled',
        },
        'created_at': '2026-11-20T09:00:01.000000Z',
        'last_sequence': _sequence.toString(),
        'resume_cursor': switch (_sequence) {
          1 => queuedCursor,
          2 => runningCursor,
          _ => _cancelledCursor,
        },
        'terminal': _sequence == 3 ? _event(3) : null,
      }),
      runId: runId,
    );
  }

  @override
  Stream<RunReplayEvent> events(String runId, String cursor) =>
      decodeRunEvents(_events(runId, cursor), runId: runId);

  Stream<List<int>> _events(String runId, String cursor) async* {
    if (runId != fixtureRunId) throw RunReplayFailure.notFound;
    final terminal = utf8.encode(
      'id: $_cancelledCursor\ndata: ${jsonEncode(_event(3))}\n\n',
    );
    switch (cursor) {
      case queuedCursor:
        await Future<void>.delayed(_tick);
        if (_sequence == 1) _sequence = 2;
        yield utf8.encode(
          'id: $runningCursor\ndata: ${jsonEncode(_event(2))}\n\n',
        );
        await Future<void>.delayed(_tick);
        _sequence = 3;
        // The connection ends during the terminal event's data line.
        yield terminal.sublist(0, terminal.length ~/ 2);
      case runningCursor:
        await Future<void>.delayed(_tick);
        _sequence = 3;
        yield terminal;
      default:
        throw RunReplayFailure.invalidCursor;
    }
  }

  Map<String, Object?> _event(int sequence) => {
    'run_id': fixtureRunId,
    'sequence': sequence.toString(),
    'type': sequence == 2 ? 'run.started' : 'run.cancelled',
    'type_version': 1,
    'occurred_at': '2026-11-20T09:00:0${sequence}.000000Z',
    'data': sequence == 2 ? <String, String>{} : {'reason': 'requested'},
  };
}

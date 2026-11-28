import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/runs/run_wire.dart';

/// Core run fixtures copied unmodified from the commit in MANIFEST.
final _root = Directory('test/fixtures/run_replay');

const _runId = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _message = 'Invalid run response';
const _maxSequence = '9223372036854775807';

List<String> _manifest() =>
    File('${_root.path}/MANIFEST')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();

Map<String, Object?> _fixture(String path) =>
    jsonDecode(File('${_root.path}/$path').readAsStringSync())
        as Map<String, Object?>;

Map<String, Object?> _instance(String path) =>
    _fixture(path)['instance']! as Map<String, Object?>;

/// The fixed, content-free failure.
final Matcher _invalid = isA<FormatException>()
    .having((e) => e.message, 'message', _message)
    .having((e) => e.source, 'source', isNull)
    .having((e) => e.offset, 'offset', isNull);

/// Serializes a parsed `RunEventItem` as one SSE record. Members other than
/// `id`, `data`, `event` and `retry` become unknown SSE fields.
String _record(Map<String, Object?> item, {String eol = '\n'}) {
  final lines = <String>[];
  item.forEach((key, value) {
    if (key == 'data') {
      lines.addAll((value! as String).split('\n').map((l) => 'data: $l'));
    } else {
      lines.add('$key: ${value is String ? value : jsonEncode(value)}');
    }
  });
  return '${lines.join(eol)}$eol$eol';
}

Stream<List<int>> _bytes(List<List<int>> chunks) => Stream.fromIterable(chunks);

Future<List<RunReplayEvent>> _decode(String body, {String runId = _runId}) =>
    decodeRunEvents(_bytes([utf8.encode(body)]), runId: runId).toList();

Future<List<RunReplayEvent>> _decodeChunks(List<List<int>> chunks) =>
    decodeRunEvents(_bytes(chunks), runId: _runId).toList();

String _event({
  String runId = _runId,
  Object? sequence = '1',
  String type = 'run.created',
  Object? typeVersion = 1,
  Object? data = const <String, Object?>{},
}) => jsonEncode({
  'run_id': runId,
  'sequence': sequence,
  'type': type,
  'type_version': typeVersion,
  'occurred_at': '2026-11-20T09:00:01.000000Z',
  'data': data,
});

String _frame(String data, {String id = 'Y3Vyc29y'}) =>
    'id: $id\ndata: $data\n\n';

/// A live snapshot derived from the pinned valid example.
Map<String, Object?> _liveSnapshot() => {
  ..._instance('valid/RunSnapshot.json'),
  'state': 'running',
  'last_sequence': '2',
  'terminal': null,
};

RunSnapshot _parse(Map<String, Object?> body, {String runId = _runId}) =>
    RunSnapshot.parse(jsonEncode(body), runId: runId);

void main() {
  final manifest = _manifest();
  final paths = manifest.skip(1).toList();

  test('fixture copies match the manifest of the pinned core commit', () {
    expect(manifest.first, '6e82f3b6edcdb3f3270170195623115462316948');
    final present =
        _root
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => f.path.substring(_root.path.length + 1))
            .where((p) => p.endsWith('.json'))
            .toList()
          ..sort();
    expect(present, paths);
    for (final path in paths) {
      final fixture = _fixture(path);
      expect(fixture['generated_by'], 'scripts/contract_fixtures.py');
      expect('${fixture['class']}/${fixture['fixture']}.json', path);
    }
  });

  group('pinned fixtures', () {
    for (final path in paths) {
      final fixture = _fixture(path);
      final valid =
          (fixture['expect']! as Map<String, Object?>)['valid'] == true;
      final instance = fixture['instance']! as Map<String, Object?>;
      final description = '$path is ${valid ? 'accepted' : 'refused'}';
      switch (fixture['schema']) {
        case '#/components/schemas/Run':
          test(description, () {
            RunSnapshot parse() => _parse(instance);
            if (valid) {
              final snapshot = parse();
              expect(snapshot.runId, _runId);
              expect(snapshot.state, instance['state']);
              expect(snapshot.cursor, instance['resume_cursor']);
              expect(snapshot.sequence, BigInt.from(3));
              expect(snapshot.isTerminal, isTrue);
            } else {
              expect(parse, throwsA(_invalid));
            }
          });
        case '#/components/schemas/RunEventItem':
          test(description, () async {
            final call = _decode(_record(instance));
            if (!valid) {
              await expectLater(call, throwsA(_invalid));
              return;
            }
            final events = await call;
            expect(events, hasLength(1));
            final event = events.single;
            final data = jsonDecode(instance['data']! as String) as Map;
            expect(event.runId, _runId);
            expect(event.cursor, instance['id']);
            expect(event.type, data['type']);
            expect(event.typeVersion, 1);
            expect(event.sequence, BigInt.parse(data['sequence'] as String));
          });
        default:
          fail('$path: unexpected schema ${fixture['schema']}');
      }
    }
  });

  group('event projection', () {
    final cases = {
      'valid/RunEventCreated.json': ('queued', false),
      'valid/RunEventStarted.json': ('running', false),
      'valid/RunEventWaiting.json': ('waiting', false),
      'valid/RunEventResumed.json': ('running', false),
      'valid/RunEventApprovalRequested.json': (null, false),
      'valid/RunEventApprovalDecided.json': (null, false),
      'valid/RunEventCancelled.json': ('cancelled', true),
      'valid/RunEventFailed.json': ('failed', true),
      'valid/RunEventApprovalExpired.json': ('failed', true),
      'valid/RunEventInvalidWait.json': ('failed', true),
      'compat/RunEventCancelled--unknown-reason.json': ('cancelled', true),
      'compat/RunEventFailed--unknown-reason.json': ('failed', true),
      'valid/RunEventItemNote.json': (null, false),
      'compat/RunEventItemNote--unrecognized-type.json': (null, false),
    };
    cases.forEach((path, expected) {
      test('$path maps to ${expected.$1}', () async {
        final event = (await _decode(_record(_instance(path)))).single;
        expect(event.state, expected.$1);
        expect(event.isTerminal, expected.$2);
      });
    });

    test('succeeded and interrupted are terminal states', () async {
      for (final (type, state) in [
        ('run.succeeded', 'succeeded'),
        ('run.interrupted', 'interrupted'),
      ]) {
        final event = (await _decode(_frame(_event(type: type)))).single;
        expect(event.state, state);
        expect(event.isTerminal, isTrue);
      }
    });

    test('an unknown version of a known type is not a transition', () async {
      final event = (await _decode(
        _frame(
          _event(type: 'run.cancelled', typeVersion: 2, data: {'future': true}),
        ),
      )).single;
      expect(event.typeVersion, 2);
      expect(event.state, isNull);
      expect(event.isTerminal, isFalse);
    });

    test('the largest signed 64-bit sequence is exact', () async {
      final event = (await _decode(
        _record(
          _instance('valid/RunEventItemNote--sequence-signed-64-maximum.json'),
        ),
      )).single;
      expect(event.sequence, BigInt.parse(_maxSequence));
      expect(event.sequence.toString(), _maxSequence);
    });

    test('type_version accepts integral JSON numbers in range', () async {
      for (final version in [1.0, 2147483647]) {
        final event = (await _decode(_frame(_event(typeVersion: version))))
            .single;
        expect(event.typeVersion, version.toInt());
      }
    });

    for (final (name, data) in [
      ('sequence with a leading zero', _event(sequence: '01')),
      ('sequence above signed 64-bit', _event(sequence: '9223372036854775808')),
      ('sequence of twenty digits', _event(sequence: '10000000000000000000')),
      ('negative sequence', _event(sequence: '-1')),
      ('missing sequence', _event(sequence: null)),
      ('type_version zero', _event(typeVersion: 0)),
      ('type_version above int32', _event(typeVersion: 2147483648)),
      ('fractional type_version', _event(typeVersion: 1.5)),
      ('string type_version', _event(typeVersion: '1')),
      ('uppercase type', _event(type: 'Run.created')),
      ('another run', _event(runId: '0f0e0d0c-0b0a-4908-8706-050403020101')),
      ('data not an object', _event(data: <Object?>[])),
      ('created with data', _event(data: {'x': 1})),
      (
        'cancelled with an invalid reason',
        _event(type: 'run.cancelled', data: {'reason': 'Bad'}),
      ),
      (
        'waiting for something else',
        _event(type: 'run.waiting', data: {'reason': 'other'}),
      ),
      ('JSON array', '[]'),
      ('bad timestamp', _event().replaceFirst('.000000Z', 'Z')),
    ]) {
      test('refuses $name', () async {
        await expectLater(_decode(_frame(data)), throwsA(_invalid));
      });
    }
  });

  group('snapshot', () {
    test('a live snapshot is not terminal', () {
      final snapshot = _parse(_liveSnapshot());
      expect(snapshot.state, 'running');
      expect(snapshot.sequence, BigInt.two);
      expect(snapshot.isTerminal, isFalse);
    });

    test('an unknown live state is preserved and not terminal', () {
      final snapshot = _parse({..._liveSnapshot(), 'state': 'future_state'});
      expect(snapshot.state, 'future_state');
      expect(snapshot.isTerminal, isFalse);
    });

    test('a legacy terminal state without an event is terminal', () {
      for (final state in ['succeeded', 'failed', 'cancelled', 'interrupted']) {
        expect(_parse({..._liveSnapshot(), 'state': state}).isTerminal, isTrue);
      }
    });

    test('the largest signed 64-bit sequence is exact', () {
      final snapshot = _parse({
        ..._liveSnapshot(),
        'last_sequence': _maxSequence,
      });
      expect(snapshot.sequence.toString(), _maxSequence);
    });

    test('a non-canonical run id argument is a caller error', () {
      expect(
        () => RunSnapshot.parse('{}', runId: _runId.toUpperCase()),
        throwsArgumentError,
      );
    });

    Map<String, Object?> terminal(Map<String, Object?> changes) => {
      ..._instance('valid/RunSnapshot.json'),
      'terminal': {
        ...(_instance('valid/RunSnapshot.json')['terminal']!
            as Map<String, Object?>),
        ...changes,
      },
    };

    for (final (name, body, runId) in [
      (
        'another run id argument',
        _liveSnapshot(),
        '${_runId.substring(0, 35)}1',
      ),
      ('a non-JSON body', null, _runId),
      ('state empty', {..._liveSnapshot(), 'state': ''}, _runId),
      ('state too long', {..._liveSnapshot(), 'state': 'a' * 65}, _runId),
      (
        'last_sequence zero',
        {..._liveSnapshot(), 'last_sequence': '0'},
        _runId,
      ),
      (
        'last_sequence above signed 64-bit',
        {..._liveSnapshot(), 'last_sequence': '9223372036854775808'},
        _runId,
      ),
      (
        'last_sequence as a JSON number',
        {..._liveSnapshot(), 'last_sequence': 2},
        _runId,
      ),
      ('padded cursor', {..._liveSnapshot(), 'resume_cursor': 'abc='}, _runId),
      (
        'cursor too long',
        {..._liveSnapshot(), 'resume_cursor': 'a' * 513},
        _runId,
      ),
      (
        'conversation id not canonical',
        {..._liveSnapshot(), 'conversation_id': 'X'},
        _runId,
      ),
      ('invalid branch id', {..._liveSnapshot(), 'branch_id': 'x'}, _runId),
      (
        'terminal before last_sequence',
        {...terminal({}), 'last_sequence': '4'},
        _runId,
      ),
      (
        'terminal of another run',
        terminal({'run_id': '0f0e0d0c-0b0a-4908-8706-050403020101'}),
        _runId,
      ),
      (
        'terminal with private data',
        terminal({
          'data': {'reason': 'requested', 'approval_id': _runId},
        }),
        _runId,
      ),
      (
        'terminal is a live transition',
        terminal({'type': 'run.started', 'data': {}}),
        _runId,
      ),
      (
        'live state with a terminal event',
        {...terminal({}), 'state': 'running'},
        _runId,
      ),
      (
        'terminal state disagrees with terminal event',
        {...terminal({}), 'state': 'succeeded'},
        _runId,
      ),
    ]) {
      test('refuses $name', () {
        final json = body == null ? 'not json' : jsonEncode(body);
        expect(() => RunSnapshot.parse(json, runId: runId), throwsA(_invalid));
      });
    }

    test('a terminal event of an unknown type is terminal', () {
      final snapshot = _parse(
        terminal({
          'type': 'run.future_end',
          'data': {'x': 1},
        }),
      );
      expect(snapshot.isTerminal, isTrue);
      expect(snapshot.state, 'cancelled');
    });
  });

  group('framing', () {
    // The ADR 0034 serialized example: a heartbeat and three items.
    final lifecycle = [
      ': heartbeat\n\n',
      for (final name in ['Created', 'Started', 'Cancelled'])
        _record(_instance('valid/RunEvent$name.json')),
    ].join();

    void expectLifecycle(List<RunReplayEvent> events) {
      expect(events.map((e) => e.sequence.toInt()), [1, 2, 3]);
      expect(events.map((e) => e.state), ['queued', 'running', 'cancelled']);
      expect(events.last.isTerminal, isTrue);
      expect(events.map((e) => e.cursor), [
        for (final name in ['Created', 'Started', 'Cancelled'])
          _instance('valid/RunEvent$name.json')['id'],
      ]);
    }

    test('decodes the lifecycle example', () async {
      expectLifecycle(await _decode(lifecycle));
    });

    test('any two-chunk split decodes identically', () async {
      // Non-ASCII in a comment, an unknown field and the data of an unknown
      // type place multi-byte characters across every split point.
      final body =
          ': heartbeat é😀\n\n'
          'x-unknown: ü\n${_frame(
            _event(type: 'example.note', data: {'note': 'é😀'}),
            id: 'YQ',
          )}'
          '${_frame(
            _event(sequence: '2', type: 'run.started'),
            id: 'Yg',
          )}';
      final bytes = utf8.encode(body);
      for (var split = 0; split <= bytes.length; split++) {
        final events = await _decodeChunks([
          bytes.sublist(0, split),
          bytes.sublist(split),
        ]);
        expect(events.map((e) => e.cursor), ['YQ', 'Yg'], reason: '$split');
      }
    });

    test('one-byte chunks decode identically', () async {
      final bytes = utf8.encode(lifecycle);
      expectLifecycle(
        await _decodeChunks([
          for (final b in bytes) [b],
        ]),
      );
    });

    for (final (name, eol) in [('CRLF', '\r\n'), ('CR', '\r')]) {
      test('accepts $name line endings, split anywhere', () async {
        final body = lifecycle.replaceAll('\n', eol);
        final bytes = utf8.encode(body);
        expectLifecycle(await _decode(body));
        expectLifecycle(
          await _decodeChunks([
            for (final b in bytes) [b],
          ]),
        );
      });
    }

    test(
      'ignores one leading BOM and accepts fields without a space',
      () async {
        final body = '﻿id:YQ\ndata:${_event()}\n\n';
        final events = await _decode(body);
        expect(events.single.cursor, 'YQ');
      },
    );

    test('joins multiple data lines with a line feed', () async {
      final json = _event();
      final cut = json.indexOf(',');
      final body =
          'id: YQ\ndata: ${json.substring(0, cut)}\n'
          'data: ${json.substring(cut)}\n\n';
      expect((await _decode(body)).single.sequence, BigInt.one);
    });

    test(
      'tolerates a named event, retry, unknown fields and comments',
      () async {
        final body =
            'retry: 1000\n\n'
            ': comment\n'
            'event: example.named\n'
            'retry: 600000\n'
            'unknown\n'
            'id: YQ\n'
            'data: ${_event()}\n\n';
        expect((await _decode(body)).single.cursor, 'YQ');
      },
    );

    for (final (name, body) in [
      ('a record without id', 'data: ${_event()}\n\n'),
      ('a record without data', 'id: YQ\n\n'),
      ('an invalid cursor', 'id: a+b\ndata: ${_event()}\n\n'),
      ('an empty cursor', 'id:\ndata: ${_event()}\n\n'),
      ('retry above the bound', 'retry: 600001\n\n'),
      ('negative retry', 'retry: -1\n\n'),
      ('non-numeric retry', 'retry: soon\n\n'),
      ('a long event name', 'event: ${'e' * 65}\n${_frame(_event())}'),
      ('data shorter than two characters', 'id: YQ\ndata: 1\n\n'),
      ('data that is not JSON', 'id: YQ\ndata: not json\n\n'),
      (
        'an invalid replayed duplicate',
        _frame(_event()) + _frame(_event(data: {'x': 1})),
      ),
    ]) {
      test('refuses $name', () async {
        await expectLater(_decode(body), throwsA(_invalid));
      });
    }

    test('accepts sequence gaps from hidden events', () async {
      final events = await _decode(
        _frame(_event()) + _frame(_event(sequence: '5', type: 'run.started')),
      );
      expect(events.map((e) => e.sequence.toInt()), [1, 5]);
    });

    test('refuses malformed UTF-8 with the fixed failure', () async {
      await expectLater(
        _decodeChunks([
          utf8.encode('id: YQ\ndata: '),
          [0xFF],
          utf8.encode('\n\n'),
        ]),
        throwsA(_invalid),
      );
    });

    test('a truncated record is discarded and does not advance', () async {
      final complete = _frame(_event());
      final partial = 'id: Yg\ndata: ${_event(sequence: '2')}\n';
      final events = await _decode(complete + partial);
      expect(events.map((e) => e.cursor), ['Y3Vyc29y']);
    });

    test('a truncated multi-byte character at the end is discarded', () async {
      final events = await _decodeChunks([
        utf8.encode('${_frame(_event())}: é'),
        utf8.encode('😀').sublist(0, 2),
      ]);
      expect(events, hasLength(1));
    });

    test('an empty body produces no events', () async {
      expect(await _decodeChunks([]), isEmpty);
    });

    test('data at the 131072-character bound is accepted', () async {
      String padded(int length) {
        final base = _event(type: 'example.note', data: {'pad': ''});
        final pad = '😀' * (length - base.runes.length);
        return _event(type: 'example.note', data: {'pad': pad});
      }

      final exact = padded(131072);
      expect(exact.runes.length, 131072);
      expect(await _decode(_frame(exact)), hasLength(1));
      await expectLater(_decode(_frame(padded(131073))), throwsA(_invalid));
    });

    test('an unterminated line fails once it exceeds the bound', () async {
      final source = StreamController<List<int>>();
      final failure = decodeRunEvents(source.stream, runId: _runId).toList();
      final chunk = utf8.encode('data: ${'a' * 65536}');
      // Bounded: fails while the source is still open.
      for (var i = 0; i < 9; i++) {
        source.add(chunk);
      }
      await expectLater(failure, throwsA(_invalid));
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test(
      'a stale terminal at the start of a replay cannot suppress a later event',
      () async {
        final events = await _decode(
          _frame(_event(type: 'run.cancelled', data: {'reason': 'requested'})) +
              _frame(_event(sequence: '2', type: 'run.started')),
        );
        expect(events.map((e) => e.state), ['cancelled', 'running']);
      },
    );

    test('replayed duplicates are dropped without advancing', () async {
      final events = await _decode(
        _frame(_event(), id: 'YQ') +
            _frame(_event(type: 'run.started'), id: 'Yg') +
            _frame(
              _event(sequence: '2', type: 'run.started'),
              id: 'Yw',
            ) +
            _frame(_event(), id: 'ZA') +
            _frame(
              _event(sequence: '3', type: 'example.note'),
              id: 'ZQ',
            ),
      );
      expect(events.map((e) => e.cursor), ['YQ', 'Yw', 'ZQ']);
      expect(events.map((e) => e.sequence.toInt()), [1, 2, 3]);
    });

    test('a replayed terminal duplicate is dropped, not delivered', () async {
      final cancelled = _event(
        sequence: '3',
        type: 'run.cancelled',
        data: {'reason': 'requested'},
      );
      final events = await _decode(
        _frame(cancelled, id: 'Yw') + _frame(cancelled, id: 'ZA'),
      );
      expect(events.map((e) => e.cursor), ['Yw']);
    });

    test(
      'the stream continues past the terminal event until the body ends',
      () async {
        final source = StreamController<List<int>>();
        final events = <RunReplayEvent>[];
        var done = false;
        decodeRunEvents(
          source.stream,
          runId: _runId,
        ).listen(events.add, onDone: () => done = true);
        source.add(utf8.encode('$lifecycle: heartbeat\n\n'));
        await pumpEventQueue();
        expectLifecycle(events);
        expect(done, isFalse);
        expect(source.hasListener, isTrue);
        await source.close();
        await pumpEventQueue();
        expect(done, isTrue);
      },
    );

    for (final (name, tail) in [
      ('a malformed frame', utf8.encode('id: Zg\ndata: not json\n\n')),
      ('malformed UTF-8', [...utf8.encode(': '), 0xC3, 0x28, 0x0A]),
      ('an oversized line', utf8.encode('data: ${'a' * 600000}')),
    ]) {
      test('events before $name in one chunk are delivered first', () async {
        var cancelled = false;
        final source = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        final events = <RunReplayEvent>[];
        final error = Completer<Object>();
        final done = Completer<void>();
        decodeRunEvents(
          source.stream,
          runId: _runId,
        ).listen(events.add, onError: error.complete, onDone: done.complete);
        source.add([...utf8.encode(lifecycle), ...tail]);
        expect(await error.future, _invalid);
        await done.future;
        expectLifecycle(events);
        expect(cancelled, isTrue);
        await source.close();
      });
    }

    test('a source error is forwarded unchanged and ends the stream', () async {
      final source = StreamController<List<int>>();
      final failure = StateError('transport');
      final events = <RunReplayEvent>[];
      final error = Completer<Object>();
      final done = Completer<void>();
      decodeRunEvents(
        source.stream,
        runId: _runId,
      ).listen(events.add, onError: error.complete, onDone: done.complete);
      source
        ..add(utf8.encode(_frame(_event())))
        ..addError(failure);
      expect(await error.future, same(failure));
      await done.future;
      expect(events, hasLength(1));
      expect(source.hasListener, isFalse);
      await source.close();
    });

    for (final (name, before, delivered) in [
      ('before any bytes arrive', <String>[], 0),
      ('on a heartbeat-only stream', [': heartbeat\n\n', ': heartbeat\n\n'], 0),
      ('between events', [_frame(_event())], 1),
      ('inside a partial record', ['id: YQ\ndata: {"run_id"'], 0),
    ]) {
      test('cancellation completes promptly $name', () async {
        var cancelled = false;
        final source = StreamController<List<int>>(
          onCancel: () => cancelled = true,
        );
        final events = <RunReplayEvent>[];
        final subscription = decodeRunEvents(
          source.stream,
          runId: _runId,
        ).listen(events.add);
        for (final text in before) {
          source.add(utf8.encode(text));
        }
        await pumpEventQueue();
        // The source never sends more or closes; cancel must not wait for it.
        await subscription.cancel().timeout(const Duration(seconds: 1));
        expect(cancelled, isTrue);
        expect(events, hasLength(delivered));
      });
    }

    test('pausing the subscription pauses the source', () async {
      final source = StreamController<List<int>>();
      final subscription = decodeRunEvents(
        source.stream,
        runId: _runId,
      ).listen((_) {});
      await pumpEventQueue();
      subscription.pause();
      expect(source.isPaused, isTrue);
      subscription.resume();
      expect(source.isPaused, isFalse);
      await subscription.cancel();
    });

    test('refuses an event of another run', () async {
      await expectLater(
        _decode(
          _frame(_event()),
          runId: '0f0e0d0c-0b0a-4908-8706-050403020101',
        ),
        throwsA(_invalid),
      );
    });

    test('a non-canonical run id argument is a caller error', () {
      expect(
        () => decodeRunEvents(_bytes([]), runId: 'RUN'),
        throwsArgumentError,
      );
    });
  });
}

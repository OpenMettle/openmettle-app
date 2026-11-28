import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/api/src/http_run_client.dart';
import 'package:openmettle_app/api/src/http_session_client.dart';
import 'package:openmettle_app/api/src/native_session_client.dart';
import 'package:openmettle_app/api/src/transport.dart';
import 'package:openmettle_app/runs/run_replay.dart';
import 'package:openmettle_app/runs/run_wire.dart';

import 'fake_transport.dart';

const _runId = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _cursor =
    'AQdleGFtcGxlAAAAAAAAAAPX4G_25L6evhHoy1RVdAyip9DN9oR5tDgnPL_6AVB-OQ';
final _runUrl = Uri.parse('$origin/v1/runs/$_runId');
final _eventsUrl = Uri.parse('$origin/v1/runs/$_runId/events?after=$_cursor');

/// A synthetic terminal `Run` shaped like core's `RunSnapshot` example. The
/// pinned fixtures themselves are checked in test/runs/run_wire_test.dart;
/// this file also runs in Chrome, which cannot read files.
final _snapshotBody = jsonEncode({
  'run_id': _runId,
  'conversation_id': '0f0e0d0c-0b0a-4908-8706-050403020101',
  'state': 'cancelled',
  'created_at': '2026-11-20T09:00:01.000000Z',
  'last_sequence': '3',
  'resume_cursor': _cursor,
  'terminal': jsonDecode(
    _event(3, 'run.cancelled', data: {'reason': 'requested'}),
  ),
});

String _event(int sequence, String type, {Map<String, Object?>? data}) =>
    jsonEncode({
      'run_id': _runId,
      'sequence': '$sequence',
      'type': type,
      'type_version': 1,
      'occurred_at': '2026-11-20T09:00:0$sequence.000000Z',
      'data': data ?? <String, Object?>{},
    });

String _frame(int sequence, String type, {Map<String, Object?>? data}) =>
    'id: cursor$sequence\ndata: ${_event(sequence, type, data: data)}\n\n';

String _problem(int status, String code) => jsonEncode({
  'type': 'about:blank',
  'title': 'Refused',
  'status': status,
  'code': code,
  'request_id': 'a3e1c0d9-8b7f-4e6d-9c5b-4a3f2e1d0c9b',
});

const _json = {'content-type': 'application/json'};
const _sse = {'content-type': 'text/event-stream'};
const _problemJson = {'content-type': 'application/problem+json'};
const _v1 = {'openmettle-api-version': '1.0'};

/// A scripted body: [chunks] are delivered, then the body ends unless
/// [open] is set. [events] records listen, pause, resume and cancel.
class _Body {
  _Body(List<String> chunks, {this.open = false, Object? error}) {
    controller = StreamController<List<int>>(
      onListen: () {
        events.add('listen');
        for (final chunk in chunks) {
          controller.add(utf8.encode(chunk));
        }
        if (error != null) controller.addError(error);
        if (!open) controller.close();
      },
      onPause: () => events.add('pause'),
      onResume: () => events.add('resume'),
      onCancel: () => events.add('cancel'),
    );
  }

  final bool open;
  late final StreamController<List<int>> controller;
  final events = <String>[];

  void add(String text) => controller.add(utf8.encode(text));
}

Future<StreamedReply> Function(OpenedRequest) _answer(
  int status, {
  Map<String, String> headers = const {},
  _Body? body,
  String type = 'basic',
  bool redirected = false,
  Uri? url,
}) =>
    (request) async => StreamedReply(
      HttpReply(
        status: status,
        url: url ?? request.url,
        type: type,
        redirected: redirected,
        headers: headers,
      ),
      (body ?? _Body(const [])).controller.stream,
    );

Future<StreamedReply> Function(OpenedRequest) _text(
  int status,
  String text, {
  Map<String, String> headers = const {..._v1, ..._json},
}) => _answer(status, headers: headers, body: _Body([text]));

HttpRunSessionClient _client(FakeStreamingTransport transport) =>
    sessionClientFor(
      transport,
      login: '/auth/login',
      session: '/auth/session',
      logout: '/auth/logout',
    ) as HttpRunSessionClient;

Matcher _bad([int? status]) => isA<ApiFailure>()
    .having((f) => f.kind, 'kind', ApiFailureKind.badResponse)
    .having((f) => f.status, 'status', status);

Future<List<Object>> _drain(Stream<RunReplayEvent> stream) async {
  final seen = <Object>[];
  final done = Completer<void>();
  stream.listen(
    seen.add,
    onError: (Object error) => seen.add(error),
    onDone: done.complete,
  );
  await done.future;
  return seen;
}

class _Unused implements NativeAuthPlatform, NativeTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('construction', () {
    test('only a configured streaming browser client reads runs', () {
      SessionClient build(Transport transport, {String session = '/s'}) =>
          sessionClientFor(
            transport,
            login: '/l',
            session: session,
            logout: '/o',
          );
      final streaming = FakeStreamingTransport(_answer(500));
      expect(build(streaming), isA<RunReplaySource>());
      expect(build(FakeTransport(reply(204))), isNot(isA<RunReplaySource>()));
      expect(build(streaming, session: '/v1/x'), isNot(isA<RunReplaySource>()));
      final insecure = FakeStreamingTransport(_answer(500));
      expect(
        sessionClientFor(
          _InsecureOrigin(insecure),
          login: '/l',
          session: '/s',
          logout: '/o',
        ),
        isNot(isA<RunReplaySource>()),
      );
      expect(
        NativeSessionClient(null, _Unused(), _Unused()),
        isNot(isA<RunReplaySource>()),
      );
    });

    test('session calls still use the unary transport', () async {
      final transport = FakeStreamingTransport(_answer(500))
        ..respond = reply(204);
      expect(await _client(transport).checkSession(), isTrue);
      expect(transport.sent.single.url, sessionUrl);
      expect(transport.opened, isEmpty);
    });
  });

  group('request construction', () {
    test('a snapshot is one GET of the canonical run URL', () async {
      final transport = FakeStreamingTransport(_text(200, _snapshotBody));
      final snapshot = await _client(transport).snapshot(_runId);
      expect(snapshot.runId, _runId);
      expect(snapshot.isTerminal, isTrue);
      expect(transport.opened.single.url, _runUrl);
      expect(transport.opened.single.accept, 'application/json');
      // A fully received snapshot is not aborted.
      await pumpEventQueue();
      expect(transport.opened.single.cancelled, isFalse);
      expect(transport.sent, isEmpty);
    });

    test('a stream resumes after the opaque cursor', () async {
      final transport = FakeStreamingTransport(
        _answer(200, headers: {..._v1, ..._sse}, body: _Body(const [])),
      );
      await _drain(_client(transport).events(_runId, _cursor));
      await pumpEventQueue();
      // A body that ended by itself is not aborted.
      expect(transport.opened.single.cancelled, isFalse);
      expect(transport.opened.single.url, _eventsUrl);
      expect(
        transport.opened.single.url.toString(),
        endsWith('?after=$_cursor'),
      );
      expect(transport.opened.single.accept, 'text/event-stream');
    });

    test('an invalid run ID or cursor is refused before the network', () async {
      final transport = FakeStreamingTransport(_answer(500));
      final client = _client(transport);
      for (final runId in [
        '',
        _runId.toUpperCase(),
        '{$_runId}',
        '$_runId/events',
        '../$_runId',
        '$_runId?x',
        ' $_runId',
        '0f0e0d0c0b0a490887060504030201000000',
      ]) {
        await expectLater(client.snapshot(runId), throwsArgumentError);
        expect(await _drain(client.events(runId, _cursor)), [
          isA<ArgumentError>(),
        ]);
      }
      for (final cursor in [
        '',
        'a/b',
        'a?b',
        'a%2Fb',
        'a=',
        'a b',
        'x' * 513,
      ]) {
        expect(await _drain(client.events(_runId, cursor)), [
          isA<ArgumentError>(),
        ]);
      }
      expect(transport.opened, isEmpty);
      expect(transport.sent, isEmpty);
    });
  });

  group('snapshot replies', () {
    Future<RunSnapshot> read(Future<StreamedReply> Function(OpenedRequest) a) =>
        _client(FakeStreamingTransport(a)).snapshot(_runId);

    test('verified refusals', () async {
      for (final (status, code, failure) in [
        (401, 'unauthenticated', RunReplayFailure.unauthenticated),
        (404, 'not_found', RunReplayFailure.notFound),
        (403, 'policy', RunReplayFailure.forbidden),
      ]) {
        await expectLater(
          read(
            _text(
              status,
              _problem(status, code),
              headers: {..._v1, ..._problemJson},
            ),
          ),
          throwsA(failure),
        );
      }
    });

    test('a cursor problem or 204 is not a snapshot answer', () async {
      await expectLater(
        read(
          _text(
            400,
            _problem(400, 'invalid_cursor'),
            headers: {..._v1, ..._problemJson},
          ),
        ),
        throwsA(_bad(400)),
      );
      await expectLater(read(_answer(204, headers: _v1)), throwsA(_bad(204)));
    });

    test('temporary failures may be retried', () async {
      for (final status in [429, 500, 502, 503, 504]) {
        for (final headers in [const <String, String>{}, _v1]) {
          await expectLater(
            read(_text(status, '<html>', headers: headers)),
            throwsA(RunReplayFailure.unavailable),
          );
        }
      }
      await expectLater(
        read((_) async => throw const TransportFailure()),
        throwsA(RunReplayFailure.unavailable),
      );
      await expectLater(
        read(
          _answer(
            200,
            headers: {..._v1, ..._json},
            body: _Body(['{"run_id"'], error: const TransportFailure()),
          ),
        ),
        throwsA(RunReplayFailure.unavailable),
      );
    });

    test('protocol violations stop with a bad response', () async {
      final problem401 = _problem(401, 'unauthenticated');
      for (final (answer, status) in [
        (_text(200, _snapshotBody, headers: _json), 200),
        (_text(200, _snapshotBody, headers: {..._v1, ..._sse}), 200),
        (_text(200, '{}'), 200),
        (
          _text(
            200,
            _snapshotBody.replaceAll(
              _runId,
              '0f0e0d0c-0b0a-4908-8706-050403020102',
            ),
          ),
          200,
        ),
        (_text(200, '\uFEFF$_snapshotBody'), 200),
        (_text(401, problem401, headers: _problemJson), 401),
        (_text(401, problem401, headers: {..._v1, ..._json}), 401),
        (
          _text(
            401,
            _problem(401, 'not_found'),
            headers: {..._v1, ..._problemJson},
          ),
          401,
        ),
        (
          _text(
            404,
            _problem(401, 'not_found'),
            headers: {..._v1, ..._problemJson},
          ),
          404,
        ),
        (
          _text(
            400,
            _problem(400, 'validation'),
            headers: {..._v1, ..._problemJson},
          ),
          400,
        ),
        (_text(418, '', headers: _v1), 418),
        (_answer(200, url: Uri.parse('$origin/elsewhere'), headers: _v1), 200),
        (_answer(200, redirected: true, headers: {..._v1, ..._json}), 200),
        (_answer(0, type: 'opaqueredirect'), null),
      ]) {
        await expectLater(read(answer), throwsA(_bad(status)));
      }
    });

    test('invalid UTF-8 is a bad response', () async {
      final body = StreamController<List<int>>()
        ..add([0x7b, 0xff, 0x7d])
        ..close();
      await expectLater(
        read(
          (request) async => StreamedReply(
            HttpReply(
              status: 200,
              url: request.url,
              headers: {..._v1, ..._json},
            ),
            body.stream,
          ),
        ),
        throwsA(_bad(200)),
      );
    });

    test('an unsupported major version stops', () async {
      for (final status in [200, 401, 503]) {
        await expectLater(
          read(
            _text(
              status,
              '',
              headers: {'openmettle-api-version': '2.0', ..._json},
            ),
          ),
          throwsA(
            isA<ApiFailure>().having(
              (f) => f.kind,
              'kind',
              ApiFailureKind.unsupportedVersion,
            ),
          ),
        );
      }
    });

    test('oversized bodies are refused and the read is aborted', () async {
      final big = _Body(['x' * (64 << 10), 'x'], open: true);
      final transport = FakeStreamingTransport(
        _answer(401, headers: {..._v1, ..._problemJson}, body: big),
      );
      await expectLater(
        _client(transport).snapshot(_runId),
        throwsA(_bad(401)),
      );
      expect(big.events, ['listen', 'cancel']);
      await pumpEventQueue();
      expect(transport.opened.single.cancelled, isTrue);

      final run = _Body(['x' * (1 << 20), 'x'], open: true);
      await expectLater(
        read(_answer(200, headers: {..._v1, ..._json}, body: run)),
        throwsA(_bad(200)),
      );
      expect(run.events, ['listen', 'cancel']);
    });

    testWidgets('the whole exchange has a finite deadline', (tester) async {
      final body = _Body(const ['{'], open: true);
      final transport = FakeStreamingTransport(
        _answer(200, headers: {..._v1, ..._json}, body: body),
      );
      Object? error;
      unawaited(
        _client(transport)
            .snapshot(_runId)
            .then<void>((_) {}, onError: (Object e) => error = e),
      );
      await tester.pump(const Duration(seconds: 29));
      expect(transport.opened.single.cancelled, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.cancelled, isTrue);
      // The real transport ends an aborted body with a transport failure.
      body.controller.addError(const TransportFailure());
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(error, RunReplayFailure.unavailable);
    });
  });

  group('stream replies', () {
    Future<List<Object>> stream(
      Future<StreamedReply> Function(OpenedRequest) answer,
    ) =>
        _drain(_client(FakeStreamingTransport(answer)).events(_runId, _cursor));

    test('a 204 is terminal at the cursor only with an empty body', () async {
      expect(await stream(_answer(204, headers: _v1)), [
        RunReplayFailure.terminalAtCursor,
      ]);
      expect(await stream(_answer(204)), [_bad(204)]);
      expect(await stream(_answer(204, headers: _v1, body: _Body(['x']))), [
        _bad(204),
      ]);
    });

    test('verified refusals and retryable failures', () async {
      for (final (status, code, failure) in [
        (400, 'invalid_cursor', RunReplayFailure.invalidCursor),
        (401, 'unauthenticated', RunReplayFailure.unauthenticated),
        (403, 'policy', RunReplayFailure.forbidden),
        (404, 'not_found', RunReplayFailure.notFound),
      ]) {
        expect(
          await stream(
            _text(
              status,
              _problem(status, code),
              headers: {..._v1, ..._problemJson},
            ),
          ),
          [failure],
        );
      }
      for (final status in [429, 500, 502, 503, 504]) {
        expect(await stream(_text(status, '', headers: const {})), [
          RunReplayFailure.unavailable,
        ]);
      }
      expect(await stream((_) async => throw const TransportFailure()), [
        RunReplayFailure.unavailable,
      ]);
    });

    test('protocol violations are not retryable failures', () async {
      for (final answer in [
        _text(200, _frame(1, 'run.created'), headers: {..._v1, ..._json}),
        _text(200, _frame(1, 'run.created'), headers: _sse),
        _answer(0, type: 'opaqueredirect'),
        _text(
          400,
          _problem(400, 'validation'),
          headers: {..._v1, ..._problemJson},
        ),
      ]) {
        final seen = await stream(answer);
        expect(seen, hasLength(1));
        expect(seen.single, isA<ApiFailure>());
      }
      expect(
        await stream(_text(200, 'data: {}\n\n', headers: {..._v1, ..._sse})),
        [isA<FormatException>()],
      );
    });

    test('events split across chunks are decoded in order', () async {
      final text =
          ': heartbeat\n\n${_frame(1, 'run.created')}${_frame(2, 'run.started')}';
      final chunks = [
        for (var i = 0; i < text.length; i += 7)
          text.substring(i, i + 7 > text.length ? text.length : i + 7),
      ];
      final seen = await stream(
        _answer(200, headers: {..._v1, ..._sse}, body: _Body(chunks)),
      );
      expect(
        [for (final e in seen.cast<RunReplayEvent>()) e.sequence],
        [BigInt.one, BigInt.two],
      );
      expect((seen.last as RunReplayEvent).cursor, 'cursor2');
    });

    test('network loss keeps the complete prefix and is retryable', () async {
      final frame = _frame(2, 'run.started');
      final seen = await stream(
        _answer(
          200,
          headers: {..._v1, ..._sse},
          body: _Body([
            _frame(1, 'run.created'),
            frame.substring(0, frame.length ~/ 2),
          ], error: const TransportFailure()),
        ),
      );
      expect(seen, [isA<RunReplayEvent>(), RunReplayFailure.unavailable]);
      expect((seen.first as RunReplayEvent).sequence, BigInt.one);
    });

    test('cancelling a pending head aborts the request', () async {
      final head = Completer<StreamedReply>();
      final transport = FakeStreamingTransport((_) => head.future);
      final subscription = _client(transport)
          .events(_runId, _cursor)
          .listen((_) => fail('no event expected'));
      await pumpEventQueue();
      expect(transport.opened.single.cancelled, isFalse);
      await subscription.cancel();
      await pumpEventQueue();
      expect(transport.opened.single.cancelled, isTrue);
      head.completeError(const TransportFailure());
      await pumpEventQueue();
    });

    test('cancelling an open stream aborts and releases the body', () async {
      final body = _Body([_frame(1, 'run.created')], open: true);
      final transport = FakeStreamingTransport(
        _answer(200, headers: {..._v1, ..._sse}, body: body),
      );
      final seen = <RunReplayEvent>[];
      final subscription = _client(transport)
          .events(_runId, _cursor)
          .listen(seen.add);
      await pumpEventQueue();
      expect(seen, hasLength(1));
      await subscription.cancel();
      expect(body.events, contains('cancel'));
      expect(transport.opened.single.cancelled, isTrue);
    });

    testWidgets('pausing pauses the body and the idle timer', (tester) async {
      final body = _Body([_frame(1, 'run.created')], open: true);
      final transport = FakeStreamingTransport(
        _answer(200, headers: {..._v1, ..._sse}, body: body),
      );
      final seen = <Object>[];
      final subscription = _client(transport)
          .events(_runId, _cursor)
          .listen(seen.add, onError: seen.add);
      await tester.pump();
      expect(seen, [isA<RunReplayEvent>()]);
      subscription.pause();
      await tester.pump();
      expect(body.events, contains('pause'));
      await tester.pump(const Duration(minutes: 5));
      expect(transport.opened.single.cancelled, isFalse);
      subscription.resume();
      await tester.pump();
      expect(body.events, contains('resume'));
      await tester.pump(const Duration(seconds: 44));
      expect(transport.opened.single.cancelled, isFalse);
      // Cancellation completes on the root zone, outside fake time.
      await tester.runAsync(subscription.cancel);
      expect(body.events, contains('cancel'));
      expect(transport.opened.single.cancelled, isTrue);
      expect(seen, hasLength(1));
    });

    testWidgets('a stalled refusal body is bounded by the head deadline', (
      tester,
    ) async {
      final body = _Body(const ['{"type":'], open: true);
      final transport = FakeStreamingTransport(
        _answer(401, headers: {..._v1, ..._problemJson}, body: body),
      );
      final seen = <Object>[];
      _client(transport)
          .events(_runId, _cursor)
          .listen(seen.add, onError: seen.add);
      await tester.pump(const Duration(seconds: 29));
      expect(transport.opened.single.cancelled, isFalse);
      expect(seen, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.cancelled, isTrue);
      // The real transport ends an aborted body with a transport failure.
      body.controller.addError(const TransportFailure());
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      expect(seen, [RunReplayFailure.unavailable]);
      expect(body.events, contains('cancel'));
    });

    testWidgets('the head wait is finite', (tester) async {
      final head = Completer<StreamedReply>();
      final transport = FakeStreamingTransport((_) => head.future);
      final seen = <Object>[];
      _client(transport)
          .events(_runId, _cursor)
          .listen(seen.add, onError: seen.add);
      await tester.pump(const Duration(seconds: 29));
      expect(transport.opened.single.cancelled, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.cancelled, isTrue);
      // The real transport rejects an aborted fetch.
      head.completeError(const TransportFailure());
      await tester.pump();
      expect(seen, [RunReplayFailure.unavailable]);
    });

    testWidgets('heartbeats keep a long stream open; silence ends it', (
      tester,
    ) async {
      final body = _Body(const [': heartbeat\n\n'], open: true);
      final transport = FakeStreamingTransport(
        _answer(200, headers: {..._v1, ..._sse}, body: body),
      );
      final seen = <Object>[];
      var done = false;
      _client(transport)
          .events(_runId, _cursor)
          .listen(seen.add, onError: seen.add, onDone: () => done = true);
      await tester.pump();
      // One hour of 15-second heartbeats, then an event.
      for (var i = 0; i < 240; i++) {
        await tester.pump(const Duration(seconds: 15));
        body.add(': heartbeat\n\n');
      }
      body.add(_frame(1, 'run.created'));
      await tester.pump();
      expect(transport.opened.single.cancelled, isFalse);
      expect(seen, [isA<RunReplayEvent>()]);
      await tester.pump(const Duration(seconds: 44));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 1));
      expect(transport.opened.single.cancelled, isTrue);
      expect(seen.last, RunReplayFailure.unavailable);
      // The decoder reports done once the body's cancellation completes,
      // which happens on the root zone, outside fake time.
      await tester.runAsync(pumpEventQueue);
      expect(done, isTrue);
    });
  });

  test('drives the replay controller from snapshot to completion', () async {
    final snapshot = jsonEncode({
      ...jsonDecode(_snapshotBody) as Map<String, Object?>,
      'state': 'running',
      'last_sequence': '2',
      'terminal': null,
    });
    final transport = FakeStreamingTransport(
      (request) => request.url == _runUrl
          ? _text(200, snapshot)(request)
          : _answer(
              200,
              headers: {..._v1, ..._sse},
              body: _Body([
                _frame(3, 'run.cancelled', data: {'reason': 'requested'}),
              ], open: true),
            )(request),
    );
    final controller = RunReplayController(
      source: _client(transport),
      runId: _runId,
    )..start();
    addTearDown(controller.dispose);
    await pumpEventQueue();
    expect(controller.phase, RunReplayPhase.complete);
    expect(controller.state, 'cancelled');
    expect(transport.opened.map((r) => r.url), [_runUrl, _eventsUrl]);
    await pumpEventQueue();
    expect(transport.opened.map((r) => r.cancelled), [false, true]);
  });
}

/// A streaming transport whose page origin is not HTTPS.
class _InsecureOrigin extends FakeStreamingTransport {
  _InsecureOrigin(FakeStreamingTransport inner) : super(inner.stream);

  @override
  String get origin => 'http://app.example.test';
}

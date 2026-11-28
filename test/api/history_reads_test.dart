import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/api/src/http_run_client.dart';
import 'package:openmettle_app/api/src/http_session_client.dart';
import 'package:openmettle_app/api/src/native_session_client.dart';
import 'package:openmettle_app/api/src/transport.dart';
import 'package:openmettle_app/conversations/history.dart';

import 'fake_transport.dart';

// Synthetic IDs and bodies shaped like core's pinned examples. The pinned
// fixtures themselves are read in history_fixtures_test.dart; this file also
// runs in Chrome, which cannot read files.
const _conversation = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _branch = '0f0e0d0c-0b0a-4908-8706-050403020101';
const _scope = '6e2dab3f-8c40-4d9e-8f1b-2c3d4e5f6071';
const _cursor =
    'AQdleGFtcGxlAAAAAAAAAAPX4G_25L6evhHoy1RVdAyip9DN9oR5tDgnPL_6AVB-OQ';
const _otherCursor = 'AQdleGFtcGxlAAAAAAAAAA';
const _time = '2026-11-20T09:00:01.000000Z';

String _id(int n) =>
    '0f0e0d0c-0b0a-4908-8706-${(0x050403020200 + n).toRadixString(16).padLeft(12, '0')}';

final _conversationsUrl = Uri.parse('$origin/v1/conversations?limit=50');
final _branchesUrl = Uri.parse(
  '$origin/v1/conversations/$_conversation/branches?limit=50',
);
final _messagesUrl = Uri.parse(
  '$origin/v1/conversations/$_conversation/branches/$_branch/messages'
  '?limit=10',
);

Map<String, Object?> _conversationItem(String id) => {
  'conversation_id': id,
  'scope_kind': 'personal',
  'scope_id': _scope,
  'project_id': null,
  'created_at': _time,
  'access': 'write',
  'can_manage_shares': true,
};

Map<String, Object?> _branchItem(String id, {String? parent}) => {
  'conversation_id': _conversation,
  'branch_id': id,
  'created_at': _time,
  'history_available': true,
  'parent_branch_id': parent,
  'fork_message_id': null,
  'head_message_id': null,
};

Map<String, Object?> _text(String id, String text) => {
  'part_id': id,
  'kind': 'text',
  'text': text,
};

Map<String, Object?> _message(
  String id, {
  String? parent,
  String role = 'assistant',
  List<Map<String, Object?>>? parts,
  Object? stopReason,
}) => {
  'message_id': id,
  'parent_message_id': parent,
  'role': role,
  'parts': parts ?? [_text(_id(900), 'Answer.')],
  'run_id': role == 'user' ? null : _id(800),
  'input_count': role == 'user' ? null : '21',
  'output_count': role == 'user' ? null : '12',
  'stop_reason': stopReason,
};

String _page(List<Object?> items, {String? next}) => jsonEncode({
  'items': items,
  'page_info': {'next_cursor': next},
});

String _problem(int status, String code) => jsonEncode({
  'type': 'about:blank',
  'title': 'Refused',
  'status': status,
  'code': code,
  'request_id': 'a3e1c0d9-8b7f-4e6d-9c5b-4a3f2e1d0c9b',
});

const _v1 = {'openmettle-api-version': '1.0'};
const _json = {..._v1, 'content-type': 'application/json'};
const _problemJson = {..._v1, 'content-type': 'application/problem+json'};

Future<StreamedReply> Function(OpenedRequest) _answer(
  int status,
  String body, {
  Map<String, String> headers = _json,
  String type = 'basic',
  bool redirected = false,
  Uri? url,
  Object? error,
}) =>
    (request) async => StreamedReply(
      HttpReply(
        status: status,
        url: url ?? request.url,
        type: type,
        redirected: redirected,
        headers: headers,
      ),
      _body(body, error),
    );

/// [body], then [error] when given, as a lost connection would end it.
Stream<List<int>> _body(String body, Object? error) async* {
  yield utf8.encode(body);
  if (error != null) throw error;
}

HttpRunSessionClient _client(FakeStreamingTransport transport) =>
    sessionClientFor(
      transport,
      login: '/auth/login',
      session: '/auth/session',
      logout: '/auth/logout',
    ) as HttpRunSessionClient;

FakeStreamingTransport _serve(
  Future<StreamedReply> Function(OpenedRequest) answer,
) => FakeStreamingTransport(answer);

Future<HistoryPage<HistoryMessage>> _messages(
  Future<StreamedReply> Function(OpenedRequest) answer, {
  String? cursor,
}) => _client(_serve(answer)).messages(_conversation, _branch, cursor: cursor);

Future<HistoryPage<BranchSummary>> _branches(
  Future<StreamedReply> Function(OpenedRequest) answer,
) => _client(_serve(answer)).branches(_conversation);

Future<HistoryPage<ConversationSummary>> _conversations(
  Future<StreamedReply> Function(OpenedRequest) answer, {
  String? cursor,
}) => _client(_serve(answer)).conversations(cursor: cursor);

final _invalid = throwsA(HistoryFailure.invalidResponse);

class _Unused implements NativeAuthPlatform, NativeTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('construction', () {
    test('only a configured streaming browser client reads history', () {
      SessionClient build(Transport transport, {String session = '/s'}) =>
          sessionClientFor(
            transport,
            login: '/l',
            session: session,
            logout: '/o',
          );
      final streaming = _serve(_answer(500, ''));
      expect(build(streaming), isA<ConversationSource>());
      expect(
        build(FakeTransport(reply(204))),
        isNot(isA<ConversationSource>()),
      );
      expect(
        build(streaming, session: '/v1/x'),
        isNot(isA<ConversationSource>()),
      );
      expect(
        NativeSessionClient(null, _Unused(), _Unused()),
        isNot(isA<ConversationSource>()),
      );
    });
  });

  group('request construction', () {
    test('each list is one GET with an explicit limit', () async {
      final transport = _serve(_answer(200, _page(const [])));
      final client = _client(transport);
      await client.conversations();
      await client.branches(_conversation);
      await client.messages(_conversation, _branch);
      expect(
        [for (final r in transport.opened) r.url],
        [_conversationsUrl, _branchesUrl, _messagesUrl],
      );
      // The personal scope is the server default: no scope_id is sent.
      expect(transport.opened.first.url.queryParameters, {'limit': '50'});
      for (final request in transport.opened) {
        expect(request.accept, 'application/json');
      }
      // Completely received pages are not aborted.
      await pumpEventQueue();
      expect(transport.opened.any((r) => r.cancelled), isFalse);
      expect(transport.sent, isEmpty);
    });

    test(
      'a continuation sends the unchanged cursor with the same limit',
      () async {
        final transport = _serve(_answer(200, _page(const [])));
        final client = _client(transport);
        await client.conversations(cursor: _cursor);
        await client.branches(_conversation, cursor: _cursor);
        await client.messages(_conversation, _branch, cursor: _cursor);
        expect(
          [for (final r in transport.opened) r.url.toString()],
          [
            '$_conversationsUrl&cursor=$_cursor',
            '$_branchesUrl&cursor=$_cursor',
            '$_messagesUrl&cursor=$_cursor',
          ],
        );
      },
    );

    test('invalid IDs and cursors are refused before the network', () async {
      final transport = _serve(_answer(500, ''));
      final client = _client(transport);
      for (final id in [
        '',
        _conversation.toUpperCase(),
        '$_conversation/branches',
        '../$_conversation',
        '$_conversation?x',
        ' $_conversation',
      ]) {
        await expectLater(client.branches(id), throwsArgumentError);
        await expectLater(client.messages(id, _branch), throwsArgumentError);
        await expectLater(
          client.messages(_conversation, id),
          throwsArgumentError,
        );
      }
      for (final cursor in ['', 'a/b', 'a&limit=1', 'a%2Fb', 'a=', 'x' * 513]) {
        await expectLater(
          client.conversations(cursor: cursor),
          throwsA(HistoryFailure.invalidCursor),
        );
        await expectLater(
          client.branches(_conversation, cursor: cursor),
          throwsA(HistoryFailure.invalidCursor),
        );
        await expectLater(
          client.messages(_conversation, _branch, cursor: cursor),
          throwsA(HistoryFailure.invalidCursor),
        );
      }
      expect(transport.opened, isEmpty);
      expect(transport.sent, isEmpty);
    });
  });

  group('pages', () {
    test('conversations keep server order, IDs and the next cursor', () async {
      final page = await _conversations(
        _answer(
          200,
          _page([
            _conversationItem(_id(1)),
            {..._conversationItem(_id(2)), 'future': 1},
          ], next: _otherCursor),
        ),
      );
      expect([for (final c in page.items) c.id], [_id(1), _id(2)]);
      expect(page.items.first.createdAt, _time);
      expect(page.nextCursor, _otherCursor);
      expect(page.historyAvailable, isTrue);
    });

    test(
      'personal conversations share one scope and accept future access codes',
      () async {
        final page = await _conversations(
          _answer(
            200,
            _page([
              {..._conversationItem(_id(1)), 'access': 'future_access'},
            ]),
          ),
        );
        expect(page.items.single.id, _id(1));
        await expectLater(
          _conversations(
            _answer(
              200,
              _page([
                _conversationItem(_id(1)),
                {..._conversationItem(_id(2)), 'scope_id': _id(3)},
              ]),
            ),
          ),
          _invalid,
        );
      },
    );

    test('branches must belong to the requested conversation', () async {
      final page = await _branches(
        _answer(
          200,
          _page([
            _branchItem(_branch),
            {
              ..._branchItem(_id(2), parent: _branch),
              'history_available': false,
            },
          ]),
        ),
      );
      expect([for (final b in page.items) b.id], [_branch, _id(2)]);
      expect(page.items.last.parentBranchId, _branch);
      expect(page.items.last.historyAvailable, isFalse);
      await expectLater(
        _branches(
          _answer(
            200,
            _page([
              {..._branchItem(_branch), 'conversation_id': _id(9)},
            ]),
          ),
        ),
        _invalid,
      );
    });

    test('messages run from head toward root on one path', () async {
      final page = await _messages(
        _answer(
          200,
          _page([
            _message(_id(3), parent: _id(2), stopReason: 'limit'),
            _message(_id(2), parent: _id(1), stopReason: null),
            _message(
              _id(1),
              role: 'user',
              parts: [_text(_id(901), '<b>kept as text</b>')],
            ),
          ]),
        ),
      );
      expect([for (final m in page.items) m.id], [_id(3), _id(2), _id(1)]);
      expect(page.items.first.stopReason, 'limit');
      expect(page.items.first.runId, _id(800));
      expect(page.items.last.role, 'user');
      expect(page.items.last.parts.single.text, '<b>kept as text</b>');
      expect(page.historyAvailable, isTrue);
      expect(page.nextCursor, isNull);

      // A gap or reordering on the page is not one path.
      await expectLater(
        _messages(
          _answer(
            200,
            _page([_message(_id(3), parent: _id(2)), _message(_id(1))]),
          ),
        ),
        _invalid,
      );
    });

    test('a page that stops before the root carries a cursor', () async {
      final page = await _messages(
        _answer(
          200,
          _page([_message(_id(3), parent: _id(2))], next: _otherCursor),
        ),
        cursor: _cursor,
      );
      expect(page.items.single.id, _id(3));
      expect(page.nextCursor, _otherCursor);
    });

    test('parts: text, attachments and opaque unknown kinds', () async {
      final page = await _messages(
        _answer(
          200,
          _page([
            _message(
              _id(1),
              parts: [
                _text(_id(10), ''),
                {
                  'part_id': _id(11),
                  'kind': 'attachment',
                  'revision_id': _id(12),
                  'state': 'retained',
                },
                {
                  'part_id': _id(13),
                  'kind': 'future_kind',
                  'text': '<script>alert(1)</script>',
                  'state': 'future_state',
                  'payload': {'x': 1},
                },
              ],
            ),
          ]),
        ),
      );
      final [text, attachment, unknown] = page.items.single.parts;
      expect(text.kind, 'text');
      expect(text.text, '');
      expect(attachment.kind, 'attachment');
      expect(attachment.revisionId, _id(12));
      expect(attachment.state, 'retained');
      expect(attachment.text, isNull);
      // An unrecognized part keeps only its kind: no payload to render.
      expect(unknown.kind, 'future_kind');
      expect(unknown.text, isNull);
      expect(unknown.state, isNull);
      expect(unknown.revisionId, isNull);
    });

    test('a legacy branch reports unavailable history', () async {
      final page = await _messages(
        _answer(
          200,
          _page(const []),
          headers: {..._json, 'openmettle-history-available': 'false'},
        ),
      );
      expect(page.items, isEmpty);
      expect(page.nextCursor, isNull);
      expect(page.historyAvailable, isFalse);

      // A managed empty branch is available and empty.
      final empty = await _messages(_answer(200, _page(const [])));
      expect(empty.items, isEmpty);
      expect(empty.historyAvailable, isTrue);

      for (final (value, body) in [
        ('true', _page(const [])),
        ('False', _page(const [])),
        ('', _page(const [])),
        ('false', _page([_message(_id(1))])),
        ('false', _page([_message(_id(1))], next: _otherCursor)),
      ]) {
        await expectLater(
          _messages(
            _answer(
              200,
              body,
              headers: {..._json, 'openmettle-history-available': value},
            ),
          ),
          _invalid,
          reason: value,
        );
      }
    });
  });

  group('page bounds', () {
    test('no more items than requested', () async {
      final conversations = [
        for (var i = 0; i < 51; i++) _conversationItem(_id(i)),
      ];
      await expectLater(
        _conversations(_answer(200, _page(conversations))),
        _invalid,
      );
      final full = await _conversations(
        _answer(200, _page(conversations.sublist(1), next: _otherCursor)),
      );
      expect(full.items, hasLength(50));

      final messages = [
        for (var i = 0; i < 11; i++) _message(_id(i), parent: _id(i + 1)),
      ];
      await expectLater(_messages(_answer(200, _page(messages))), _invalid);
      final turns = await _messages(
        _answer(200, _page(messages.sublist(1), next: _otherCursor)),
      );
      expect(turns.items, hasLength(10));
    });

    test('an oversized body is invalid and aborts the request', () async {
      final transport = _serve(
        (request) async => StreamedReply(
          HttpReply(status: 200, url: request.url, headers: _json),
          Stream.fromIterable([
            for (var i = 0; i < 300; i++) List.filled(1024, 0x20),
          ]),
        ),
      );
      await expectLater(_client(transport).conversations(), _invalid);
      await pumpEventQueue();
      expect(transport.opened.single.cancelled, isTrue);
    });

    test('a continuation must make progress', () async {
      // The same cursor again, or a cursor after an empty page, would loop.
      await expectLater(
        _conversations(
          _answer(200, _page([_conversationItem(_id(1))], next: _cursor)),
          cursor: _cursor,
        ),
        _invalid,
      );
      await expectLater(
        _conversations(_answer(200, _page(const [], next: _otherCursor))),
        _invalid,
      );
    });
  });

  group('refusals and failures', () {
    test('verified refusals map to history failures', () async {
      for (final (status, code, failure) in [
        (401, 'unauthenticated', HistoryFailure.unauthenticated),
        (403, 'policy', HistoryFailure.inaccessible),
        (404, 'not_found', HistoryFailure.inaccessible),
      ]) {
        final answer = _answer(
          status,
          _problem(status, code),
          headers: _problemJson,
        );
        await expectLater(_conversations(answer), throwsA(failure));
        await expectLater(_branches(answer), throwsA(failure));
        await expectLater(_messages(answer), throwsA(failure));
      }
    });

    test('invalid_cursor is a cursor refusal only after a cursor', () async {
      final answer = _answer(
        400,
        _problem(400, 'invalid_cursor'),
        headers: _problemJson,
      );
      await expectLater(
        _messages(answer, cursor: _cursor),
        throwsA(HistoryFailure.invalidCursor),
      );
      await expectLater(_messages(answer), _invalid);
      await expectLater(
        _conversations(
          _answer(400, _problem(400, 'validation'), headers: _problemJson),
          cursor: _cursor,
        ),
        _invalid,
      );
    });

    test('temporary failures may be retried', () async {
      for (final status in [429, 500, 502, 503, 504]) {
        for (final headers in [const <String, String>{}, _v1]) {
          await expectLater(
            _conversations(_answer(status, '<html>', headers: headers)),
            throwsA(HistoryFailure.unavailable),
          );
        }
      }
      await expectLater(
        _conversations((_) async => throw const TransportFailure()),
        throwsA(HistoryFailure.unavailable),
      );
      await expectLater(
        _conversations(
          _answer(200, '{"items":', error: const TransportFailure()),
        ),
        throwsA(HistoryFailure.unavailable),
      );
    });

    testWidgets('the deadline covers a silent head', (tester) async {
      final head = Completer<StreamedReply>();
      final transport = _serve((_) => head.future);
      Object? failure;
      unawaited(
        _client(transport)
            .conversations()
            .then<void>((_) {}, onError: (Object error) => failure = error),
      );
      await tester.pump(const Duration(seconds: 29));
      expect(transport.opened.single.cancelled, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(transport.opened.single.cancelled, isTrue);
      // The aborted fetch fails without a head.
      head.completeError(const TransportFailure());
      await tester.pump();
      expect(failure, HistoryFailure.unavailable);
    });

    test('contract violations are invalid responses', () async {
      final page = _page(const []);
      final problem = _problem(404, 'not_found');
      for (final (name, answer) in [
        (
          'no version',
          _answer(
            200,
            page,
            headers: const {'content-type': 'application/json'},
          ),
        ),
        (
          'newer major',
          _answer(
            200,
            page,
            headers: {..._json, 'openmettle-api-version': '2.0'},
          ),
        ),
        (
          'bad version',
          _answer(
            200,
            page,
            headers: {..._json, 'openmettle-api-version': '1'},
          ),
        ),
        (
          'html',
          _answer(200, page, headers: {..._v1, 'content-type': 'text/html'}),
        ),
        ('redirected', _answer(200, page, redirected: true)),
        ('opaque redirect', _answer(0, '', type: 'opaqueredirect')),
        ('cors', _answer(200, page, type: 'cors')),
        ('other URL', _answer(200, page, url: Uri.parse('$origin/v1/other'))),
        ('redirect status', _answer(302, '', headers: _v1)),
        ('bom', _answer(200, '﻿$page')),
        ('not json', _answer(200, '{')),
        ('array root', _answer(200, '[]')),
        ('no items', _answer(200, '{"page_info":{"next_cursor":null}}')),
        ('no page_info', _answer(200, '{"items":[]}')),
        ('no next_cursor', _answer(200, '{"items":[],"page_info":{}}')),
        (
          'bad cursor',
          _answer(200, _page([_conversationItem(_id(1))], next: 'a/b')),
        ),
        ('status-only 404', _answer(404, '', headers: const {})),
        ('problem as json', _answer(404, problem, headers: _json)),
        (
          'unversioned problem',
          _answer(
            404,
            problem,
            headers: const {'content-type': 'application/problem+json'},
          ),
        ),
        (
          'status mismatch',
          _answer(404, _problem(403, 'policy'), headers: _problemJson),
        ),
        (
          'unknown code',
          _answer(403, _problem(403, 'future_code'), headers: _problemJson),
        ),
        (
          'code for other status',
          _answer(404, _problem(404, 'policy'), headers: _problemJson),
        ),
        (
          '400 validation',
          _answer(400, _problem(400, 'validation'), headers: _problemJson),
        ),
      ]) {
        await expectLater(_conversations(answer), _invalid, reason: name);
      }
    });

    test('invalid items are invalid responses', () async {
      final conversation = _conversationItem(_id(1));
      for (final item in [
        {...conversation, 'conversation_id': _id(1).toUpperCase()},
        {...conversation, 'scope_kind': 'Personal'},
        {...conversation, 'scope_kind': 'project', 'project_id': _id(9)},
        {...conversation, 'scope_kind': 'future_scope'},
        {...conversation, 'project_id': _id(9)},
        {...conversation, 'access': null},
        {...conversation, 'project_id': 'x'},
        _without(conversation, 'project_id'),
        {...conversation, 'created_at': '2026-11-20T09:00:01Z'},
        {...conversation, 'can_manage_shares': 'true'},
        'not an object',
      ]) {
        await expectLater(
          _conversations(_answer(200, _page([item]))),
          _invalid,
          reason: '$item',
        );
      }
      await expectLater(
        _conversations(_answer(200, _page([conversation, conversation]))),
        _invalid,
      );

      final branch = _branchItem(_branch);
      for (final item in [
        _without(branch, 'parent_branch_id'),
        _without(branch, 'fork_message_id'),
        _without(branch, 'head_message_id'),
        {...branch, 'history_available': null},
        {...branch, 'head_message_id': 'x'},
      ]) {
        await expectLater(
          _branches(_answer(200, _page([item]))),
          _invalid,
          reason: '$item',
        );
      }

      final message = _message(_id(1));
      final text = _text(_id(2), 'x');
      for (final item in [
        _without(message, 'parent_message_id'),
        _without(message, 'run_id'),
        _without(message, 'input_count'),
        {...message, 'role': ''},
        {...message, 'role': 'r' * 257},
        {...message, 'input_count': '01'},
        {...message, 'output_count': '9223372036854775808'},
        {...message, 'output_count': 12},
        {...message, 'stop_reason': 'Limit'},
        {...message, 'stop_reason': 123},
        _message(_id(1), role: 'user', stopReason: 'limit'),
        {...message, 'parts': null},
        {
          ...message,
          'parts': [for (var i = 0; i < 129; i++) _text(_id(100 + i), 'x')],
        },
        {
          ...message,
          'parts': [text, text],
        },
        {
          ...message,
          'parts': [_without(text, 'text')],
        },
        {
          ...message,
          'parts': [
            {...text, 'text': 'x' * 65537},
          ],
        },
        {
          ...message,
          'parts': [
            {'part_id': _id(2), 'kind': 'attachment', 'state': 'active'},
          ],
        },
        {
          ...message,
          'parts': [
            {'part_id': _id(2), 'kind': 'future', 'revision_id': 'x'},
          ],
        },
        {
          ...message,
          'parts': [
            {'part_id': _id(2), 'kind': ''},
          ],
        },
      ]) {
        await expectLater(
          _messages(_answer(200, _page([item]))),
          _invalid,
          reason: '$item',
        );
      }
      await expectLater(
        _messages(_answer(200, _page([message, message]))),
        _invalid,
      );
    });

    test('limits count code points, not UTF-16 units', () async {
      // 65,536 astral characters are 131,072 UTF-16 units.
      final wide = '\u{1F600}' * 65536;
      final page = await _messages(
        _answer(
          200,
          _page([
            _message(_id(1), parts: [_text(_id(2), wide)], stopReason: null),
          ]),
        ),
      );
      expect(page.items.single.parts.single.text, wide);
      expect(page.items.single.stopReason, isNull);
      // An absent stop_reason is accepted from older cores.
      final older = await _messages(
        _answer(200, _page([_without(_message(_id(1)), 'stop_reason')])),
      );
      expect(older.items.single.stopReason, isNull);
    });
  });
}

Map<String, Object?> _without(Map<String, Object?> item, String key) =>
    Map.of(item)..remove(key);

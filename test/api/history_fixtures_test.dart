@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/src/http_run_client.dart';
import 'package:openmettle_app/api/src/http_session_client.dart';
import 'package:openmettle_app/api/src/transport.dart';
import 'package:openmettle_app/conversations/history.dart';

import 'fake_transport.dart';

/// Core history fixtures copied unmodified from the commit in MANIFEST.
final _root = Directory('test/fixtures/history');

const _conversationId = '0f0e0d0c-0b0a-4908-8706-050403020100';
const _branchId = '0f0e0d0c-0b0a-4908-8706-050403020101';

List<String> _manifest() =>
    File('${_root.path}/MANIFEST')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();

Map<String, Object?> _fixture(String path) =>
    jsonDecode(File('${_root.path}/$path').readAsStringSync())
        as Map<String, Object?>;

/// Reads the fixture instance as a `200` through the web client operation
/// that returns its schema.
Future<HistoryPage<Object>> _read(Map<String, Object?> fixture) {
  final body = utf8.encode(jsonEncode(fixture['instance']));
  final transport = FakeStreamingTransport(
    (request) async => StreamedReply(
      HttpReply(
        status: 200,
        url: request.url,
        headers: const {
          'content-type': 'application/json',
          'openmettle-api-version': '1.0',
        },
      ),
      Stream.value(body),
    ),
  );
  final client = sessionClientFor(
    transport,
    login: '/auth/login',
    session: '/auth/session',
    logout: '/auth/logout',
  ) as HttpRunSessionClient;
  return switch (fixture['schema']) {
    '#/components/schemas/ConversationPage' => client.conversations(),
    '#/components/schemas/BranchPage' => client.branches(_conversationId),
    '#/components/schemas/MessagePage' => client.messages(
      _conversationId,
      _branchId,
    ),
    final schema => throw StateError('unexpected schema $schema'),
  };
}

void main() {
  final manifest = _manifest();

  test('the manifest pins a core commit and lists every fixture', () {
    expect(manifest.first, matches(RegExp(r'^[0-9a-f]{40}$')));
    final listed = manifest.skip(1).toSet();
    final present = _root
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => f.path.substring(_root.path.length + 1))
        .where((p) => p != 'MANIFEST')
        .toSet();
    expect(present, listed);
  });

  for (final path in manifest.skip(1)) {
    test(path, () async {
      final fixture = _fixture(path);
      final valid = (fixture['expect']! as Map)['valid'] as bool;
      expect(path.startsWith('invalid/'), !valid);
      // Core’s valid conversation examples describe a project. The personal
      // collection must refuse these otherwise well-formed responses.
      final projectExample =
          fixture['schema'] == '#/components/schemas/ConversationPage';
      if (valid && !projectExample) {
        final page = await _read(fixture);
        expect(page.items, hasLength(1));
        expect(page.nextCursor, isNull);
        expect(page.historyAvailable, isTrue);
      } else {
        await expectLater(
          _read(fixture),
          throwsA(HistoryFailure.invalidResponse),
        );
      }
    });
  }

  test('valid fixtures decode to their documented values', () async {
    final branch =
        (await _read(_fixture('valid/VisibleBranchPage.json'))).items.single
            as BranchSummary;
    expect(branch.id, '0f0e0d0c-0b0a-4908-8706-050403020101');
    expect(branch.parentBranchId, isNull);
    expect(branch.historyAvailable, isTrue);

    final question =
        (await _read(_fixture('valid/VisibleMessagePage.json'))).items.single
            as HistoryMessage;
    expect(question.role, 'user');
    expect(question.runId, isNull);
    expect(question.stopReason, isNull);
    expect(question.parts.single.kind, 'text');
    expect(question.parts.single.text, 'Example question.');

    final limited =
        (await _read(
              _fixture('valid/VisibleMessagePage--assistant-limit-stop.json'),
            )).items.single
            as HistoryMessage;
    expect(limited.role, 'assistant');
    expect(limited.runId, '0f0e0d0c-0b0a-4908-8706-050403020105');
    expect(limited.stopReason, 'limit');

    // An open vocabulary value is kept verbatim, not rejected.
    final future =
        (await _read(
              _fixture(
                'compat/VisibleMessagePage--unrecognized-stop-reason.json',
              ),
            )).items.single
            as HistoryMessage;
    expect(future.stopReason, 'future_stop_reason');
  });
}

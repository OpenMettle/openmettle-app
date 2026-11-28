import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/api/src/http_session_client.dart';

import 'fake_transport.dart';

/// Core consumer fixtures copied unmodified from the commit in MANIFEST.
final _root = Directory('test/fixtures/core');

List<String> _manifest() =>
    File('${_root.path}/MANIFEST')
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();

Map<String, Object?> _fixture(String path) =>
    jsonDecode(File('${_root.path}/$path').readAsStringSync())
        as Map<String, Object?>;

SessionClient _client(FakeTransport transport) => sessionClientFor(
  transport,
  login: '/auth/login',
  session: '/auth/session',
  logout: '/auth/logout',
);

Future<List<Capability>> _capabilities(
  String body, {
  String? version = '1.0',
}) => _client(FakeTransport(api(200, body, version: version))).capabilities();

Future<void> _unauthenticated(String body) => _client(
  FakeTransport(api(401, body, contentType: 'application/problem+json')),
).capabilities();

Matcher _failure(ApiFailureKind kind) =>
    isA<ApiFailure>().having((f) => f.kind, 'kind', kind);

const _coreOnly =
    '{"capabilities":[],"generated_at":"2026-11-17T09:00:00.000000Z"}';

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

  for (final path in paths) {
    final fixture = _fixture(path);
    final valid = (fixture['expect']! as Map<String, Object?>)['valid'] == true;
    final instance = fixture['instance'];
    final description = '$path is ${valid ? 'accepted' : 'refused'}';
    switch (fixture['schema']) {
      case '#/components/schemas/CapabilityList':
        test(description, () async {
          final call = _capabilities(jsonEncode(instance));
          if (valid) {
            await expectLater(call, completes);
          } else {
            await expectLater(
              call,
              throwsA(_failure(ApiFailureKind.badResponse)),
            );
          }
        });
      case '#/components/schemas/ApiVersion':
        test(description, () async {
          final call = _capabilities(_coreOnly, version: instance! as String);
          if (valid) {
            await expectLater(call, completion(isEmpty));
          } else {
            // A well-formed other major is refused explicitly (ADR 0007).
            final unsupported =
                fixture['fixture'] == 'ApiVersionCurrent--unsupported-major';
            await expectLater(
              call,
              throwsA(
                _failure(
                  unsupported
                      ? ApiFailureKind.unsupportedVersion
                      : ApiFailureKind.badResponse,
                ),
              ),
            );
          }
        });
      case '#/components/schemas/Problem':
        test(description, () async {
          final call = _unauthenticated(jsonEncode(instance));
          await expectLater(
            call,
            throwsA(
              valid
                  ? isA<SessionExpired>()
                  : _failure(ApiFailureKind.badResponse),
            ),
          );
        });
      default:
        test('$path has a handled schema', () => fail('${fixture['schema']}'));
    }
  }

  test('CapabilitiesMixed keeps every dimension independent', () async {
    final body = jsonEncode(
      _fixture('valid/CapabilitiesMixed.json')['instance'],
    );
    expect(await _capabilities(body), const [
      Capability(
        id: 'chat.completions',
        kind: 'inference',
        installed: true,
        authorization: true,
        readiness: 'ready',
      ),
      Capability(
        id: 'search.web',
        kind: 'tool',
        installed: true,
        authorization: false,
        readiness: 'unavailable',
      ),
      Capability(
        id: 'media.image',
        kind: 'media',
        installed: false,
        authorization: null,
      ),
      Capability(
        id: 'memory.graph',
        kind: 'memory',
        installed: true,
        authorization: null,
        readiness: 'unknown',
      ),
      Capability(
        id: 'retrieval.rerank',
        kind: 'retrieval',
        installed: true,
        authorization: true,
        readiness: 'degraded',
      ),
    ]);
  });

  test('a core-only installation is an empty list', () async {
    final body = jsonEncode(
      _fixture('valid/CapabilitiesCoreOnly.json')['instance'],
    );
    expect(await _capabilities(body), isEmpty);
  });

  test('unrecognized kind and readiness are kept verbatim', () async {
    final kind = await _capabilities(
      jsonEncode(
        _fixture(
          'compat/CapabilitiesMixed--unrecognized-kind.json',
        )['instance'],
      ),
    );
    expect(kind.first.kind, 'hologram');
    final state = await _capabilities(
      jsonEncode(
        _fixture(
          'compat/CapabilitiesMixed--unrecognized-readiness-state.json',
        )['instance'],
      ),
    );
    expect(state.first.readiness, 'warming');
    expect(state.first.authorization, isTrue);
  });
}

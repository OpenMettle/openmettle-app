import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/api/src/http_session_client.dart';
import 'package:openmettle_app/api/src/transport.dart';

import 'fake_transport.dart';

SessionClient _client(FakeTransport transport) => sessionClientFor(
  transport,
  login: '/auth/login',
  session: '/auth/session',
  logout: '/auth/logout',
);

Matcher _failure(ApiFailureKind kind, [int? status]) => isA<ApiFailure>()
    .having((f) => f.kind, 'kind', kind)
    .having((f) => f.status, 'status', status);

HttpReply _lost(SentRequest _) => throw const TransportFailure();

HttpReply Function(SentRequest) _opaqueRedirect() =>
    (request) => HttpReply(status: 0, url: request.url, type: 'opaqueredirect');

HttpReply Function(SentRequest) _from(String url, int status) =>
    (request) => HttpReply(status: status, url: Uri.parse(url));

const _html = {'content-type': 'text/html'};

const _problem = {
  'type': 'about:blank',
  'title': 'Unauthorized',
  'status': 401,
  'code': 'unauthenticated',
  'request_id': 'a3e1c0d9-8b7f-4e6d-9c5b-4a3f2e1d0c9b',
};

String _problemWith(Map<String, Object?> changes) =>
    jsonEncode({..._problem, ...changes});

String _capability(String id) =>
    '{"id":"$id","kind":"tool","installed":false,"authorization":null}';

String _list(List<String> items, {String at = '2026-11-17T09:00:00.000000Z'}) =>
    '{"generated_at":"$at","capabilities":[${items.join(',')}]}';

void main() {
  group('checkSession', () {
    Future<bool> check(HttpReply Function(SentRequest) respond) =>
        _client(FakeTransport(respond)).checkSession();

    test('sends one same-origin GET to the session path', () async {
      final transport = FakeTransport(reply(204));
      expect(await _client(transport).checkSession(), isTrue);
      expect(transport.sent, [(method: 'GET', url: sessionUrl, accept: null)]);
    });

    test('a valid session is an empty 204', () async {
      expect(await check(reply(204)), isTrue);
      await expectLater(
        check(reply(204, body: 'x')),
        throwsA(_failure(ApiFailureKind.badResponse, 204)),
      );
    });

    test('an invalid or expired session is signed out', () async {
      expect(await check(line(403, 'session not valid')), isFalse);
    });

    test('a refused origin is not mistaken for a signed-out session', () async {
      await expectLater(
        check(line(403, 'session origin refused')),
        throwsA(_failure(ApiFailureKind.originRefused, 403)),
      );
    });

    test('a 403 that is not a core fixed line is a bad response', () async {
      for (final respond in [
        reply(403, headers: _html, body: '<h1>Forbidden</h1>'),
        reply(403, headers: _html, body: 'session not valid\n'),
        reply(
          403,
          headers: const {'content-type': 'text/plain'},
          body: 'session not valid',
        ),
        line(403, 'logout origin refused'),
        reply(403),
      ]) {
        await expectLater(
          check(respond),
          throwsA(_failure(ApiFailureKind.badResponse, 403)),
        );
      }
    });

    test(
      'rate limits and server or gateway failures are unavailable',
      () async {
        for (final status in [429, 500, 502, 503, 504]) {
          await expectLater(
            check(line(status, 'session unavailable; try again later')),
            throwsA(_failure(ApiFailureKind.unavailable, status)),
          );
        }
        await expectLater(
          check(reply(502, headers: _html, body: '<h1>Bad Gateway</h1>')),
          throwsA(_failure(ApiFailureKind.unavailable, 502)),
        );
      },
    );

    test('a lost response is unavailable, never signed out', () async {
      await expectLater(
        check(_lost),
        throwsA(_failure(ApiFailureKind.unavailable)),
      );
    });

    test('other statuses are bad responses', () async {
      for (final status in [200, 401, 404, 405, 413, 414, 431]) {
        await expectLater(
          check(reply(status)),
          throwsA(_failure(ApiFailureKind.badResponse, status)),
        );
      }
    });

    test('redirects and responses from another URL are refused', () async {
      await expectLater(
        check(_opaqueRedirect()),
        throwsA(_failure(ApiFailureKind.badResponse)),
      );
      await expectLater(
        check(_from('https://elsewhere.example.test/auth/session', 204)),
        throwsA(_failure(ApiFailureKind.badResponse, 204)),
      );
      await expectLater(
        check((r) => HttpReply(status: 204, url: r.url, redirected: true)),
        throwsA(_failure(ApiFailureKind.badResponse, 204)),
      );
      await expectLater(
        check((r) => HttpReply(status: 204, url: r.url, type: 'cors')),
        throwsA(_failure(ApiFailureKind.badResponse, 204)),
      );
    });
  });

  group('signIn', () {
    test(
      'submits a top-level form to the login path and sends nothing',
      () async {
        final transport = FakeTransport(_lost);
        await _client(transport).signIn();
        expect(transport.submitted, [loginUrl]);
        expect(transport.sent, isEmpty);
      },
    );
  });

  group('signOut', () {
    Future<void> logout(HttpReply Function(SentRequest) respond) =>
        _client(FakeTransport(respond)).signOut();

    test('an acknowledged logout is a POST answered with 204', () async {
      final transport = FakeTransport(reply(204));
      await _client(transport).signOut();
      expect(transport.sent, [(method: 'POST', url: logoutUrl, accept: null)]);
    });

    test('an already invalid session is SessionExpired', () async {
      await expectLater(
        logout(line(403, 'session not valid')),
        throwsA(isA<SessionExpired>()),
      );
    });

    test('a refused origin is reported, not treated as signed out', () async {
      await expectLater(
        logout(line(403, 'logout origin refused')),
        throwsA(_failure(ApiFailureKind.originRefused, 403)),
      );
    });

    test('a rate-limited logout revoked nothing', () async {
      await expectLater(
        logout(line(429, 'session rate limit reached; try again later')),
        throwsA(_failure(ApiFailureKind.unavailable, 429)),
      );
    });

    test('a 503 after an uncertain commit is uncertain', () async {
      await expectLater(
        logout(line(503, 'session unavailable; try again later')),
        throwsA(_failure(ApiFailureKind.signOutUncertain, 503)),
      );
    });

    test('a lost response is uncertain', () async {
      await expectLater(
        logout(_lost),
        throwsA(_failure(ApiFailureKind.signOutUncertain)),
      );
    });

    test('gateway errors and unrecognized answers are uncertain', () async {
      for (final status in [200, 400, 404, 500, 502, 504]) {
        await expectLater(
          logout(reply(status, headers: _html, body: '<p>x</p>')),
          throwsA(_failure(ApiFailureKind.signOutUncertain, status)),
        );
      }
      await expectLater(
        logout(reply(403, headers: _html, body: '<h1>Forbidden</h1>')),
        throwsA(_failure(ApiFailureKind.signOutUncertain, 403)),
      );
    });

    test('a redirect or another URL never confirms sign-out', () async {
      await expectLater(
        logout(_opaqueRedirect()),
        throwsA(_failure(ApiFailureKind.signOutUncertain)),
      );
      await expectLater(
        logout(_from('https://elsewhere.example.test/auth/logout', 204)),
        throwsA(_failure(ApiFailureKind.signOutUncertain, 204)),
      );
    });
  });

  group('capabilities', () {
    Future<List<Capability>> read(HttpReply Function(SentRequest) respond) =>
        _client(FakeTransport(respond)).capabilities();

    test('sends one same-origin GET accepting JSON', () async {
      final transport = FakeTransport(api(200, _list([])));
      expect(await _client(transport).capabilities(), isEmpty);
      expect(transport.sent, [
        (method: 'GET', url: capabilitiesUrl, accept: 'application/json'),
      ]);
    });

    test('signed in: decodes the list', () async {
      final list = await read(api(200, _list([_capability('search.web')])));
      expect(list, const [
        Capability(
          id: 'search.web',
          kind: 'tool',
          installed: false,
          authorization: null,
        ),
      ]);
    });

    test('accepts any newer minor and charset=utf-8', () async {
      await expectLater(
        read(
          api(
            200,
            _list([]),
            version: '1.7',
            contentType: 'Application/JSON; charset=UTF-8',
          ),
        ),
        completion(isEmpty),
      );
    });

    test('expired: a 401 unauthenticated problem is SessionExpired', () async {
      await expectLater(
        read(
          api(
            401,
            jsonEncode(_problem),
            contentType: 'application/problem+json',
          ),
        ),
        throwsA(isA<SessionExpired>()),
      );
    });

    test(
      'a 401 that is not a core unauthenticated problem is refused',
      () async {
        for (final respond in [
          api(401, jsonEncode(_problem), contentType: 'application/json'),
          api(
            401,
            jsonEncode(_problem),
            contentType: 'application/problem+json',
            version: null,
          ),
          reply(401, headers: _html, body: '<h1>Unauthorized</h1>'),
          api(
            401,
            _problemWith({'code': 'policy'}),
            contentType: 'application/problem+json',
          ),
          api(
            401,
            _problemWith({'status': 403}),
            contentType: 'application/problem+json',
          ),
          api(
            401,
            _problemWith({'request_id': 'not-a-uuid'}),
            contentType: 'application/problem+json',
          ),
          api(401, 'not json', contentType: 'application/problem+json'),
        ]) {
          await expectLater(
            read(respond),
            throwsA(_failure(ApiFailureKind.badResponse, 401)),
          );
        }
      },
    );

    test('an unsupported major is refused before decoding', () async {
      await expectLater(
        read(api(200, _list([]), version: '2.0')),
        throwsA(_failure(ApiFailureKind.unsupportedVersion, 200)),
      );
      await expectLater(
        read(api(503, '{}', version: '2.0')),
        throwsA(_failure(ApiFailureKind.unsupportedVersion, 503)),
      );
    });

    test(
      'a missing, malformed or repeated version header is refused',
      () async {
        for (final version in [null, '1', '1.01', '01.0', '1.0, 1.0', 'v1.0']) {
          await expectLater(
            read(api(200, _list([]), version: version)),
            throwsA(_failure(ApiFailureKind.badResponse, 200)),
          );
        }
      },
    );

    test('a wrong media type is refused', () async {
      for (final type in [
        'text/html',
        'application/problem+json',
        'application/json; charset=latin1',
        'application/json; charset=utf-8; x=y',
      ]) {
        await expectLater(
          read(api(200, _list([]), contentType: type)),
          throwsA(_failure(ApiFailureKind.badResponse, 200)),
        );
      }
    });

    test('bad gateway and other transient failures are unavailable', () async {
      await expectLater(
        read(reply(502, headers: _html, body: '<h1>Bad Gateway</h1>')),
        throwsA(_failure(ApiFailureKind.unavailable, 502)),
      );
      for (final status in [429, 500, 503, 504]) {
        await expectLater(
          read(api(status, '{}', contentType: 'application/problem+json')),
          throwsA(_failure(ApiFailureKind.unavailable, status)),
        );
      }
      await expectLater(
        read(_lost),
        throwsA(_failure(ApiFailureKind.unavailable)),
      );
    });

    test('unexpected statuses are bad responses', () async {
      for (final status in [204, 400, 403, 404]) {
        await expectLater(
          read(api(status, '{}', contentType: 'application/problem+json')),
          throwsA(_failure(ApiFailureKind.badResponse, status)),
        );
      }
    });

    test('redirects and responses from another URL are refused', () async {
      await expectLater(
        read(_opaqueRedirect()),
        throwsA(_failure(ApiFailureKind.badResponse)),
      );
      await expectLater(
        read(_from('https://elsewhere.example.test/v1/capabilities', 200)),
        throwsA(_failure(ApiFailureKind.badResponse, 200)),
      );
    });

    test('structural violations are refused', () async {
      final tooMany = [for (var i = 0; i < 257; i++) _capability('c$i')];
      for (final body in [
        'not json',
        '[]',
        _list([_capability('a'), _capability('a')]),
        _list(tooMany),
        _list([], at: '2026-02-30T09:00:00.000000Z'),
        _list([], at: '2026-11-17T24:00:00.000000Z'),
        _list([
          '{"id":"a","kind":"Tool","installed":false,"authorization":null}',
        ]),
        _list([
          '{"id":"a","kind":"tool","installed":true,"authorization":true,'
              '"readiness":{"state":"unknown","reason":"Bad"}}',
        ]),
        _list([
          '{"id":"a","kind":"tool","installed":true,"authorization":true,'
              '"readiness":"ready"}',
        ]),
      ]) {
        await expectLater(
          read(api(200, body)),
          throwsA(_failure(ApiFailureKind.badResponse, 200)),
          reason: body.length > 80 ? body.substring(0, 80) : body,
        );
      }
    });

    test(
      'the maximum list size and an unknown readiness are accepted',
      () async {
        final most = [for (var i = 0; i < 256; i++) _capability('c$i')];
        expect(await read(api(200, _list(most))), hasLength(256));
        final unknown = await read(
          api(
            200,
            _list([
              '{"id":"a","kind":"tool","installed":true,"authorization":false,'
                  '"readiness":{"state":"unknown"}}',
            ]),
          ),
        );
        expect(unknown.single.readiness, 'unknown');
        expect(unknown.single.authorization, isFalse);
      },
    );
  });

  group('configuration', () {
    test('a non-HTTPS page or an unplain path sends nothing', () async {
      final configurations = [
        (origin: 'http://app.example.test', login: '/auth/login'),
        (origin: 'https://app.example.test', login: 'https://evil.test/x'),
        (origin: 'https://app.example.test', login: '//evil.test/x'),
        (origin: 'https://app.example.test', login: '/auth/session'),
        (origin: 'https://app.example.test', login: '/v1/login'),
      ];
      for (final c in configurations) {
        final transport = FakeTransport(reply(204), origin: c.origin);
        final client = sessionClientFor(
          transport,
          login: c.login,
          session: '/auth/session',
          logout: '/auth/logout',
        );
        final configuration = throwsA(_failure(ApiFailureKind.configuration));
        await expectLater(client.checkSession(), configuration);
        await expectLater(client.signIn(), configuration);
        await expectLater(client.signOut(), configuration);
        await expectLater(client.capabilities(), configuration);
        expect(transport.sent, isEmpty);
        expect(transport.submitted, isEmpty);
      }
    });
  });
}

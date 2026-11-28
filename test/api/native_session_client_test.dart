import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/client.dart';
import 'package:openmettle_app/api/src/native_profile.dart';
import 'package:openmettle_app/api/src/native_session_client.dart';
import 'package:openmettle_app/api/src/transport.dart';

const _issuer = 'https://api.example.test:8443';
const _id = 'example-android';
const _redirect = 'https://links.example.test/android/complete';
const _start = '/auth/native/authorize';
const _token = '/auth/native/token';
const _session = '/auth/native/session';
const _logout = '/auth/native/logout';
const _capabilities = '/v1/capabilities';

String _value(int n) => base64UrlEncode(List.filled(32, n)).replaceAll('=', '');

final _bearer = '${_value(5)}.${_value(6)}';
final _profile = NativeProfile.parse(_issuer, _id, _redirect)!;

typedef _Request = ({
  String method,
  Uri url,
  String? accept,
  String? bearer,
  String? jsonBody,
});

class _Platform implements NativeAuthPlatform {
  final secrets = <String, String>{};
  String? link;
  Uri? browser;
  int attempts = 0;
  Object? launchFailure;
  String? refusedRead;
  bool refuseAttemptDeletion = false;

  @override
  Stream<void> get linkAvailable => const Stream.empty();

  @override
  Future<({String state, String verifier, String challenge})>
  newAttempt() async {
    attempts++;
    return (state: _value(attempts), verifier: _value(7), challenge: _value(8));
  }

  @override
  Future<String?> readSecret(String key) async {
    if (key == refusedRead) throw StateError('storage unavailable');
    return secrets[key];
  }

  @override
  Future<void> writeSecret(String key, String? value) async {
    if (value == null) {
      if (key == 'attempt' && refuseAttemptDeletion)
        throw StateError('storage unavailable');
      secrets.remove(key);
    } else {
      secrets[key] = value;
    }
  }

  @override
  Future<void> launchBrowser(Uri url) async {
    expect(secrets['attempt'], isNotNull);
    if (launchFailure case final error?) throw error;
    browser = url;
  }

  @override
  Future<String?> takeLink() async {
    final pending = link;
    link = null;
    return pending;
  }

  String callback({String? issuer, String? state, String? redirect}) =>
      Uri.parse(redirect ?? _redirect)
          .replace(
            queryParameters: {
              'code': _value(9),
              'state': state ?? browser!.queryParameters['state'],
              'iss': issuer ?? _issuer,
            },
          )
          .toString();
}

class _Transport implements NativeTransport {
  final requests = <_Request>[];
  FutureOr<HttpReply> Function(_Request) respond = _response;

  @override
  Future<HttpReply> send(
    String method,
    Uri url, {
    String? accept,
    String? bearer,
    String? jsonBody,
  }) async {
    final request = (
      method: method,
      url: url,
      accept: accept,
      bearer: bearer,
      jsonBody: jsonBody,
    );
    requests.add(request);
    return respond(request);
  }
}

HttpReply _response(_Request request) => switch (request.url.path) {
  _token => HttpReply(
    status: 200,
    url: request.url,
    headers: {'content-type': 'application/json'},
    body: jsonEncode({'token_type': 'Bearer', 'access_token': _bearer}),
  ),
  _session || _logout => HttpReply(status: 204, url: request.url),
  _capabilities => HttpReply(
    status: 200,
    url: request.url,
    headers: {
      'content-type': 'application/json',
      'openmettle-api-version': '1.0',
    },
    body: '{"generated_at":"2026-01-01T00:00:00.000000Z","capabilities":[]}',
  ),
  _ => throw StateError('Unexpected request'),
};

Matcher _failure(ApiFailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  late _Platform platform;
  late _Transport transport;
  late NativeSessionClient client;

  setUp(() {
    platform = _Platform();
    transport = _Transport();
    client = NativeSessionClient(_profile, platform, transport);
  });

  test('fails closed before touching the platform or network', () async {
    for (final values in [
      ('', _id, _redirect),
      ('http://api.example.test', _id, _redirect),
      ('$_issuer/', _id, _redirect),
      (_issuer, '', _redirect),
      (_issuer, '$_id\n', _redirect),
      (_issuer, _id, ''),
      (_issuer, _id, '$_redirect?'),
      (_issuer, _id, '$_redirect#'),
      (_issuer, _id, 'https://links.example.test:8443/android/complete'),
      (_issuer, _id, 'https://links.example.test/x/../android/complete'),
      (_issuer, _id, 'https://user@links.example.test/android/complete'),
    ]) {
      expect(NativeProfile.parse(values.$1, values.$2, values.$3), isNull);
    }
    final unavailable = NativeSessionClient(null, platform, transport);
    for (final operation in [
      unavailable.checkSession,
      unavailable.signIn,
      unavailable.signOut,
      unavailable.capabilities,
    ]) {
      await expectLater(
        operation(),
        throwsA(_failure(ApiFailureKind.configuration)),
      );
    }
    expect(platform.secrets, isEmpty);
    expect(platform.attempts, 0);
    expect(transport.requests, isEmpty);
  });

  test(
    'clears a failed browser launch and discards raw platform error',
    () async {
      platform.launchFailure = StateError('synthetic platform detail');
      await expectLater(
        client.signIn(),
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.toString(),
            'diagnostic',
            'ApiFailure(unavailable)',
          ),
        ),
      );
      expect(platform.secrets, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test('persists before opening and completes from cold start', () async {
    await client.signIn();
    final browser = platform.browser!;
    expect(browser.origin, _issuer);
    expect(browser.path, _start);
    expect(browser.queryParameters, {
      'response_type': 'code',
      'client_id': _id,
      'redirect_uri': _redirect,
      'code_challenge_method': 'S256',
      'code_challenge': _value(8),
      'state': _value(1),
    });

    platform.link = platform.callback();
    transport.respond = (request) {
      if (request.url.path == _token) {
        expect(platform.secrets['attempt'], isNull);
      }
      return _response(request);
    };
    final restarted = NativeSessionClient(_profile, platform, transport);
    expect(await restarted.checkSession(), isTrue);
    expect(await restarted.capabilities(), isEmpty);
    expect(transport.requests.map((request) => request.url.path), [
      _token,
      _session,
      _capabilities,
    ]);
    final exchange = transport.requests.first;
    expect(exchange.method, 'POST');
    expect(exchange.bearer, isNull);
    expect(jsonDecode(exchange.jsonBody!), {
      ..._profile.binding,
      'grant_type': 'authorization_code',
      'code': _value(9),
      'code_verifier': _value(7),
    });
    for (final request in transport.requests.skip(1)) {
      expect(request.jsonBody, isNull);
      expect(request.bearer, _bearer);
      expect(request.url.origin, _issuer);
    }
  });

  test(
    'rejects stale and malformed links without consuming a new attempt',
    () async {
      await client.signIn();
      final stale = platform.callback();
      await client.signIn();
      final valid = platform.callback();
      for (final link in [
        stale,
        platform.callback(issuer: 'https://foreign.example.test'),
        platform.callback(
          redirect: 'https://foreign.example.test/android/complete',
        ),
        platform.callback(redirect: '$_redirect/'),
        '$valid#fragment',
        '$valid&state=${_value(2)}',
        '$valid&other=1',
        valid.replaceFirst('code=${_value(9)}', 'code=%FF'),
      ]) {
        platform.link = link;
        expect(await client.checkSession(), isFalse);
        expect(platform.secrets['attempt'], isNotNull);
      }
      expect(transport.requests, isEmpty);
      platform.link = valid;
      expect(await client.checkSession(), isTrue);
    },
  );

  test(
    'expires pending attempts locally without contacting the issuer',
    () async {
      final created = DateTime.utc(2026);
      final start = NativeSessionClient(
        _profile,
        platform,
        transport,
        clock: () => created,
      );
      await start.signIn();
      platform.link = platform.callback();
      final resumed = NativeSessionClient(
        _profile,
        platform,
        transport,
        clock: () => created.add(const Duration(minutes: 10)),
      );
      expect(await resumed.checkSession(), isFalse);
      expect(platform.secrets, isEmpty);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'keeps the link across transient storage failures before exchange',
    () async {
      await client.signIn();
      platform.link = platform.callback();
      for (final key in ['session', 'attempt']) {
        platform.refusedRead = key;
        await expectLater(
          client.checkSession(),
          throwsA(_failure(ApiFailureKind.unavailable)),
        );
      }
      platform.refusedRead = null;
      platform.refuseAttemptDeletion = true;
      await expectLater(
        client.checkSession(),
        throwsA(_failure(ApiFailureKind.unavailable)),
      );
      expect(transport.requests, isEmpty);
      platform.refuseAttemptDeletion = false;
      expect(await client.checkSession(), isTrue);
      expect(transport.requests.map((r) => r.url.path), [_token, _session]);
    },
  );

  test('does not reuse an attempt after an uncertain exchange', () async {
    await client.signIn();
    final link = platform.callback();
    platform.link = link;
    transport.respond = (_) => throw const TransportFailure();
    await expectLater(
      client.checkSession(),
      throwsA(_failure(ApiFailureKind.unavailable)),
    );
    expect(platform.secrets, isEmpty);
    platform.link = link;
    expect(await client.checkSession(), isFalse);
    expect(transport.requests.length, 1);
  });

  test(
    'serializes redemption and logout and discards callback replays',
    () async {
      await client.signIn();
      final link = platform.callback();
      platform.link = link;
      final requested = Completer<_Request>();
      final exchange = Completer<HttpReply>();
      transport.respond = (request) {
        if (request.url.path != _token) return _response(request);
        requested.complete(request);
        return exchange.future;
      };
      final checking = client.checkSession();
      final request = await requested.future;
      final logout = client.signOut();
      platform.link = link;
      final callback = client.checkSession();
      exchange.complete(_response(request));
      expect(await checking, isTrue);
      await logout;
      expect(await callback, isFalse);
      expect(platform.secrets, isEmpty);
      expect(transport.requests.map((item) => item.url.path), [
        _token,
        _session,
        _logout,
      ]);
    },
  );

  test('lost logout response fences the stored bearer until retry', () async {
    await client.signIn();
    platform.link = platform.callback();
    expect(await client.checkSession(), isTrue);
    transport.respond = (_) => throw const TransportFailure();
    await expectLater(
      client.signOut(),
      throwsA(_failure(ApiFailureKind.signOutUncertain)),
    );

    final restarted = NativeSessionClient(_profile, platform, transport);
    transport.requests.clear();
    await expectLater(
      restarted.checkSession(),
      throwsA(_failure(ApiFailureKind.signOutUncertain)),
    );
    await expectLater(
      restarted.capabilities(),
      throwsA(_failure(ApiFailureKind.signOutUncertain)),
    );
    expect(transport.requests, isEmpty);
    transport.respond = (request) => HttpReply(
      status: 403,
      url: request.url,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: 'native sign-in refused\n',
    );
    await expectLater(restarted.signOut(), throwsA(isA<SessionExpired>()));
    expect(transport.requests.single.bearer, _bearer);
    expect(platform.secrets, isEmpty);
  });

  test('unknown refusals never clear an existing bearer', () async {
    await client.signIn();
    platform.link = platform.callback();
    expect(await client.checkSession(), isTrue);
    transport.respond = (request) => HttpReply(
      status: 403,
      url: request.url,
      headers: {'content-type': 'text/plain'},
      body: 'synthetic gateway detail',
    );
    await expectLater(
      client.checkSession(),
      throwsA(_failure(ApiFailureKind.badResponse)),
    );
    expect(platform.secrets['session'], isNotNull);

    transport.respond = (request) => HttpReply(
      status: 403,
      url: request.url,
      headers: {'content-type': 'text/plain; charset=utf-8'},
      body: 'native sign-in refused\n',
    );
    expect(await client.checkSession(), isFalse);
    expect(platform.secrets, isEmpty);
  });

  test('rejects unusable bearer responses without persisting them', () async {
    await client.signIn();
    platform.link = platform.callback();
    transport.respond = (request) => HttpReply(
      status: 200,
      url: request.url,
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'token_type': 'Bearer', 'access_token': 'invalid'}),
    );
    await expectLater(
      client.checkSession(),
      throwsA(_failure(ApiFailureKind.badResponse)),
    );
    expect(platform.secrets, isEmpty);
    expect(transport.requests.single.url.path, _token);
  });

  test('discards credentials across changes to any profile field', () async {
    final otherProfiles = [
      NativeProfile.parse('https://other.example.test', _id, _redirect)!,
      NativeProfile.parse(_issuer, 'other', _redirect)!,
      NativeProfile.parse(_issuer, _id, '$_redirect/other')!,
    ];
    for (final other in otherProfiles) {
      final mismatched = NativeSessionClient(other, platform, transport);
      await client.signIn();
      platform.link = platform.callback();
      expect(await mismatched.checkSession(), isFalse);
      expect(platform.secrets, isEmpty);
      expect(transport.requests, isEmpty);

      await client.signIn();
      platform.link = platform.callback();
      expect(await client.checkSession(), isTrue);
      expect(await client.signIn(), SignInResult.sessionPresent);
      transport.requests.clear();
      expect(await mismatched.checkSession(), isFalse);
      expect(platform.secrets, isEmpty);
      await expectLater(
        mismatched.capabilities(),
        throwsA(isA<SessionExpired>()),
      );
      await mismatched.signOut();
      expect(transport.requests, isEmpty);
    }
  });
}

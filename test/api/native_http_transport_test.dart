import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/src/native_http_transport.dart';
import 'package:openmettle_app/api/src/transport.dart';

class _Headers extends Fake implements HttpHeaders {
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }
}

class _Redirect extends Fake implements HttpClientResponse {
  @override
  int get statusCode => 307;
}

class _Request extends Fake implements HttpClientRequest {
  @override
  final _Headers headers = _Headers();

  @override
  late bool followRedirects;

  @override
  late bool persistentConnection;

  @override
  late int contentLength;

  @override
  Future<HttpClientResponse> close() async {
    expect(followRedirects, isFalse);
    expect(persistentConnection, isFalse);
    return _Redirect();
  }
}

class _Client extends Fake implements HttpClient {
  final requests = <Uri>[];
  final request = _Request();

  @override
  late bool autoUncompress;

  bool closed = false;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add(url);
    return request;
  }

  @override
  void close({bool force = false}) {
    expect(force, isTrue);
    closed = true;
  }
}

void main() {
  test('does not follow redirects or attach cookies or origin', () async {
    final client = _Client();
    final url = Uri.parse('https://api.example.test/auth/native/logout');
    await HttpOverrides.runZoned(() async {
      final reply = await const NativeHttpTransport().send(
        'POST',
        url,
        bearer: 'synthetic-bearer',
      );
      expect(reply.redirected, isTrue);
      expect(reply.status, 307);
      expect(client.requests, [url]);
      expect(client.request.headers.values, {
        'accept-encoding': 'identity',
        'authorization': 'Bearer synthetic-bearer',
      });
      expect(client.request.contentLength, 0);
      expect(client.closed, isTrue);
    }, createHttpClient: (_) => client);
  });

  test(
    'refuses insecure or query-bearing URLs before opening a request',
    () async {
      final client = _Client();
      await HttpOverrides.runZoned(() async {
        for (final url in [
          'http://api.example.test/auth/native/logout',
          'https://api.example.test/auth/native/logout?unexpected=1',
          'https://user@api.example.test/auth/native/logout',
        ]) {
          await expectLater(
            const NativeHttpTransport().send('POST', Uri.parse(url)),
            throwsA(isA<TransportFailure>()),
          );
        }
        expect(client.requests, isEmpty);
      }, createHttpClient: (_) => client);
    },
  );
}

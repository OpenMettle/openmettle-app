@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/src/fetch_transport.dart';
import 'package:openmettle_app/api/src/transport.dart';

/// Exercises the real Fetch bindings in a browser against the test runner's
/// own origin. It cannot exercise the core routes, cookies or HTTPS.
void main() {
  final transport = FetchTransport();

  test('reads the page origin', () {
    expect(Uri.parse(transport.origin).origin, transport.origin);
  });

  test('a same-origin answer is a basic response from that URL', () async {
    final url = Uri.parse('${transport.origin}/openmettle-absent-route');
    final reply = await transport.send('GET', url, accept: 'application/json');
    expect(reply.type, 'basic');
    expect(reply.redirected, isFalse);
    expect(reply.url, url);
    expect(reply.status, greaterThanOrEqualTo(200));
  });

  test('a cross-origin request is never sent', () async {
    final url = Uri.parse('https://cross-origin.invalid/auth/session');
    await expectLater(
      transport.send('GET', url),
      throwsA(isA<TransportFailure>()),
    );
  });
}

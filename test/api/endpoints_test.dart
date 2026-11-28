import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/browser_client.dart';
import 'package:openmettle_app/api/src/endpoints.dart';

void main() {
  test('plain literal paths follow core check_path', () {
    for (final path in [
      '/',
      '/auth/login',
      '/auth/login/',
      '/a.b_c~d-e',
      '/${'a' * 255}',
    ]) {
      expect(isPlainPath(path), isTrue, reason: path);
    }
    for (final path in [
      '',
      'auth/login',
      '//evil.test/login',
      '/auth//login',
      '/auth/login//',
      '/auth/./login',
      '/auth/../login',
      '/..',
      '/auth/login?x=1',
      '/auth/login#x',
      '/auth/%6Cogin',
      '/auth/{id}',
      '/auth/:id',
      '/auth/*',
      '/auth/lögin',
      r'/auth\login',
      'https://evil.test/login',
      '/${'a' * 256}',
    ]) {
      expect(isPlainPath(path), isFalse, reason: path);
    }
  });

  test('origins must be canonical HTTPS', () {
    for (final origin in [
      'https://app.example.test',
      'https://app.example.test:8443',
    ]) {
      expect(isHttpsOrigin(origin), isTrue, reason: origin);
    }
    for (final origin in [
      'http://app.example.test',
      'https://APP.example.test',
      'https://app.example.test:443',
      'https://app.example.test/',
      'https://user@app.example.test',
      'null',
      '',
    ]) {
      expect(isHttpsOrigin(origin), isFalse, reason: origin);
    }
  });

  test('routes resolve on the page origin', () {
    final endpoints = Endpoints.resolve(
      origin: 'https://app.example.test',
      login: '/auth/login',
      session: '/auth/session',
      logout: '/auth/logout',
    )!;
    expect(endpoints.login, Uri.parse('https://app.example.test/auth/login'));
    expect(
      endpoints.session,
      Uri.parse('https://app.example.test/auth/session'),
    );
    expect(endpoints.logout, Uri.parse('https://app.example.test/auth/logout'));
    expect(
      endpoints.capabilities,
      Uri.parse('https://app.example.test/v1/capabilities'),
    );
  });

  test('colliding or reserved paths are refused', () {
    Endpoints? resolve(String login, String session, String logout) =>
        Endpoints.resolve(
          origin: 'https://app.example.test',
          login: login,
          session: session,
          logout: logout,
        );
    expect(resolve('/a', '/a', '/b'), isNull);
    expect(resolve('/a', '/b', '/a'), isNull);
    for (final reserved in ['/healthz', '/readyz', '/v1', '/v1/', '/v1/x']) {
      expect(resolve(reserved, '/b', '/c'), isNull, reason: reserved);
      expect(resolve('/a', reserved, '/c'), isNull, reason: reserved);
      expect(resolve('/a', '/b', reserved), isNull, reason: reserved);
    }
  });

  test('the VM build has no browser client', () {
    expect(createBrowserClient, throwsUnsupportedError);
  });
}

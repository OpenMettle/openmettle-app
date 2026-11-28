import '../client.dart';
import 'fetch_transport.dart';
import 'http_session_client.dart';

// Deployment-selected public route paths, set at build time with
// `--dart-define`. They must equal the `browser.paths` of the server's auth
// settings document (core ADR 0020). The defaults are that ADR's synthetic
// example values, not a recommendation.
const _loginPath = String.fromEnvironment(
  'OPENMETTLE_LOGIN_PATH',
  defaultValue: '/auth/login',
);
const _sessionPath = String.fromEnvironment(
  'OPENMETTLE_SESSION_PATH',
  defaultValue: '/auth/session',
);
const _logoutPath = String.fromEnvironment(
  'OPENMETTLE_LOGOUT_PATH',
  defaultValue: '/auth/logout',
);

/// The same-origin cookie-mode client for this page. See [sessionClientFor].
SessionClient createBrowserClient() => sessionClientFor(
  FetchTransport(),
  login: _loginPath,
  session: _sessionPath,
  logout: _logoutPath,
);

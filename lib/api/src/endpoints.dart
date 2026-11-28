/// Absolute URLs of the browser session routes and the application API, all
/// on the page origin.
class Endpoints {
  const Endpoints._({
    required this.origin,
    required this.login,
    required this.session,
    required this.logout,
    required this.capabilities,
  });

  final String origin;
  final Uri login;
  final Uri session;
  final Uri logout;
  final Uri capabilities;

  /// Resolves the deployment-selected route paths against the page [origin].
  ///
  /// Returns `null` unless [origin] is a canonical HTTPS origin and each path
  /// is a plain literal path that core's browser profile accepts (ADRs 0018
  /// and 0020): distinct, not `/healthz`, `/readyz`, `/v1` or under `/v1/`.
  /// A plain absolute path cannot leave the page origin.
  static Endpoints? resolve({
    required String origin,
    required String login,
    required String session,
    required String logout,
  }) {
    if (!isHttpsOrigin(origin)) return null;
    final paths = [login, session, logout];
    if (!paths.every(isPlainPath)) return null;
    if (paths.any(_reserved) || paths.toSet().length != paths.length) {
      return null;
    }
    Uri at(String path) => Uri.parse('$origin$path');
    return Endpoints._(
      origin: origin,
      login: at(login),
      session: at(session),
      logout: at(logout),
      capabilities: at('/v1/capabilities'),
    );
  }
}

const _maxPathBytes = 256;
final _pathBytes = RegExp(r'^[A-Za-z0-9/._~-]*$');

/// `/`, then segments of ASCII letters, digits and `- . _ ~`, with no empty
/// inner segment, dot segment, escape, query or fragment; a trailing `/` is
/// allowed. Mirrors core `browser_auth::router::check_path`.
bool isPlainPath(String path) {
  if (path.length > _maxPathBytes || !path.startsWith('/')) return false;
  final rest = path.substring(1);
  if (!_pathBytes.hasMatch(rest)) return false;
  final segments = rest.split('/');
  if (segments.isNotEmpty && segments.last.isEmpty) segments.removeLast();
  return segments.every((s) => s.isNotEmpty && s != '.' && s != '..');
}

bool _reserved(String path) =>
    path == '/healthz' ||
    path == '/readyz' ||
    path == '/v1' ||
    path.startsWith('/v1/');

/// `https://host[:port]` exactly as browsers serialize an origin.
bool isHttpsOrigin(String origin) {
  final uri = Uri.tryParse(origin);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.path.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.origin == origin;
}

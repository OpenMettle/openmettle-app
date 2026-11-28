import '../client.dart';
import 'endpoints.dart';
import 'transport.dart';
import 'wire.dart';

/// The client for [transport]'s page origin and the deployment-selected route
/// paths. When the origin is not HTTPS or a path is not a plain literal path
/// (see [Endpoints.resolve]), every call fails with
/// [ApiFailureKind.configuration] and nothing is sent.
SessionClient sessionClientFor(
  Transport transport, {
  required String login,
  required String session,
  required String logout,
}) {
  final endpoints = Endpoints.resolve(
    origin: transport.origin,
    login: login,
    session: session,
    logout: logout,
  );
  return endpoints == null
      ? const _Misconfigured()
      : HttpSessionClient(transport, endpoints);
}

/// Same-origin cookie-mode client for core's browser session routes
/// (ADR 0019) and `GET /v1/capabilities` (ADR 0007).
///
/// The session credential is the `__Host-openmettle-session` cookie, which is
/// HttpOnly: this client never reads, stores or sends it itself. The browser
/// attaches it to same-origin requests.
class HttpSessionClient implements SessionClient {
  HttpSessionClient(this._transport, this._endpoints);

  final Transport _transport;
  final Endpoints _endpoints;

  @override
  Future<bool> checkSession() async {
    final reply = await _read(_endpoints.session);
    _requireSameOrigin(reply, _endpoints.session);
    switch (reply.status) {
      case 204:
        if (reply.body.isNotEmpty) _bad(reply);
        return true;
      case 403:
        switch (_fixedLine(reply)) {
          case 'session not valid':
            return false;
          case 'session origin refused':
            throw ApiFailure(ApiFailureKind.originRefused, status: 403);
        }
        _bad(reply);
      default:
        _transient(reply);
        _bad(reply);
    }
  }

  @override
  Future<void> signIn() async {
    _transport.submitForm(_endpoints.login);
  }

  @override
  Future<void> signOut() async {
    final HttpReply reply;
    try {
      reply = await _transport.send('POST', _endpoints.logout);
    } on TransportFailure {
      throw const ApiFailure(ApiFailureKind.signOutUncertain);
    }
    if (_sameOrigin(reply, _endpoints.logout)) {
      switch (reply.status) {
        case 204:
          return;
        case 403:
          switch (_fixedLine(reply)) {
            case 'session not valid':
              throw const SessionExpired();
            case 'logout origin refused':
              throw ApiFailure(ApiFailureKind.originRefused, status: 403);
          }
        case 429:
          // Refused before the handoff; nothing was revoked.
          throw ApiFailure(ApiFailureKind.unavailable, status: 429);
      }
    }
    // Anything else, including a 503 after an uncertain commit, a redirect or
    // an unrecognized refusal, leaves the revocation unknown (ADR 0019).
    throw ApiFailure(
      ApiFailureKind.signOutUncertain,
      status: reply.status == 0 ? null : reply.status,
    );
  }

  @override
  Future<List<Capability>> capabilities() async {
    final url = _endpoints.capabilities;
    final reply = await _read(url, accept: 'application/json');
    _requireSameOrigin(reply, url);
    final status = reply.status;
    final version = reply.headers['openmettle-api-version'];
    if (version != null) checkApiVersion(version, status: status);
    switch (status) {
      case 200:
        if (version == null ||
            !hasMediaType(reply.headers['content-type'], 'application/json')) {
          _bad(reply);
        }
        return decodeCapabilityList(reply.body, status: status);
      case 401:
        if (version == null ||
            !hasMediaType(
              reply.headers['content-type'],
              'application/problem+json',
            ) ||
            decodeProblemCode(reply.body, status) != 'unauthenticated') {
          _bad(reply);
        }
        throw const SessionExpired();
      default:
        _transient(reply);
        _bad(reply);
    }
  }

  /// A safe `GET`: no answer means the result is unknown, not refused.
  Future<HttpReply> _read(Uri url, {String? accept}) async {
    try {
      return await _transport.send('GET', url, accept: accept);
    } on TransportFailure {
      throw const ApiFailure(ApiFailureKind.unavailable);
    }
  }

  /// Rate limits and server or gateway failures, recognized by status alone
  /// because an intermediary may have produced them.
  static void _transient(HttpReply reply) {
    if (const {429, 500, 502, 503, 504}.contains(reply.status)) {
      throw ApiFailure(ApiFailureKind.unavailable, status: reply.status);
    }
  }

  static Never _bad(HttpReply reply) => throw ApiFailure(
    ApiFailureKind.badResponse,
    status: reply.status == 0 ? null : reply.status,
  );

  /// A same-origin answer from [url] itself: not a redirect, opaque or
  /// cross-origin response.
  static bool _sameOrigin(HttpReply reply, Uri url) =>
      reply.type == 'basic' && !reply.redirected && reply.url == url;

  static void _requireSameOrigin(HttpReply reply, Uri url) {
    if (!_sameOrigin(reply, url)) _bad(reply);
  }

  /// The session routes' plain-text refusal line, or `null`.
  static String? _fixedLine(HttpReply reply) {
    if (!hasMediaType(reply.headers['content-type'], 'text/plain')) return null;
    final body = reply.body;
    if (!body.endsWith('\n')) return null;
    final line = body.substring(0, body.length - 1);
    return line.contains('\n') ? null : line;
  }
}

class _Misconfigured implements SessionClient {
  const _Misconfigured();

  static Never _fail() => throw const ApiFailure(ApiFailureKind.configuration);

  @override
  Future<bool> checkSession() async => _fail();

  @override
  Future<void> signIn() async => _fail();

  @override
  Future<void> signOut() async => _fail();

  @override
  Future<List<Capability>> capabilities() async => _fail();
}

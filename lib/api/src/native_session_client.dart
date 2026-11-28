import 'dart:convert';

import '../client.dart';
import 'capabilities_reply.dart';
import 'native_profile.dart';
import 'transport.dart';
import 'wire.dart';

abstract interface class NativeAuthPlatform {
  Stream<void> get linkAvailable;

  Future<({String state, String verifier, String challenge})> newAttempt();
  Future<String?> readSecret(String key);
  Future<void> writeSecret(String key, String? value);
  Future<void> launchBrowser(Uri url);
  Future<String?> takeLink();
}

abstract interface class NativeTransport {
  /// Sends one request without redirects, retries, cookies or Origin.
  Future<HttpReply> send(
    String method,
    Uri url, {
    String? accept,
    String? bearer,
    String? jsonBody,
  });
}

class NativeSessionClient implements SessionClient, SessionUpdates {
  NativeSessionClient(
    this._profile,
    this._platform,
    this._transport, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NativeProfile? _profile;
  final NativeAuthPlatform _platform;
  final NativeTransport _transport;
  final DateTime Function() _clock;

  // A callback can arrive during sign-in, session checks or logout. Keep
  // secure storage and HTTP mutations in one queue, including the consume
  // before exchange, even when an older UI request no longer owns the screen.
  Future<void> _tail = Future.value();
  // Kept only when deleting the matching attempt failed before token exchange.
  String? _linkAwaitingStorage;

  @override
  Stream<void> get sessionUpdates => _platform.linkAvailable;

  Future<T> _serial<T>(Future<T> Function(NativeProfile) operation) {
    final result = _tail.then((_) async {
      final profile = _profile;
      if (profile == null) {
        throw const ApiFailure(ApiFailureKind.configuration);
      }
      try {
        return await operation(profile);
      } on ApiFailure {
        rethrow;
      } on SessionExpired {
        rethrow;
      } catch (_) {
        // Platform and codec exceptions can include raw channel arguments.
        throw const ApiFailure(ApiFailureKind.unavailable);
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  @override
  Future<SignInResult> signIn() => _serial((profile) async {
    // A launch request only comes from the signed-out screen. Recheck here
    // because an earlier queued callback could have installed a session.
    if (await _session(profile) != null) return SignInResult.sessionPresent;
    _linkAwaitingStorage = null;
    final attempt = await _platform.newAttempt();
    if (!_token(attempt.state) ||
        !_token(attempt.verifier) ||
        !_token(attempt.challenge)) {
      throw const ApiFailure(ApiFailureKind.unavailable);
    }
    await _platform.writeSecret(
      'attempt',
      jsonEncode({
        ...profile.binding,
        'state': attempt.state,
        'verifier': attempt.verifier,
        'created_ms': _now,
      }),
    );
    try {
      await _platform.launchBrowser(
        profile
            .endpoint('/auth/native/authorize')
            .replace(
              queryParameters: {
                'response_type': 'code',
                'client_id': profile.clientId,
                'redirect_uri': profile.redirect,
                'code_challenge_method': 'S256',
                'code_challenge': attempt.challenge,
                'state': attempt.state,
              },
            ),
      );
    } catch (_) {
      await _platform.writeSecret('attempt', null);
      rethrow;
    }
    return SignInResult.browserOpened;
  });

  @override
  Future<bool> checkSession() => _serial((profile) async {
    final existing = await _session(profile);
    if (existing?.revoking ?? false) {
      throw const ApiFailure(ApiFailureKind.signOutUncertain);
    }
    final bearer = existing?.bearer ?? await _redeem(profile);
    if (bearer == null) return false;
    final reply = await _send(
      'GET',
      profile.endpoint('/auth/native/session'),
      bearer: bearer,
    );
    if (_emptySuccess(reply)) return true;
    if (_refused(reply)) {
      await _platform.writeSecret('session', null);
      return false;
    }
    checkTransientReply(reply);
    badHttpReply(reply);
  });

  @override
  Future<List<Capability>> capabilities() => _serial((profile) async {
    final session = await _session(profile);
    if (session == null) throw const SessionExpired();
    if (session.revoking) {
      throw const ApiFailure(ApiFailureKind.signOutUncertain);
    }
    final reply = await _send(
      'GET',
      profile.endpoint('/v1/capabilities'),
      accept: 'application/json',
      bearer: session.bearer,
    );
    try {
      return decodeCapabilitiesReply(reply);
    } on SessionExpired {
      await _platform.writeSecret('session', null);
      rethrow;
    }
  });

  @override
  Future<void> signOut() => _serial((profile) async {
    _linkAwaitingStorage = null;
    await _platform.writeSecret('attempt', null);
    final session = await _session(profile);
    if (session == null) return;
    // Keep the bearer only for retrying a logout whose response may be lost.
    // Fence normal use before the POST so the fence survives a process death.
    await _storeSession(profile, session.bearer, revoking: true);
    try {
      final reply = await _send(
        'POST',
        profile.endpoint('/auth/native/logout'),
        bearer: session.bearer,
      );
      if (!_emptySuccess(reply) && !_refused(reply)) {
        throw ApiFailure(ApiFailureKind.signOutUncertain, status: reply.status);
      }
      await _platform.writeSecret('session', null);
      if (_refused(reply)) throw const SessionExpired();
    } on SessionExpired {
      rethrow;
    } on ApiFailure catch (error) {
      throw ApiFailure(ApiFailureKind.signOutUncertain, status: error.status);
    } catch (_) {
      throw const ApiFailure(ApiFailureKind.signOutUncertain);
    }
  });

  Future<String?> _redeem(NativeProfile profile) async {
    final attempt = await _readRecord(profile, 'attempt');
    final link = await _platform.takeLink() ?? _linkAwaitingStorage;
    _linkAwaitingStorage = null;
    if (attempt == null) return null;
    final created = attempt['created_ms'];
    final now = _now;
    if (created is! int || created > now || now - created >= _attemptMs) {
      await _platform.writeSecret('attempt', null);
      return null;
    }
    if (link == null ||
        link.length > 8192 ||
        !link.startsWith('${profile.redirect}?')) {
      return null;
    }
    final uri = Uri.tryParse(link);
    if (uri == null || uri.hasFragment) return null;
    final Map<String, List<String>> query;
    try {
      query = uri.queryParametersAll;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
    if (query.length != 3) return null;
    final issuer = _only(query['iss']);
    final code = _only(query['code']);
    final state = _only(query['state']);
    if (issuer != profile.issuer || !_token(code) || !_token(state))
      return null;

    final verifier = attempt['verifier'];
    if (attempt['state'] != state || verifier is! String || !_token(verifier)) {
      return null;
    }

    // The one-use exchange is never retried, including after response loss.
    _linkAwaitingStorage = link;
    await _platform.writeSecret('attempt', null);
    _linkAwaitingStorage = null;
    final reply = await _send(
      'POST',
      profile.endpoint('/auth/native/token'),
      accept: 'application/json',
      jsonBody: jsonEncode({
        ...profile.binding,
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
      }),
    );
    if (_refused(reply)) return null;
    checkTransientReply(reply);
    if (reply.status != 200 ||
        !hasMediaType(reply.headers['content-type'], 'application/json')) {
      badHttpReply(reply);
    }
    final token = _object(reply.body);
    final bearer = token?['access_token'];
    if (token?['token_type'] != 'Bearer' || !_bearer(bearer))
      badHttpReply(reply);
    final value = bearer as String;
    await _storeSession(profile, value, revoking: false);
    return value;
  }

  Future<HttpReply> _send(
    String method,
    Uri url, {
    String? accept,
    String? bearer,
    String? jsonBody,
  }) async {
    final HttpReply reply;
    try {
      reply = await _transport.send(
        method,
        url,
        accept: accept,
        bearer: bearer,
        jsonBody: jsonBody,
      );
    } on TransportFailure {
      throw const ApiFailure(ApiFailureKind.unavailable);
    }
    if (reply.url != url || reply.type != 'basic' || reply.redirected) {
      badHttpReply(reply);
    }
    return reply;
  }

  Future<Map<String, Object?>?> _readRecord(
    NativeProfile profile,
    String key,
  ) async {
    final value = await _platform.readSecret(key);
    if (value == null) return null;
    final record = _object(value);
    if (record != null && profile.matches(record)) return record;
    // A different registration cannot revoke the old session. Discard its
    // local credential without presenting it to the new registration.
    await _platform.writeSecret(key, null);
    return null;
  }

  Future<({String bearer, bool revoking})?> _session(
    NativeProfile profile,
  ) async {
    final record = await _readRecord(profile, 'session');
    if (record == null) return null;
    final bearer = record['bearer'];
    final revoking = record['revoking'];
    if (!_bearer(bearer) || revoking is! bool) {
      await _platform.writeSecret('session', null);
      return null;
    }
    return (bearer: bearer as String, revoking: revoking);
  }

  Future<void> _storeSession(
    NativeProfile profile,
    String bearer, {
    required bool revoking,
  }) => _platform.writeSecret(
    'session',
    jsonEncode({...profile.binding, 'bearer': bearer, 'revoking': revoking}),
  );

  int get _now => _clock().millisecondsSinceEpoch;
}

const _attemptMs = 600000; // Core's maximum login lifetime.

String? _only(List<String>? values) =>
    values?.length == 1 ? values!.single : null;

final _encodedToken = RegExp(r'^[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$');

bool _token(Object? value) =>
    value is String && value.length == 43 && _encodedToken.hasMatch(value);

/// Core ADRs 0023 and 0013 define two canonical components.
bool _bearer(Object? value) {
  if (value is! String || value.length != 87) return false;
  final parts = value.split('.');
  return parts.length == 2 && parts.every(_token);
}

bool _emptySuccess(HttpReply reply) =>
    reply.status == 204 && reply.body.isEmpty;

bool _refused(HttpReply reply) =>
    reply.status == 403 &&
    hasMediaType(reply.headers['content-type'], 'text/plain') &&
    reply.body == 'native sign-in refused\n';

Map<String, Object?>? _object(String value) {
  try {
    final result = jsonDecode(value);
    return result is Map<String, Object?> ? result : null;
  } on FormatException {
    return null;
  }
}

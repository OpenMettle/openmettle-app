/// Session and capability seam between the UI and the core application API.
///
/// The session screen uses this interface across browser and Android clients.
/// Tests can substitute their own [SessionClient].
library;

/// The application session and the read-only capability inventory.
///
/// [SessionExpired] indicates a definite session refusal. [ApiFailure]
/// reports configuration, transport and protocol failures.
abstract interface class SessionClient {
  /// Whether this client holds a session the server currently accepts.
  ///
  /// Returns `false` when no credential is available or the server refuses it.
  /// Throws [ApiFailure] when the answer is unknown.
  Future<bool> checkSession();

  /// Requests browser sign-in, or reports a session that arrived first.
  Future<SignInResult> signIn();

  /// Ends the presented session.
  ///
  /// For a presented credential, waits for the server to acknowledge
  /// revocation. Throws [SessionExpired] after a definite refusal and
  /// [ApiFailure] with [ApiFailureKind.signOutUncertain] when the outcome
  /// is unknown and sign-out can be retried.
  Future<void> signOut();

  /// Capabilities visible to the signed-in caller (`GET /v1/capabilities`).
  Future<List<Capability>> capabilities();
}

enum SignInResult { browserOpened, sessionPresent }

/// A native handoff can arrive independently of the current screen or
/// lifecycle transition. The app rechecks on each signal and on foregrounding.
abstract interface class SessionUpdates {
  Stream<void> get sessionUpdates;
}

/// One capability with independent dimensions, as reported by the server.
///
/// [kind] and [readiness] are open vocabularies and are kept verbatim: an
/// unrecognized value must never be read as a capability or as ready. A
/// `null` [authorization] means "not determined", never `false`. [readiness]
/// is the readiness state and is present exactly when [installed] is `true`.
class Capability {
  const Capability({
    required this.id,
    required this.kind,
    required this.installed,
    required this.authorization,
    this.readiness,
  });

  final String id;
  final String kind;
  final bool installed;
  final bool? authorization;
  final String? readiness;

  @override
  bool operator ==(Object other) =>
      other is Capability &&
      other.id == id &&
      other.kind == kind &&
      other.installed == installed &&
      other.authorization == authorization &&
      other.readiness == readiness;

  @override
  int get hashCode =>
      Object.hash(id, kind, installed, authorization, readiness);

  @override
  String toString() =>
      'Capability($id, kind: $kind, installed: $installed, '
      'authorization: $authorization, readiness: $readiness)';
}

/// The server refused the session: it is absent, expired, revoked or no
/// longer eligible. The user has to sign in again.
class SessionExpired implements Exception {
  const SessionExpired();

  @override
  String toString() => 'SessionExpired';
}

/// Why a call failed without a definite session refusal.
enum ApiFailureKind {
  /// The client's deployment configuration is unusable (route paths or page
  /// origin). Nothing was sent.
  configuration,

  /// The server refused the page origin or fetch metadata. This indicates a
  /// deployment or ingress fault, not a session state.
  originRefused,

  /// The server or a gateway is temporarily unable to answer (rate limit,
  /// `5xx`, network failure or timeout). The request may be retried.
  unavailable,

  /// The logout outcome is unknown: the session may still be valid. Retrying
  /// sign-out is safe.
  signOutUncertain,

  /// The response declares an API major version this client does not support.
  unsupportedVersion,

  /// The response did not follow the contract: unexpected status, redirect,
  /// media type, header or body.
  badResponse,
}

/// A failed call that is not a [SessionExpired] refusal. Carries no response
/// body or header value.
class ApiFailure implements Exception {
  const ApiFailure(this.kind, {this.status});

  final ApiFailureKind kind;

  /// The HTTP status, when a response was received.
  final int? status;

  @override
  String toString() =>
      'ApiFailure(${kind.name}${status == null ? '' : ', status $status'})';
}

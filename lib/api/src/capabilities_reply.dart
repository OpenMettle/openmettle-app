import '../client.dart';
import 'transport.dart';
import 'wire.dart';

/// The common authenticated capabilities contract for web and Android.
List<Capability> decodeCapabilitiesReply(HttpReply reply) {
  final status = reply.status;
  final version = reply.headers['openmettle-api-version'];
  if (version != null) checkApiVersion(version, status: status);
  switch (status) {
    case 200:
      if (version == null ||
          !hasMediaType(reply.headers['content-type'], 'application/json')) {
        badHttpReply(reply);
      }
      return decodeCapabilityList(reply.body, status: status);
    case 401:
      if (version == null ||
          !hasMediaType(
            reply.headers['content-type'],
            'application/problem+json',
          ) ||
          decodeProblemCode(reply.body, status) != 'unauthenticated') {
        badHttpReply(reply);
      }
      throw const SessionExpired();
    default:
      checkTransientReply(reply);
      badHttpReply(reply);
  }
}

/// Rate limits and server or gateway failures, recognized by status alone
/// because an intermediary may have produced them.
const transientStatuses = {429, 500, 502, 503, 504};

/// Throws [ApiFailureKind.unavailable] for one of [transientStatuses].
void checkTransientReply(HttpReply reply) {
  if (transientStatuses.contains(reply.status)) {
    throw ApiFailure(ApiFailureKind.unavailable, status: reply.status);
  }
}

Never badHttpReply(HttpReply reply) => throw ApiFailure(
  ApiFailureKind.badResponse,
  status: reply.status == 0 ? null : reply.status,
);

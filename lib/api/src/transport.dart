/// One received response, already read in full. Header names are lowercase;
/// only [Transport.headerNames] are captured, and a repeated field arrives as
/// the browser combines it (`a, b`).
class HttpReply {
  const HttpReply({
    required this.status,
    required this.url,
    this.type = 'basic',
    this.redirected = false,
    this.headers = const {},
    this.body = '',
  });

  /// `0` for an unfollowed redirect.
  final int status;

  /// The URL that produced this response.
  final Uri url;

  /// The Fetch response type: `basic` for a same-origin response,
  /// `opaqueredirect` for a redirect that was not followed.
  final String type;
  final bool redirected;
  final Map<String, String> headers;
  final String body;
}

/// The request was not answered: network failure, abort or timeout. The
/// server may still have received and processed it.
class TransportFailure implements Exception {
  const TransportFailure();

  @override
  String toString() => 'TransportFailure';
}

/// The browser primitives the client needs. The web implementation sends
/// same-origin requests with cookies, never follows a redirect and adds no
/// credential of its own.
abstract interface class Transport {
  /// Response headers the client inspects.
  static const headerNames = ['content-type', 'openmettle-api-version'];

  /// The page origin as the browser serializes it, for example
  /// `https://app.example.test`.
  String get origin;

  /// Sends one request with an empty body. Throws [TransportFailure] when no
  /// response is received.
  Future<HttpReply> send(String method, Uri url, {String? accept});

  /// Navigates the page with a top-level form `POST` to [action] and an empty
  /// body.
  void submitForm(Uri action);
}

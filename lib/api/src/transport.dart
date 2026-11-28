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

/// A response head whose body is still arriving.
class StreamedReply {
  const StreamedReply(this.head, this.body);

  /// Status, URL, type and [Transport.headerNames]; its `body` is empty.
  final HttpReply head;

  /// The body bytes, single-subscription. Reading stops while the
  /// subscription is paused, and cancelling it aborts the request. A lost
  /// connection or an abort ends it with [TransportFailure].
  final Stream<List<int>> body;
}

/// Same-origin `GET` with an incrementally read body, under the same request
/// rules as [Transport.send] but without a built-in timeout: the caller
/// decides how long to wait, so a healthy long-lived stream is not cut off.
abstract interface class StreamingTransport implements Transport {
  /// Starts a `GET` and completes with the response head. Completing
  /// [cancel] aborts the request at any stage, including a pending head or
  /// an unread body. Throws [TransportFailure] when no head is received.
  Future<StreamedReply> open(
    Uri url, {
    required String accept,
    required Future<void> cancel,
  });
}

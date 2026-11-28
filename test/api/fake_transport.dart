import 'package:openmettle_app/api/src/transport.dart';

const origin = 'https://app.example.test';
final sessionUrl = Uri.parse('$origin/auth/session');
final logoutUrl = Uri.parse('$origin/auth/logout');
final loginUrl = Uri.parse('$origin/auth/login');
final capabilitiesUrl = Uri.parse('$origin/v1/capabilities');

/// One recorded [Transport.send] call.
typedef SentRequest = ({String method, Uri url, String? accept});

/// A scripted [Transport]: [respond] answers each request, or throws
/// [TransportFailure] to simulate a lost response.
class FakeTransport implements Transport {
  FakeTransport(this.respond, {this.origin = 'https://app.example.test'});

  HttpReply Function(SentRequest request) respond;

  @override
  final String origin;

  final sent = <SentRequest>[];
  final submitted = <Uri>[];

  @override
  Future<HttpReply> send(String method, Uri url, {String? accept}) async {
    final request = (method: method, url: url, accept: accept);
    sent.add(request);
    return respond(request);
  }

  @override
  void submitForm(Uri action) => submitted.add(action);
}

/// A same-origin response from the requested URL.
HttpReply Function(SentRequest) reply(
  int status, {
  Map<String, String> headers = const {},
  String body = '',
}) =>
    (request) => HttpReply(
      status: status,
      url: request.url,
      headers: headers,
      body: body,
    );

/// A session-route refusal: one plain-text fixed line (core ADR 0019).
HttpReply Function(SentRequest) line(int status, String text) => reply(
  status,
  headers: const {'content-type': 'text/plain; charset=utf-8'},
  body: '$text\n',
);

/// An application API response with the version header.
HttpReply Function(SentRequest) api(
  int status,
  String body, {
  String contentType = 'application/json',
  String? version = '1.0',
}) => reply(
  status,
  headers: {'content-type': contentType, 'openmettle-api-version': ?version},
  body: body,
);

/// One recorded [StreamingTransport.open] call. [cancelled] is set when the
/// caller completes its cancel signal.
class OpenedRequest {
  OpenedRequest(this.url, this.accept, Future<void> cancel) {
    cancel.then((_) => cancelled = true);
  }

  final Uri url;
  final String accept;
  bool cancelled = false;
}

/// A scripted [Transport] that is also a [StreamingTransport]: [stream]
/// answers each [open], or throws [TransportFailure] for a lost head.
class FakeStreamingTransport extends FakeTransport
    implements StreamingTransport {
  FakeStreamingTransport(this.stream) : super(_unexpected);

  Future<StreamedReply> Function(OpenedRequest request) stream;

  final opened = <OpenedRequest>[];

  static HttpReply _unexpected(SentRequest _) =>
      throw StateError('unexpected unary send');

  @override
  Future<StreamedReply> open(
    Uri url, {
    required String accept,
    required Future<void> cancel,
  }) {
    final request = OpenedRequest(url, accept, cancel);
    opened.add(request);
    return stream(request);
  }
}

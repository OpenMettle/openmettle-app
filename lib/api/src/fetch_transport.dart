import 'dart:js_interop';

import 'transport.dart';

/// [Transport] over the browser Fetch API and DOM, through `dart:js_interop`
/// bindings declared here (no package dependency).
///
/// Every request is same-origin only (`mode: same-origin`), sends cookies only
/// to the same origin, bypasses the HTTP cache, never follows a redirect
/// (`redirect: manual`) and is aborted after [timeout]. The request referrer
/// policy is `same-origin`, so the browser sends the page `Origin` on the
/// logout `POST` even if the page itself uses `no-referrer`.
class FetchTransport implements Transport {
  FetchTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  @override
  String get origin => _location.origin;

  @override
  Future<HttpReply> send(String method, Uri url, {String? accept}) async {
    final _Response response;
    final String body;
    try {
      response = await _fetch(
        url.toString(),
        _RequestInit(
          method: method,
          mode: 'same-origin',
          credentials: 'same-origin',
          cache: 'no-store',
          redirect: 'manual',
          referrerPolicy: 'same-origin',
          headers: {if (accept != null) 'Accept': accept}.jsify()!,
          signal: _timeoutSignal(timeout.inMilliseconds),
        ),
      ).toDart;
      body = (await response.text().toDart).toDart;
    } catch (_) {
      // Network failure, abort, timeout or a refused cross-origin request.
      throw const TransportFailure();
    }
    final headers = <String, String>{
      for (final name in Transport.headerNames)
        if (response.headers.get(name) case final value?) name: value,
    };
    return HttpReply(
      status: response.status,
      url: Uri.parse(response.url.isEmpty ? url.toString() : response.url),
      type: response.type,
      redirected: response.redirected,
      headers: headers,
      body: body,
    );
  }

  @override
  void submitForm(Uri action) {
    final form = _document.createElement('form')
      ..setAttribute('method', 'post')
      ..setAttribute('action', action.toString())
      ..setAttribute('enctype', 'application/x-www-form-urlencoded')
      ..setAttribute('target', '_self')
      ..setAttribute('hidden', '');
    final body = _document.body;
    if (body == null) throw StateError('document has no body');
    body.appendChild(form);
    form.submit();
  }
}

@JS('fetch')
external JSPromise<_Response> _fetch(String url, _RequestInit init);

@JS('AbortSignal.timeout')
external JSObject _timeoutSignal(int milliseconds);

@JS('location')
external _Location get _location;

@JS('document')
external _Document get _document;

extension type _RequestInit._(JSObject _) implements JSObject {
  external factory _RequestInit({
    String method,
    String mode,
    String credentials,
    String cache,
    String redirect,
    String referrerPolicy,
    JSAny headers,
    JSObject signal,
  });
}

extension type _Response._(JSObject _) implements JSObject {
  external int get status;
  external String get type;
  external String get url;
  external bool get redirected;
  external _Headers get headers;
  external JSPromise<JSString> text();
}

extension type _Headers._(JSObject _) implements JSObject {
  external String? get(String name);
}

extension type _Location._(JSObject _) implements JSObject {
  external String get origin;
}

extension type _Document._(JSObject _) implements JSObject {
  external _Element createElement(String tagName);
  external _Element? get body;
}

extension type _Element._(JSObject _) implements JSObject {
  external void setAttribute(String name, String value);
  external void appendChild(_Element child);
  external void submit();
}

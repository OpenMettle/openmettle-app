import 'dart:async';
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
///
/// [open] applies the same request rules, but with an `AbortController`
/// instead of [timeout], and reads the body through its stream reader only
/// while the consumer is listening and not paused.
class FetchTransport implements StreamingTransport {
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
  Future<StreamedReply> open(
    Uri url, {
    required String accept,
    required Future<void> cancel,
  }) async {
    final abort = _AbortController();
    unawaited(cancel.then((_) => abort.abort()));
    final _Response response;
    try {
      response = await _fetch(
        url.toString(),
        _RequestInit(
          method: 'GET',
          mode: 'same-origin',
          credentials: 'same-origin',
          cache: 'no-store',
          redirect: 'manual',
          referrerPolicy: 'same-origin',
          headers: {'Accept': accept}.jsify()!,
          signal: abort.signal,
        ),
      ).toDart;
    } catch (_) {
      throw const TransportFailure();
    }
    final head = HttpReply(
      status: response.status,
      url: Uri.parse(response.url.isEmpty ? url.toString() : response.url),
      type: response.type,
      redirected: response.redirected,
      headers: {
        for (final name in Transport.headerNames)
          if (response.headers.get(name) case final value?) name: value,
      },
    );
    return StreamedReply(head, _readBody(response.body, abort));
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

/// Reads [body] chunk by chunk. A paused subscription issues no further
/// read, so at most one chunk is buffered (backpressure). Cancelling aborts
/// the request; a failed read, including an abort the consumer did not ask
/// for, ends the stream with [TransportFailure].
Stream<List<int>> _readBody(_ReadableStream? body, _AbortController abort) {
  late final StreamController<List<int>> out;
  var cancelled = false;
  Completer<void>? resumed;

  Future<void> pump(_Reader reader) async {
    try {
      while (true) {
        while (out.isPaused && !cancelled) {
          await (resumed ??= Completer<void>()).future;
        }
        if (cancelled) return;
        final chunk = await reader.read().toDart;
        if (cancelled) return;
        if (chunk.done) break;
        final value = chunk.value;
        if (value != null) out.add(value.toDart);
      }
    } catch (_) {
      if (cancelled) return;
      out.addError(const TransportFailure());
    }
    await out.close();
  }

  out = StreamController<List<int>>(
    onListen: () {
      if (body == null) {
        unawaited(out.close());
      } else {
        unawaited(pump(body.getReader()));
      }
    },
    onResume: () {
      resumed?.complete();
      resumed = null;
    },
    onCancel: () {
      cancelled = true;
      resumed?.complete();
      resumed = null;
      // StreamController also calls onCancel after delivering its done event.
      if (!out.isClosed) abort.abort();
    },
  );
  return out.stream;
}

@JS('fetch')
external JSPromise<_Response> _fetch(String url, _RequestInit init);

@JS('AbortSignal.timeout')
external JSObject _timeoutSignal(int milliseconds);

@JS('location')
external _Location get _location;

@JS('document')
external _Document get _document;

@JS('AbortController')
extension type _AbortController._(JSObject _) implements JSObject {
  external factory _AbortController();
  external JSObject get signal;
  external void abort();
}

extension type _ReadableStream._(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

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
  external _ReadableStream? get body;
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

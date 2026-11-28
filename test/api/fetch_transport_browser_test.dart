@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:openmettle_app/api/src/fetch_transport.dart';
import 'package:openmettle_app/api/src/transport.dart';

/// Exercises the real Fetch bindings in a browser against the test runner's
/// own origin. It cannot exercise the core routes, cookies or HTTPS. Streamed
/// bodies come from same-origin `blob:` URLs, which the browser reads through
/// the same `ReadableStream` reader as a network body.
void main() {
  final transport = FetchTransport();

  test('reads the page origin', () {
    expect(Uri.parse(transport.origin).origin, transport.origin);
  });

  test('a same-origin answer is a basic response from that URL', () async {
    final url = Uri.parse('${transport.origin}/openmettle-absent-route');
    final reply = await transport.send('GET', url, accept: 'application/json');
    expect(reply.type, 'basic');
    expect(reply.redirected, isFalse);
    expect(reply.url, url);
    expect(reply.status, greaterThanOrEqualTo(200));
  });

  test('a fully consumed HTTP response retains its status in Chrome', () async {
    _clearResourceTimings();
    final url = Uri.parse('${transport.origin}/openmettle-completed-read');
    final reply = await transport.open(
      url,
      accept: 'application/json',
      cancel: Completer<void>().future,
    );
    await reply.body.drain<void>();
    await pumpEventQueue();
    final timing = _resourceTiming(url.toString(), 'resource').toDart.single;
    expect(reply.head.status, greaterThanOrEqualTo(200));
    expect(timing.responseStatus, reply.head.status);
  });

  test('a cross-origin request is never sent', () async {
    final url = Uri.parse('https://cross-origin.invalid/auth/session');
    await expectLater(
      transport.send('GET', url),
      throwsA(isA<TransportFailure>()),
    );
  });

  group('streamed reads', () {
    const size = 8 << 20;
    late Uri url;

    setUp(() {
      url = Uri.parse(_blobUrl(size));
      addTearDown(() => _revoke(url.toString()));
    });

    Future<StreamedReply> open({Future<void>? cancel}) => transport.open(
      url,
      accept: 'text/event-stream',
      cancel: cancel ?? Completer<void>().future,
    );

    test('reads the whole body in order', () async {
      final reply = await open();
      expect(reply.head.status, 200);
      expect(reply.head.type, 'basic');
      expect(reply.head.url, url);
      var length = 0;
      await for (final chunk in reply.body) {
        expect(chunk.every((byte) => byte == 0x61), isTrue);
        length += chunk.length;
      }
      expect(length, size);
    });

    test('a paused reader issues no further reads until resumed', () async {
      final reply = await open();
      var length = 0;
      var chunks = 0;
      final done = Completer<void>();
      late final StreamSubscription<List<int>> subscription;
      subscription = reply.body.listen((chunk) {
        length += chunk.length;
        if (++chunks == 1) subscription.pause();
      }, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      // At most one read completes after the pause.
      expect(chunks, lessThanOrEqualTo(2));
      expect(length, lessThan(size));
      subscription.resume();
      await done.future;
      expect(length, size);
    });

    test('a cancelled head is never delivered', () async {
      await expectLater(
        open(cancel: Future<void>.value()),
        throwsA(isA<TransportFailure>()),
      );
    });

    test('cancelling mid-body ends it with a transport failure', () async {
      final cancel = Completer<void>();
      final reply = await open(cancel: cancel.future);
      final seen = <Object>[];
      var length = 0;
      final done = Completer<void>();
      reply.body.listen(
        (chunk) {
          length += chunk.length;
          if (!cancel.isCompleted) cancel.complete();
        },
        onError: seen.add,
        onDone: done.complete,
      );
      await done.future;
      expect(seen, [isA<TransportFailure>()]);
      expect(length, lessThan(size));
    });

    test('cancelling the subscription stops reading', () async {
      final reply = await open();
      var chunks = 0;
      late final StreamSubscription<List<int>> subscription;
      subscription = reply.body.listen((_) {
        if (++chunks == 1) unawaited(subscription.cancel());
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(chunks, 1);
    });
  });
}

/// A same-origin `blob:` URL of [size] bytes `a`.
String _blobUrl(int size) {
  final bytes = JSUint8Array.withLength(size)..fill(0x61);
  return _createObjectUrl(_Blob([bytes].toJS));
}

extension on JSUint8Array {
  external void fill(int value);
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
}

@JS('URL.createObjectURL')
external String _createObjectUrl(_Blob blob);

@JS('URL.revokeObjectURL')
external void _revoke(String url);

@JS('performance.clearResourceTimings')
external void _clearResourceTimings();

@JS('performance.getEntriesByName')
external JSArray<_ResourceTiming> _resourceTiming(String name, String type);

extension type _ResourceTiming._(JSObject _) implements JSObject {
  external int get responseStatus;
}

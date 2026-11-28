import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../runs/run_replay.dart';
import '../../runs/run_wire.dart';
import '../client.dart';
import 'capabilities_reply.dart';
import 'endpoints.dart';
import 'http_session_client.dart';
import 'transport.dart';
import 'wire.dart';

/// The browser session client that also reads runs (core ADR 0034, error
/// model ADR 0007): `getRun` `GET /v1/runs/{run_id}` and `streamRunEvents`
/// `GET /v1/runs/{run_id}/events?after={cursor}`, on the page origin with
/// the browser's same-origin session cookie, which this client never sees.
///
/// Failures follow [RunReplaySource]: [RunReplayFailure] for verified
/// refusals and for temporary failures that may be retried; [ApiFailure]
/// (configuration, unsupported version, bad response), [FormatException] from
/// the event decoder and [ArgumentError] for an invalid run ID or cursor for
/// everything that a retry cannot fix. No error carries a URL, header value or
/// body.
class HttpRunSessionClient extends HttpSessionClient
    implements RunReplaySource {
  HttpRunSessionClient(this._streams, Endpoints endpoints)
    : _origin = endpoints.origin,
      super(_streams, endpoints);

  // Covers the complete snapshot or refusal, or the head of an event stream.
  static const _responseTimeout = Duration(seconds: 30);
  // Core sends a heartbeat at least every 15 s while a run is quiet.
  static const _idleTimeout = Duration(seconds: 45);

  final StreamingTransport _streams;
  final String _origin;

  static const _maxRunBytes = 1 << 20;
  static const _maxProblemBytes = 64 << 10;

  @override
  Future<RunSnapshot> snapshot(String runId) async {
    _checkRunId(runId);
    final url = Uri.parse('$_origin/v1/runs/$runId');
    final cancel = Completer<void>();
    final deadline = Timer(_responseTimeout, cancel.complete);
    var delivered = false;
    try {
      final reply = await _open(url, 'application/json', cancel.future);
      final head = reply.head;
      if (head.status != 200) {
        throw await _refusal(reply, url, stream: false);
      }
      _requireSuccess(head, url, 'application/json');
      final body = await _text(reply.body, _maxRunBytes, head);
      delivered = true;
      try {
        return RunSnapshot.parse(body, runId: runId);
      } on FormatException {
        badHttpReply(head);
      }
    } finally {
      deadline.cancel();
      // A completely received snapshot needs no abort; anything else may
      // still hold an unread body.
      if (!delivered && !cancel.isCompleted) cancel.complete();
    }
  }

  @override
  Stream<RunReplayEvent> events(String runId, String cursor) {
    try {
      _checkRunId(runId);
      if (!isCursor(cursor)) {
        throw ArgumentError('cursor must be a run cursor');
      }
    } on ArgumentError catch (error) {
      return Stream.error(error);
    }
    final url = Uri.parse('$_origin/v1/runs/$runId/events?after=$cursor');
    return decodeRunEvents(_eventBytes(url), runId: runId);
  }

  /// The event stream body. Refusals arrive as stream errors before any byte.
  /// A lost connection or a silent stream ends with
  /// [RunReplayFailure.unavailable] after every byte already received, so the
  /// decoder keeps each complete record. Cancelling aborts the request, also
  /// while the head is pending; pausing stops reading and the idle timer.
  Stream<List<int>> _eventBytes(Uri url) {
    final cancel = Completer<void>();
    late final StreamController<List<int>> out;
    StreamSubscription<List<int>>? body;
    Timer? timer;
    var closed = false;
    void finish([Object? error]) {
      if (closed) return;
      closed = true;
      timer?.cancel();
      if (error != null) {
        if (!cancel.isCompleted) cancel.complete();
        out.addError(error);
      }
      unawaited(out.close());
    }

    void arm() {
      timer?.cancel();
      timer = Timer(_idleTimeout, () => finish(RunReplayFailure.unavailable));
    }

    Future<void> start() async {
      timer = Timer(_responseTimeout, cancel.complete);
      final StreamedReply reply;
      try {
        // The deadline also covers a refusal body; [arm] replaces it once
        // the stream is accepted.
        reply = await _open(url, 'text/event-stream', cancel.future);
        if (closed) return;
        final head = reply.head;
        if (head.status != 200) {
          throw await _refusal(reply, url, stream: true);
        }
        _requireSuccess(head, url, 'text/event-stream');
      } catch (error) {
        finish(error);
        return;
      }
      arm();
      body = reply.body.listen(
        (chunk) {
          arm();
          out.add(chunk);
        },
        onError: (Object error) => finish(
          error is TransportFailure ? RunReplayFailure.unavailable : error,
        ),
        onDone: finish,
      );
      if (out.isPaused) {
        body!.pause();
        timer?.cancel();
      }
    }

    out = StreamController<List<int>>(
      onListen: () => unawaited(start()),
      onPause: () {
        body?.pause();
        if (body != null) timer?.cancel();
      },
      onResume: () {
        body?.resume();
        if (body != null && !closed) arm();
      },
      onCancel: () {
        // A naturally completed body releases its subscription without aborting.
        if (!closed && !cancel.isCompleted) cancel.complete();
        closed = true;
        timer?.cancel();
        return body?.cancel();
      },
    );
    return out.stream;
  }

  Future<StreamedReply> _open(
    Uri url,
    String accept,
    Future<void> cancel,
  ) async {
    try {
      return await _streams.open(url, accept: accept, cancel: cancel);
    } on TransportFailure {
      throw RunReplayFailure.unavailable;
    }
  }

  /// The failure a non-`200` reply stands for. Only a version-tagged,
  /// well-formed `Problem` with the code bound to its status is a refusal;
  /// a status-only `429` or `5xx` may come from an intermediary.
  Future<Object> _refusal(
    StreamedReply reply,
    Uri url, {
    required bool stream,
  }) async {
    final head = reply.head;
    final status = head.status;
    if (!isSameOriginReply(head, url)) badHttpReply(head);
    final version = head.headers['openmettle-api-version'];
    if (version != null) checkApiVersion(version, status: status);
    if (transientStatuses.contains(status)) return RunReplayFailure.unavailable;
    if (version == null) badHttpReply(head);
    if (status == 204 && stream) {
      if ((await _bytes(reply.body, 0, head)).isNotEmpty) badHttpReply(head);
      return RunReplayFailure.terminalAtCursor;
    }
    if (!hasMediaType(
      head.headers['content-type'],
      'application/problem+json',
    )) {
      badHttpReply(head);
    }
    final code = decodeProblemCode(
      await _text(reply.body, _maxProblemBytes, head),
      status,
    );
    return switch ((status, code)) {
      (400, 'invalid_cursor') when stream => RunReplayFailure.invalidCursor,
      (401, 'unauthenticated') => RunReplayFailure.unauthenticated,
      (403, 'policy') => RunReplayFailure.forbidden,
      (404, 'not_found') => RunReplayFailure.notFound,
      _ => badHttpReply(head),
    };
  }

  static void _requireSuccess(HttpReply head, Uri url, String mediaType) {
    if (!isSameOriginReply(head, url)) badHttpReply(head);
    final version = head.headers['openmettle-api-version'];
    if (version == null) badHttpReply(head);
    checkApiVersion(version, status: head.status);
    if (!hasMediaType(head.headers['content-type'], mediaType)) {
      badHttpReply(head);
    }
  }

  static void _checkRunId(String runId) {
    if (!isCanonicalRunId(runId)) {
      throw ArgumentError('runId must be a canonical lowercase UUID');
    }
  }

  /// The whole body as strict UTF-8 without a byte order mark (RFC 8259
  /// section 8.1), at most [limit] bytes.
  static Future<String> _text(
    Stream<List<int>> body,
    int limit,
    HttpReply head,
  ) async {
    final bytes = await _bytes(body, limit, head);
    // Checked on the raw bytes: `utf8.decode` silently drops a leading BOM.
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      badHttpReply(head);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      badHttpReply(head);
    }
  }

  /// The whole body; more than [limit] bytes is a bad response and aborts.
  static Future<Uint8List> _bytes(
    Stream<List<int>> body,
    int limit,
    HttpReply head,
  ) async {
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in body) {
        if (bytes.length + chunk.length > limit) badHttpReply(head);
        bytes.add(chunk);
      }
    } on TransportFailure {
      throw RunReplayFailure.unavailable;
    }
    return bytes.takeBytes();
  }
}

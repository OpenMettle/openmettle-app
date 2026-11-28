import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../conversations/history.dart';
import '../../runs/run_replay.dart';
import '../../runs/run_wire.dart';
import '../client.dart';
import 'capabilities_reply.dart';
import 'endpoints.dart';
import 'history_wire.dart';
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
///
/// It also reads conversation history ([ConversationSource]):
/// `listConversations` `GET /v1/conversations` in the caller's personal scope,
/// `listBranches` `GET /v1/conversations/{conversation_id}/branches` and
/// `listMessages`
/// `GET /v1/conversations/{conversation_id}/branches/{branch_id}/messages`.
/// Every request names an explicit `limit` and, to continue, the unchanged
/// `next_cursor`; core binds a cursor to the caller, operation, path and
/// limit. Each failure is a [HistoryFailure], except an [ArgumentError] for a
/// conversation or branch ID that is not a canonical UUID. A page larger than
/// the byte bound for its operation is [HistoryFailure.invalidResponse].
class HttpRunSessionClient extends HttpSessionClient
    implements RunReplaySource, ConversationSource {
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

  /// Items requested per conversation or branch page. A summary row is well
  /// under 1 KiB, so a full page fits [_maxListBytes] with room for unknown
  /// members.
  static const listPageSize = 50;
  static const _maxListBytes = 256 << 10;

  /// Pinned core writes up to 128 parts and 65,536 UTF-8 text bytes per turn.
  /// Ten turns fit the byte limit even when JSON escapes each text byte.
  static const messagePageSize = 10;
  static const _maxMessageBytes = 8 << 20;

  @override
  Future<RunSnapshot> snapshot(String runId) async {
    _checkRunId(runId);
    final url = Uri.parse('$_origin/v1/runs/$runId');
    final (head, body) = await _readJson(
      url,
      _maxRunBytes,
      unavailable: RunReplayFailure.unavailable,
      refusal: (status, code) => _runRefusal(status, code, stream: false),
    );
    try {
      return RunSnapshot.parse(body, runId: runId);
    } on FormatException {
      badHttpReply(head);
    }
  }

  @override
  Future<HistoryPage<ConversationSummary>> conversations({String? cursor}) =>
      _history(
        '/v1/conversations',
        listPageSize,
        _maxListBytes,
        cursor,
        (head, body) =>
            decodeConversationPage(body, limit: listPageSize, cursor: cursor),
      );

  @override
  Future<HistoryPage<BranchSummary>> branches(
    String conversationId, {
    String? cursor,
  }) async {
    _checkId(conversationId, 'conversationId');
    return _history(
      '/v1/conversations/$conversationId/branches',
      listPageSize,
      _maxListBytes,
      cursor,
      (head, body) => decodeBranchPage(
        body,
        conversationId: conversationId,
        limit: listPageSize,
        cursor: cursor,
      ),
    );
  }

  @override
  Future<HistoryPage<HistoryMessage>> messages(
    String conversationId,
    String branchId, {
    String? cursor,
  }) async {
    _checkId(conversationId, 'conversationId');
    _checkId(branchId, 'branchId');
    return _history(
      '/v1/conversations/$conversationId/branches/$branchId/messages',
      messagePageSize,
      _maxMessageBytes,
      cursor,
      (head, body) => decodeMessagePage(
        body,
        historyHeader: head.headers['openmettle-history-available'],
        limit: messagePageSize,
        cursor: cursor,
      ),
    );
  }

  /// One history page from [path] on the page origin. A [cursor] that is not
  /// a server-issued cursor is refused before anything is sent.
  Future<HistoryPage<T>> _history<T>(
    String path,
    int limit,
    int maxBytes,
    String? cursor,
    HistoryPage<T> Function(HttpReply head, String body) decode,
  ) async {
    if (cursor != null && !isCursor(cursor)) {
      throw HistoryFailure.invalidCursor;
    }
    final url = Uri.parse(
      '$_origin$path?limit=$limit${cursor == null ? '' : '&cursor=$cursor'}',
    );
    try {
      final (head, body) = await _readJson(
        url,
        maxBytes,
        unavailable: HistoryFailure.unavailable,
        refusal: (status, code) => switch ((status, code)) {
          (400, 'invalid_cursor') when cursor != null =>
            HistoryFailure.invalidCursor,
          (401, 'unauthenticated') => HistoryFailure.unauthenticated,
          (403, 'policy') || (404, 'not_found') => HistoryFailure.inaccessible,
          _ => null,
        },
      );
      return decode(head, body);
    } on ApiFailure {
      // Unsupported version, redirect, media type, refusal or body.
      throw HistoryFailure.invalidResponse;
    }
  }

  /// A complete `200` `application/json` body of at most [limit] bytes, read
  /// under one deadline for the head and the body. A lost or timed-out
  /// exchange and a transient status throw [unavailable]; a verified refusal
  /// throws what [refusal] maps it to, and an unmapped refusal or any
  /// contract violation throws [ApiFailure].
  Future<(HttpReply, String)> _readJson(
    Uri url,
    int limit, {
    required Object unavailable,
    required Object? Function(int status, String code) refusal,
  }) async {
    final cancel = Completer<void>();
    final deadline = Timer(_responseTimeout, cancel.complete);
    var delivered = false;
    try {
      final reply = await _open(
        url,
        'application/json',
        cancel.future,
        unavailable,
      );
      final head = reply.head;
      if (head.status != 200) {
        throw await _refusal(
          reply,
          url,
          stream: false,
          unavailable: unavailable,
          refusal: refusal,
        );
      }
      _requireSuccess(head, url, 'application/json');
      final body = await _text(reply.body, limit, head, unavailable);
      delivered = true;
      return (head, body);
    } finally {
      deadline.cancel();
      // A completely received body needs no abort; anything else may still
      // hold an unread body.
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
        reply = await _open(
          url,
          'text/event-stream',
          cancel.future,
          RunReplayFailure.unavailable,
        );
        if (closed) return;
        final head = reply.head;
        if (head.status != 200) {
          throw await _refusal(
            reply,
            url,
            stream: true,
            unavailable: RunReplayFailure.unavailable,
            refusal: (status, code) => _runRefusal(status, code, stream: true),
          );
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
    Object unavailable,
  ) async {
    try {
      return await _streams.open(url, accept: accept, cancel: cancel);
    } on TransportFailure {
      throw unavailable;
    }
  }

  static RunReplayFailure? _runRefusal(
    int status,
    String code, {
    required bool stream,
  }) => switch ((status, code)) {
    (400, 'invalid_cursor') when stream => RunReplayFailure.invalidCursor,
    (401, 'unauthenticated') => RunReplayFailure.unauthenticated,
    (403, 'policy') => RunReplayFailure.forbidden,
    (404, 'not_found') => RunReplayFailure.notFound,
    _ => null,
  };

  /// The failure a non-`200` reply stands for. Only a version-tagged,
  /// well-formed `Problem` with the code bound to its status is a refusal,
  /// mapped by [refusal]; a status-only `429` or `5xx` may come from an
  /// intermediary and is [unavailable].
  Future<Object> _refusal(
    StreamedReply reply,
    Uri url, {
    required bool stream,
    required Object unavailable,
    required Object? Function(int status, String code) refusal,
  }) async {
    final head = reply.head;
    final status = head.status;
    if (!isSameOriginReply(head, url)) badHttpReply(head);
    final version = head.headers['openmettle-api-version'];
    if (version != null) checkApiVersion(version, status: status);
    if (transientStatuses.contains(status)) return unavailable;
    if (version == null) badHttpReply(head);
    if (status == 204 && stream) {
      if ((await _bytes(reply.body, 0, head, unavailable)).isNotEmpty) {
        badHttpReply(head);
      }
      return RunReplayFailure.terminalAtCursor;
    }
    if (!hasMediaType(
      head.headers['content-type'],
      'application/problem+json',
    )) {
      badHttpReply(head);
    }
    final code = decodeProblemCode(
      await _text(reply.body, _maxProblemBytes, head, unavailable),
      status,
    );
    return refusal(status, code) ?? badHttpReply(head);
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

  static void _checkId(String id, String name) {
    if (!isUuid(id)) {
      throw ArgumentError('$name must be a canonical lowercase UUID');
    }
  }

  /// The whole body as strict UTF-8 without a byte order mark (RFC 8259
  /// section 8.1), at most [limit] bytes.
  static Future<String> _text(
    Stream<List<int>> body,
    int limit,
    HttpReply head,
    Object unavailable,
  ) async {
    final bytes = await _bytes(body, limit, head, unavailable);
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
  /// A lost connection throws [unavailable].
  static Future<Uint8List> _bytes(
    Stream<List<int>> body,
    int limit,
    HttpReply head,
    Object unavailable,
  ) async {
    final bytes = BytesBuilder(copy: false);
    try {
      await for (final chunk in body) {
        if (bytes.length + chunk.length > limit) badHttpReply(head);
        bytes.add(chunk);
      }
    } on TransportFailure {
      throw unavailable;
    }
    return bytes.takeBytes();
  }
}

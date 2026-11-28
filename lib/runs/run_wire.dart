import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api/src/wire.dart' show isTimestamp;

/// Wire decoding for core run replay (ADR 0034, ADR 0007): the `Run`
/// snapshot and the `RunEventStream` (`text/event-stream` of `RunEventItem`s
/// whose `data` is one JSON `RunEvent`).
///
/// Objects are extensible: unknown members, unknown event types and versions,
/// unknown states and unknown reason codes are tolerated. Every member the
/// client relies on is checked against the pinned schema. The projection
/// keeps only identity, position and status; event `data` is validated and
/// then dropped. Every violation throws the same [FormatException], which
/// never carries response content.

const _invalid = FormatException('Invalid run response');

Never _bad() => throw _invalid;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _code = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _type = RegExp(r'^[a-z][a-z0-9._-]{0,127}$');
final _cursor = RegExp(r'^[A-Za-z0-9_-]{1,512}$');
final _sequenceText = RegExp(r'^[1-9][0-9]{0,18}$');
final _retry = RegExp(r'^(?:0|[1-9][0-9]{0,5})$');
final _maxSequence = BigInt.parse('9223372036854775807');
const _maxTypeVersion = 2147483647;
const _maxStateLength = 64;
const _maxEventNameLength = 64;
const _maxRetry = 600000;
const _minItemData = 2;
const _maxItemData = 131072;

const _terminalStates = {'succeeded', 'failed', 'cancelled', 'interrupted'};
const _liveStates = {'queued', 'running', 'waiting', 'cancelling'};

/// Public v1 event types whose `type_version` 1 is a state transition, with
/// the run state each one establishes (ADR 0034 wire events).
const _transitions = {
  'run.created': 'queued',
  'run.started': 'running',
  'run.waiting': 'waiting',
  'run.resumed': 'running',
  'run.succeeded': 'succeeded',
  'run.failed': 'failed',
  'run.cancelled': 'cancelled',
  'run.interrupted': 'interrupted',
};

/// Version 1 types whose `data` is closed and empty in the pinned contract.
const _emptyData = {
  'run.created',
  'run.started',
  'run.resumed',
  'run.approval_requested',
  'run.approval_decided',
};

/// Version 1 types whose `data` is exactly `{"reason": Code}`.
const _reasonData = {'run.cancelled', 'run.failed'};

void _requireUuid(String runId) {
  if (!_uuid.hasMatch(runId)) {
    throw ArgumentError('runId must be a canonical lowercase UUID');
  }
}

BigInt _sequence(Object? value) {
  if (value is! String || !_sequenceText.hasMatch(value)) _bad();
  final sequence = BigInt.parse(value);
  if (sequence > _maxSequence) _bad();
  return sequence;
}

String _cursorValue(Object? value) {
  if (value is! String || !_cursor.hasMatch(value)) _bad();
  return value;
}

Object? _json(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    _bad();
  }
}

/// Run consistent snapshot from `GET /v1/runs/{run_id}`.
final class RunSnapshot {
  const RunSnapshot._({
    required this.runId,
    required this.state,
    required this.cursor,
    required this.sequence,
    required this.isTerminal,
  });

  /// Decodes a `Run` body for [runId]. The body's `run_id` and any terminal
  /// event must belong to [runId]; a terminal event must be the last event and
  /// agree with a recognized state.
  factory RunSnapshot.parse(String json, {required String runId}) {
    _requireUuid(runId);
    final root = _json(json);
    if (root is! Map<String, Object?>) _bad();
    if (root['run_id'] != runId) _bad();
    final conversationId = root['conversation_id'];
    if (conversationId is! String || !_uuid.hasMatch(conversationId)) _bad();
    for (final optional in const ['branch_id', 'input_message_id']) {
      final value = root[optional];
      if (root.containsKey(optional) &&
          (value is! String || !_uuid.hasMatch(value))) {
        _bad();
      }
    }
    final state = root['state'];
    if (state is! String ||
        state.isEmpty ||
        state.runes.length > _maxStateLength) {
      _bad();
    }
    if (!isTimestamp(root['created_at'])) _bad();
    final sequence = _sequence(root['last_sequence']);
    final cursor = _cursorValue(root['resume_cursor']);

    // Required and nullable: null is a live run or a terminal row written
    // before terminal events existed, where the state alone is authoritative.
    if (!root.containsKey('terminal')) _bad();
    final terminalValue = root['terminal'];
    RunReplayEvent? terminal;
    if (terminalValue != null) {
      terminal = RunReplayEvent._decode(
        terminalValue,
        runId: runId,
        cursor: cursor,
      );
      // The terminal event is the run's last event (ADR 0034 invariant 3).
      if (terminal.sequence != sequence) _bad();
      // A recognized live transition cannot be the terminal event.
      if (terminal.state != null && !terminal.isTerminal) _bad();
      // A recognized state must agree with a recognized terminal event.
      if (_liveStates.contains(state)) _bad();
      if (terminal.isTerminal &&
          _terminalStates.contains(state) &&
          state != terminal.state) {
        _bad();
      }
    }

    return RunSnapshot._(
      runId: runId,
      state: state,
      cursor: cursor,
      sequence: sequence,
      isTerminal: terminal != null || _terminalStates.contains(state),
    );
  }

  final String runId;

  /// Open state vocabulary as reported; unknown values are preserved.
  final String state;

  /// Opaque resume cursor at [sequence]; store it unchanged.
  final String cursor;

  /// `last_sequence`, exact on every platform.
  final BigInt sequence;

  /// The run has ended: a terminal event is present, or the state is a
  /// recognized terminal state. Such a run needs no stream.
  final bool isTerminal;
}

/// One visible run event: its position and, for recognized public v1 state
/// transitions, the state it establishes. Event `data` is not retained.
final class RunReplayEvent {
  const RunReplayEvent._({
    required this.runId,
    required this.cursor,
    required this.type,
    required this.sequence,
    required this.typeVersion,
  });

  factory RunReplayEvent._decode(
    Object? value, {
    required String runId,
    required String cursor,
  }) {
    if (value is! Map<String, Object?>) _bad();
    if (value['run_id'] != runId) _bad();
    final sequence = _sequence(value['sequence']);
    final type = value['type'];
    if (type is! String || !_type.hasMatch(type)) _bad();
    final typeVersion = _typeVersion(value['type_version']);
    if (!isTimestamp(value['occurred_at'])) _bad();
    final data = value['data'];
    if (data is! Map<String, Object?>) _bad();
    if (typeVersion == 1) _checkV1Data(type, data);
    return RunReplayEvent._(
      runId: runId,
      cursor: cursor,
      type: type,
      sequence: sequence,
      typeVersion: typeVersion,
    );
  }

  final String runId;

  /// Opaque resume cursor at [sequence] (the SSE `id`); store it unchanged.
  final String cursor;

  /// Open type vocabulary; unknown types are tolerated and only advance the
  /// cursor.
  final String type;

  /// Per-run position, exact on every platform.
  final BigInt sequence;

  final int typeVersion;

  /// The run state this event establishes, or null for an event that is not
  /// a recognized public v1 state transition (including unknown types and
  /// versions).
  String? get state => typeVersion == 1 ? _transitions[type] : null;

  /// This is the run's terminal event.
  bool get isTerminal => _terminalStates.contains(state);
}

int _typeVersion(Object? value) {
  // JSON Schema integers include 1.0; web and native decode it differently.
  if (value is! num || !value.isFinite || value != value.truncate()) _bad();
  if (value < 1 || value > _maxTypeVersion) _bad();
  return value.toInt();
}

/// Enforces the pinned contract's closed `data` schemas so private members
/// never reach the client unnoticed. Types without a pinned schema, including
/// `run.succeeded` and `run.interrupted`, accept any object.
void _checkV1Data(String type, Map<String, Object?> data) {
  if (_emptyData.contains(type)) {
    if (data.isNotEmpty) _bad();
  } else if (_reasonData.contains(type)) {
    final reason = data['reason'];
    if (data.length != 1 || reason is! String || !_code.hasMatch(reason)) {
      _bad();
    }
  } else if (type == 'run.waiting') {
    if (data.length != 1 || data['reason'] != 'approval') _bad();
  }
}

/// Decodes a `streamRunEvents` body for [runId].
///
/// Framing follows the SSE rules at the byte level, so records may split
/// across any chunk boundary, including inside a multi-byte character: lines
/// end in CRLF, LF or CR; each complete line is decoded as strict UTF-8; one
/// leading BOM, comments and unknown fields are ignored; `event` and `retry`
/// are validated and otherwise ignored. Each record needs one cursor `id` and
/// JSON `data`.
///
/// Every record is delivered as soon as its blank line arrives, so a later
/// malformed record cannot discard earlier events in the same chunk. A
/// sequence at or below the last delivered one is a replayed duplicate: it is
/// validated, then dropped without advancing (ADR 0007). Only the consumer
/// knows the position from its previous connection. It cancels after a
/// terminal event advances that position. A record not closed by a blank line before the body ends is
/// discarded, so truncation never advances a cursor. Buffers are bounded per
/// line and per record.
///
/// A malformed body produces one fixed [FormatException]; an error from
/// [bytes] is forwarded unchanged. Either ends the stream and cancels
/// [bytes]. Cancelling the subscription cancels [bytes] at once, also while
/// no bytes are arriving. Pausing pauses [bytes].
Stream<RunReplayEvent> decodeRunEvents(
  Stream<List<int>> bytes, {
  required String runId,
}) {
  _requireUuid(runId);
  StreamSubscription<List<int>>? source;
  Future<void>? releasing;
  late final StreamController<RunReplayEvent> out;

  void end([Object? error, StackTrace? stack]) {
    final subscription = source;
    source = null;
    if (subscription == null) return;
    if (error != null) out.addError(error, stack);
    releasing = subscription.cancel().catchError((Object _) {});
    unawaited(out.close());
  }

  out = StreamController<RunReplayEvent>(
    onListen: () {
      final framer = _SseFramer(runId, out.add);
      source = bytes.listen(
        (chunk) {
          if (source == null) return;
          try {
            framer.add(chunk);
          } on FormatException {
            end(_invalid);
          }
        },
        onError: end,
        onDone: () {
          source = null;
          unawaited(out.close());
        },
      );
    },
    onPause: () => source?.pause(),
    onResume: () => source?.resume(),
    onCancel: () {
      final subscription = source;
      source = null;
      return subscription?.cancel() ?? releasing;
    },
  );
  return out.stream;
}

/// Incremental SSE framing and event validation with bounded buffers.
final class _SseFramer {
  _SseFramer(this._runId, this._emit);

  // UTF-8 bytes of one line: `data: ` plus the largest item.
  static const _maxLineBytes = 4 * _maxItemData + 16;
  // UTF-16 code units of one record's data: any 131072-code-point value fits.
  static const _maxData = 2 * _maxItemData;

  final String _runId;
  final void Function(RunReplayEvent) _emit;

  final _line = BytesBuilder();
  bool _afterCr = false;
  bool _firstLine = true;

  String? _id;
  StringBuffer? _data;
  String? _event;
  String? _retryValue;

  BigInt? _last;

  void add(List<int> chunk) {
    var start = 0;
    for (var i = 0; i < chunk.length; i++) {
      final byte = chunk[i];
      if (byte == 0x0A && _afterCr) {
        // Second half of a CRLF whose CR already ended the line.
        _afterCr = false;
        start = i + 1;
        continue;
      }
      _afterCr = false;
      if (byte == 0x0A || byte == 0x0D) {
        _append(chunk, start, i);
        _afterCr = byte == 0x0D;
        _endLine();
        start = i + 1;
      }
    }
    _append(chunk, start, chunk.length);
  }

  void _append(List<int> chunk, int start, int end) {
    if (end <= start) return;
    if (_line.length + end - start > _maxLineBytes) _bad();
    _line.add(chunk.sublist(start, end));
  }

  void _endLine() {
    final String decoded;
    try {
      decoded = utf8.decode(_line.takeBytes());
    } on FormatException {
      _bad();
    }
    var line = decoded;
    if (_firstLine) {
      _firstLine = false;
      if (line.startsWith('\uFEFF')) line = line.substring(1);
    }
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        final data = _data;
        if (data == null) {
          if (value.length > _maxData) _bad();
          _data = StringBuffer(value);
        } else {
          if (data.length + 1 + value.length > _maxData) _bad();
          data
            ..write('\n')
            ..write(value);
        }
      case 'id':
        _id = value;
      case 'event':
        _event = value;
      case 'retry':
        _retryValue = value;
      // Unknown fields are ignored (SSE).
    }
  }

  void _dispatch() {
    final id = _id;
    final data = _data?.toString();
    final event = _event;
    final retry = _retryValue;
    _id = null;
    _data = null;
    _event = null;
    _retryValue = null;
    if (event != null && event.runes.length > _maxEventNameLength) _bad();
    if (retry != null &&
        (!_retry.hasMatch(retry) || int.parse(retry) > _maxRetry)) {
      _bad();
    }
    // A block with neither id nor data (for example only `retry`) is not an
    // item.
    if (id == null && data == null) return;
    if (id == null || data == null) _bad();
    final length = data.runes.length;
    if (length < _minItemData || length > _maxItemData) _bad();
    final decoded = RunReplayEvent._decode(
      _json(data),
      runId: _runId,
      cursor: _cursorValue(id),
    );
    final last = _last;
    if (last != null && decoded.sequence <= last) return;
    _last = decoded.sequence;
    _emit(decoded);
  }
}

import 'dart:convert';

import '../../conversations/history.dart';
import 'wire.dart';

/// Decoders for core's read-only history pages (`ConversationPage`,
/// `BranchPage`, `MessagePage` in the pinned OpenAPI document). Objects are
/// extensible, so unknown members are ignored; every member the client relies
/// on, and each required member, is checked against its schema. Any violation
/// is [HistoryFailure.invalidResponse] and carries none of the body.
///
/// Each page is also checked against the request that produced it: at most
/// [limit] items, unique item IDs, a `next_cursor` only after a non-empty page
/// and never the cursor that was sent.

final _decimal = RegExp(r'^(0|[1-9][0-9]{0,18})$');
const _maxDecimal = '9223372036854775807';
const _maxParts = 128;
const _maxText = 65536;
const _maxVocabulary = 256;

Never _invalid() => throw HistoryFailure.invalidResponse;

/// An unscoped listConversations request returns only the caller's personal scope.
HistoryPage<ConversationSummary> decodeConversationPage(
  String body, {
  required int limit,
  String? cursor,
}) {
  final (items, next) = _page(body, limit, cursor);
  final seen = <String>{};
  final conversations = <ConversationSummary>[];
  String? scope;
  for (final value in items) {
    final item = _object(value);
    final id = _id(item['conversation_id']);
    final scopeId = _id(item['scope_id']);
    scope ??= scopeId;
    if (scopeId != scope ||
        !seen.add(id) ||
        item['scope_kind'] != 'personal' ||
        _nullableId(item, 'project_id') != null) {
      _invalid();
    }
    _codeValue(item['access']);
    if (item['can_manage_shares'] is! bool) _invalid();
    conversations.add(
      ConversationSummary(id: id, createdAt: _timestamp(item['created_at'])),
    );
  }
  return HistoryPage(conversations, nextCursor: next);
}

/// `listBranches` for [conversationId]: every item must belong to it.
HistoryPage<BranchSummary> decodeBranchPage(
  String body, {
  required String conversationId,
  required int limit,
  String? cursor,
}) {
  final (items, next) = _page(body, limit, cursor);
  final seen = <String>{};
  final branches = [
    for (final item in items) _branch(_object(item), conversationId, seen),
  ];
  return HistoryPage(branches, nextCursor: next);
}

BranchSummary _branch(
  Map<String, Object?> item,
  String conversationId,
  Set<String> seen,
) {
  if (_id(item['conversation_id']) != conversationId) _invalid();
  final id = _id(item['branch_id']);
  if (!seen.add(id)) _invalid();
  final createdAt = _timestamp(item['created_at']);
  final available = item['history_available'];
  if (available is! bool) _invalid();
  final parent = _nullableId(item, 'parent_branch_id');
  _nullableId(item, 'fork_message_id');
  _nullableId(item, 'head_message_id');
  return BranchSummary(
    id: id,
    createdAt: createdAt,
    parentBranchId: parent,
    historyAvailable: available,
  );
}

/// `listMessages`: one contiguous run of the pinned path, head toward root.
///
/// [historyHeader] is the `OpenMettle-History-Available` value. Core sends
/// `false` for a legacy branch without a managed head, whose history is not
/// readable: that page must be empty and final. Any other value is invalid.
HistoryPage<HistoryMessage> decodeMessagePage(
  String body, {
  required String? historyHeader,
  required int limit,
  String? cursor,
}) {
  if (historyHeader != null && historyHeader != 'false') _invalid();
  final available = historyHeader == null;
  final (items, next) = _page(body, limit, cursor);
  if (!available && (items.isNotEmpty || next != null)) _invalid();
  final seen = <String>{};
  final messages = <HistoryMessage>[];
  String? expectedId;
  for (final (index, item) in items.indexed) {
    final object = _object(item);
    final (message, parentId) = _message(object, seen);
    // One path: each turn's parent is the next item on the page.
    if (index > 0 && message.id != expectedId) _invalid();
    expectedId = parentId;
    messages.add(message);
  }
  return HistoryPage(messages, nextCursor: next, historyAvailable: available);
}

(HistoryMessage, String?) _message(
  Map<String, Object?> item,
  Set<String> seen,
) {
  final id = _id(item['message_id']);
  if (!seen.add(id)) _invalid();
  final parentId = _nullableId(item, 'parent_message_id');
  final role = _vocabulary(item['role']);
  final runId = _nullableId(item, 'run_id');
  _nullableDecimal(item, 'input_count');
  _nullableDecimal(item, 'output_count');
  // Optional: older cores omit it. A user turn never stops early.
  final stop = item['stop_reason'];
  if (stop != null) {
    _codeValue(stop);
    if (role == 'user') _invalid();
  }
  final parts = item['parts'];
  if (parts is! List<Object?> || parts.length > _maxParts) _invalid();
  final partIds = <String>{};
  return (
    HistoryMessage(
      id: id,
      role: role,
      runId: runId,
      stopReason: stop as String?,
      parts: [for (final part in parts) _part(_object(part), partIds)],
    ),
    parentId,
  );
}

/// A `VisiblePart`. `kind` is an open vocabulary: an unrecognized part keeps
/// only its kind, so no payload of an unknown kind can be presented as text.
HistoryPart _part(Map<String, Object?> part, Set<String> seen) {
  if (!seen.add(_id(part['part_id']))) _invalid();
  final kind = _vocabulary(part['kind']);
  final text = part['text'];
  if (part.containsKey('text') && !_isText(text)) _invalid();
  final revision = part['revision_id'];
  if (part.containsKey('revision_id')) _id(revision);
  final state = part['state'];
  if (part.containsKey('state')) _vocabulary(state);
  switch (kind) {
    case 'text':
      if (text == null) _invalid();
      return HistoryPart(kind: kind, text: text as String);
    case 'attachment':
      if (revision == null || state == null) _invalid();
      return HistoryPart(
        kind: kind,
        revisionId: revision as String,
        state: state as String,
      );
    default:
      return HistoryPart(kind: kind);
  }
}

/// The common `{items, page_info}` envelope.
(List<Object?>, String?) _page(String body, int limit, String? cursor) {
  final Object? root;
  try {
    root = jsonDecode(body);
  } on FormatException {
    _invalid();
  }
  if (root is! Map<String, Object?>) _invalid();
  final items = root['items'];
  if (items is! List<Object?> || items.length > limit) _invalid();
  final info = root['page_info'];
  if (info is! Map<String, Object?> || !info.containsKey('next_cursor')) {
    _invalid();
  }
  final next = info['next_cursor'];
  if (next != null) {
    // A continuation must make progress.
    if (next is! String || !isCursor(next) || next == cursor) _invalid();
    if (items.isEmpty) _invalid();
  }
  return (items, next as String?);
}

Map<String, Object?> _object(Object? value) =>
    value is Map<String, Object?> ? value : _invalid();

String _id(Object? value) =>
    value is String && isUuid(value) ? value : _invalid();

/// A required member whose value is a `Uuid` or `null`.
String? _nullableId(Map<String, Object?> item, String name) {
  if (!item.containsKey(name)) _invalid();
  final value = item[name];
  return value == null ? null : _id(value);
}

void _nullableDecimal(Map<String, Object?> item, String name) {
  if (!item.containsKey(name)) _invalid();
  final value = item[name];
  if (value == null) return;
  if (value is! String || !_decimal.hasMatch(value)) _invalid();
  if (value.length == _maxDecimal.length && value.compareTo(_maxDecimal) > 0) {
    _invalid();
  }
}

String _timestamp(Object? value) =>
    isTimestamp(value) ? value as String : _invalid();

/// Core's open-vocabulary `Code`, kept verbatim.
String _codeValue(Object? value) =>
    isCode(value) ? value as String : _invalid();

/// A free-form open vocabulary (`role`, part `kind` and `state`): 1 to 256
/// characters, kept verbatim.
String _vocabulary(Object? value) =>
    value is String && value.isNotEmpty && _within(value, _maxVocabulary)
    ? value
    : _invalid();

bool _isText(Object? value) => value is String && _within(value, _maxText);

/// At most [max] Unicode code points (the JSON Schema length), which never
/// exceeds the UTF-16 length.
bool _within(String value, int max) =>
    value.length <= max || value.runes.length <= max;

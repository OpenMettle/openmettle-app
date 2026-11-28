import 'dart:convert';

import '../client.dart';

/// Wire decoding for the core v1 contract (ADR 0007): response objects are
/// extensible, so unknown members are ignored; every member the client relies
/// on is checked against its schema. A violation is
/// [ApiFailureKind.badResponse].

const _maxCapabilities = 256;
final _capabilityId = RegExp(r'^[a-z][a-z0-9._-]{0,63}$');
final _code = RegExp(r'^[a-z][a-z0-9_]{0,63}$');
final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);
final _timestamp = RegExp(
  r'^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})\.[0-9]{6}Z$',
);
final _cursor = RegExp(r'^[A-Za-z0-9_-]{1,512}$');
const _observedStates = {'ready', 'degraded', 'unavailable'};

/// An opaque server-issued `Cursor`: 1 to 512 base64url characters.
bool isCursor(String value) => _cursor.hasMatch(value);

/// Core's `Uuid`: a canonical lowercase UUID.
bool isUuid(String value) => _uuid.hasMatch(value);

/// Core's open-vocabulary `Code`.
bool isCode(Object? value) => value is String && _code.hasMatch(value);

Never _bad(int? status) =>
    throw ApiFailure(ApiFailureKind.badResponse, status: status);

/// Checks `OpenMettle-API-Version`: canonical `major.minor`, major 1, any
/// minor. Mirrors core `tests/contract/consumer.rs` `check_api_version`.
void checkApiVersion(String value, {int? status}) {
  final parts = value.split('.');
  bool canonical(String s) =>
      s.isNotEmpty &&
      s.length <= 7 &&
      s.codeUnits.every((c) => c >= 0x30 && c <= 0x39) &&
      !(s.length > 1 && s.startsWith('0'));
  if (parts.length != 2 || !parts.every(canonical)) _bad(status);
  if (parts[0] != '1') {
    throw ApiFailure(ApiFailureKind.unsupportedVersion, status: status);
  }
}

/// Whether [contentType] is [mediaType], optionally with `charset=utf-8`,
/// compared case-insensitively.
bool hasMediaType(String? contentType, String mediaType) {
  if (contentType == null) return false;
  final parts = contentType.split(';').map((p) => p.trim()).toList();
  if (parts.first.toLowerCase() != mediaType) return false;
  if (parts.length == 1) return true;
  return parts.length == 2 &&
      parts[1].replaceAll(' ', '').toLowerCase() == 'charset=utf-8';
}

Object? _json(String body, int status) {
  try {
    return jsonDecode(body);
  } on FormatException {
    _bad(status);
  }
}

/// RFC 3339 UTC with exactly six fractional digits and `Z`, naming a real
/// calendar instant.
bool isTimestamp(Object? value) {
  if (value is! String) return false;
  final match = _timestamp.firstMatch(value);
  if (match == null) return false;
  final [year, month, day, hour, minute, second] = [
    for (var i = 1; i <= 6; i++) int.parse(match.group(i)!),
  ];
  if (month < 1 || month > 12 || day < 1) return false;
  final daysInMonth = DateTime.utc(year, month + 1, 0).day;
  return day <= daysInMonth &&
      hour < 24 &&
      minute < 60 &&
      (second < 60 || (second == 60 && hour == 23 && minute == 59));
}

/// Decodes a `CapabilityList` body into [Capability] values.
List<Capability> decodeCapabilityList(String body, {int status = 200}) {
  final root = _json(body, status);
  if (root is! Map<String, Object?>) _bad(status);
  if (!isTimestamp(root['generated_at'])) _bad(status);
  final items = root['capabilities'];
  if (items is! List<Object?> || items.length > _maxCapabilities) _bad(status);
  final seen = <String>{};
  return [for (final item in items) _capability(item, status, seen)];
}

Capability _capability(Object? item, int status, Set<String> seen) {
  if (item is! Map<String, Object?>) _bad(status);
  final id = item['id'];
  final kind = item['kind'];
  final installed = item['installed'];
  final authorization = item['authorization'];
  if (id is! String || !_capabilityId.hasMatch(id) || !seen.add(id)) {
    _bad(status);
  }
  if (kind is! String || !_code.hasMatch(kind)) _bad(status);
  if (installed is! bool) _bad(status);
  // Required and nullable: absent is a violation, null is "not determined".
  if (!item.containsKey('authorization') ||
      (authorization != null && authorization is! bool)) {
    _bad(status);
  }
  // readiness is present exactly when installed.
  if (item.containsKey('readiness') != installed) _bad(status);
  String? readiness;
  if (installed) {
    final r = item['readiness'];
    if (r is! Map<String, Object?>) _bad(status);
    final state = r['state'];
    if (state is! String || !_code.hasMatch(state)) _bad(status);
    final observed = r.containsKey('observed_at');
    if (observed && !isTimestamp(r['observed_at'])) _bad(status);
    if (_observedStates.contains(state) && !observed) _bad(status);
    final reason = r['reason'];
    if (r.containsKey('reason') &&
        (reason is! String || !_code.hasMatch(reason))) {
      _bad(status);
    }
    readiness = state;
  }
  return Capability(
    id: id,
    kind: kind,
    installed: installed,
    authorization: authorization as bool?,
    readiness: readiness,
  );
}

/// Decodes an RFC 9457 `Problem` and returns its `code`. The body's `status`
/// must equal the HTTP [status].
String decodeProblemCode(String body, int status) {
  final root = _json(body, status);
  if (root is! Map<String, Object?>) _bad(status);
  final type = root['type'];
  final title = root['title'];
  final code = root['code'];
  final requestId = root['request_id'];
  final detail = root['detail'];
  if (type is! String || type.length > 256) _bad(status);
  if (title is! String || title.isEmpty || title.length > 128) _bad(status);
  if (root['status'] != status) _bad(status);
  if (code is! String || !_code.hasMatch(code)) _bad(status);
  if (requestId is! String || !_uuid.hasMatch(requestId)) _bad(status);
  if (root.containsKey('detail') &&
      (detail is! String || detail.isEmpty || detail.length > 512)) {
    _bad(status);
  }
  return code;
}

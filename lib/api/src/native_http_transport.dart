import 'dart:convert';
import 'dart:io';

import 'native_session_client.dart';
import 'transport.dart';

class NativeHttpTransport implements NativeTransport {
  const NativeHttpTransport();

  static const _timeout = Duration(seconds: 10);
  static const _maxBodyBytes = 256 * 1024;

  @override
  Future<HttpReply> send(
    String method,
    Uri url, {
    String? accept,
    String? bearer,
    String? jsonBody,
  }) async {
    final client = HttpClient()..autoUncompress = false;
    try {
      return await _request(
        client,
        method,
        url,
        accept: accept,
        bearer: bearer,
        jsonBody: jsonBody,
      ).timeout(_timeout);
    } catch (_) {
      // HTTP and TLS exceptions can include URL or header values.
      throw const TransportFailure();
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpReply> _request(
    HttpClient client,
    String method,
    Uri url, {
    String? accept,
    String? bearer,
    String? jsonBody,
  }) async {
    if (url.scheme != 'https' ||
        !url.hasAuthority ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment) {
      throw const TransportFailure();
    }
    final request = await client.openUrl(method, url);
    request.followRedirects = false;
    request.persistentConnection = false;
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    if (accept != null) request.headers.set(HttpHeaders.acceptHeader, accept);
    if (bearer != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    }
    final bytes = jsonBody == null ? const <int>[] : utf8.encode(jsonBody);
    request.contentLength = bytes.length;
    if (jsonBody != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(bytes);
    }
    final response = await request.close();
    if (response.statusCode >= 300 && response.statusCode < 400) {
      return HttpReply(status: response.statusCode, url: url, redirected: true);
    }
    if (response.contentLength > _maxBodyBytes) throw const TransportFailure();
    final body = <int>[];
    await for (final chunk in response) {
      if (body.length + chunk.length > _maxBodyBytes) {
        throw const TransportFailure();
      }
      body.addAll(chunk);
    }
    return HttpReply(
      status: response.statusCode,
      url: url,
      headers: {
        for (final name in Transport.headerNames)
          if (response.headers[name] case final values?)
            name: values.join(', '),
      },
      body: utf8.decode(body),
    );
  }
}

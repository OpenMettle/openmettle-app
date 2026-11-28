import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../client.dart';
import 'native_http_transport.dart';
import 'native_profile.dart';
import 'native_session_client.dart';

SessionClient createAppClient() {
  if (!Platform.isAndroid) {
    throw UnsupportedError('OpenMettle sign-in requires web or Android.');
  }
  final profile = NativeProfile.parse(
    const String.fromEnvironment('OPENMETTLE_NATIVE_ISSUER'),
    const String.fromEnvironment('OPENMETTLE_NATIVE_CLIENT_ID'),
    const String.fromEnvironment('OPENMETTLE_NATIVE_REDIRECT_URI'),
  );
  return NativeSessionClient(
    profile,
    _AndroidAuth(),
    const NativeHttpTransport(),
  );
}

class _AndroidAuth implements NativeAuthPlatform {
  _AndroidAuth() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'linkAvailable') _links.add(null);
    });
  }

  static const _channel = MethodChannel('org.openmettle.app/native_auth');
  final _links = StreamController<void>.broadcast();

  @override
  Stream<void> get linkAvailable => _links.stream;

  @override
  Future<({String state, String verifier, String challenge})>
  newAttempt() async {
    final result = await _channel.invokeMapMethod<String, String>('newAttempt');
    return (
      state: result!['state']!,
      verifier: result['verifier']!,
      challenge: result['challenge']!,
    );
  }

  @override
  Future<String?> readSecret(String key) =>
      _channel.invokeMethod<String>('readSecret', {'key': key});

  @override
  Future<void> writeSecret(String key, String? value) =>
      _channel.invokeMethod<void>('writeSecret', {'key': key, 'value': value});

  @override
  Future<void> launchBrowser(Uri url) =>
      _channel.invokeMethod<void>('launchBrowser', {'url': url.toString()});

  @override
  Future<String?> takeLink() => _channel.invokeMethod<String>('takeLink');
}

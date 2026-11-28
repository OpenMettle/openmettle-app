import '../client.dart';

/// No browser session exists outside a web build. Tests inject their own
/// [SessionClient] instead of calling this.
SessionClient createBrowserClient() =>
    throw UnsupportedError('The browser session client requires a web build.');

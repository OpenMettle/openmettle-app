/// Creates the browser [SessionClient]. Web builds use same-origin cookie
/// mode; other platforms get a stub that refuses to construct a client, so
/// widget tests on the Dart VM can compile code that imports this file.
library;

export 'src/browser_client_stub.dart'
    if (dart.library.js_interop) 'src/browser_client_web.dart';

export 'src/app_client_native.dart'
    if (dart.library.js_interop) 'src/browser_client_web.dart'
    show createAppClient;

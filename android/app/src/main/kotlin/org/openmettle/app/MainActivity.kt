package org.openmettle.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeAuth: NativeAuthChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeAuth = NativeAuthChannel(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        nativeAuth?.close()
        nativeAuth = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // This activity is exported as the launcher. Neither intent data nor a "route" extra from
    // another app selects a Flutter route; Dart starts at its default route.
    override fun getInitialRoute(): String? = null

    override fun shouldHandleDeeplinking(): Boolean = false
}

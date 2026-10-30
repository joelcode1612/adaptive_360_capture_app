package com.adaptive360.adaptive_360_capture_app

import com.adaptive360.adaptive_360_capture_app.ar.ArCoreCapturePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /**
     * Registers the ARCore host.
     *
     * The host ships inside this app rather than as a pub package, so the
     * generated plugin registrar does not know about it. Adding it here — before
     * the activity is attached — is also what lets it implement `ActivityAware`,
     * which it needs for ARCore's install request and for reading the display
     * rotation it feeds to `Session.setDisplayGeometry`.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ArCoreCapturePlugin())
    }
}

package com.sinhaankur.structura

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/// The Android entry point — and where the native capture plugin gets **connected**.
///
/// Without this, the `structura/capture` MethodChannel has no handler on the
/// Android side, so every call from Dart fails with a MissingPluginException and
/// nothing captures. `configureFlutterEngine` is the hook Flutter gives us to wire
/// a hand-written plugin against the engine's messenger.
///
/// `flutter create .` generates the rest of the Android host (Gradle, manifest,
/// the default MainActivity). This file replaces that default MainActivity with
/// one that registers our ARCore-Depth capture plugin.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register auto-discovered plugins (share_plus, gal, etc.).
        // (GeneratedPluginRegistrant is invoked by the framework in v2 embedding.)

        // Wire OUR capture plugin to the engine's messenger.
        StructuraCapturePlugin(this)
            .register(flutterEngine.dartExecutor.binaryMessenger)
    }
}

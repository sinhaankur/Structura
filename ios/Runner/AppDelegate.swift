import Flutter
import UIKit

/// The app entry point — and where the native capture plugin gets **connected**.
///
/// Without this registration the `structura/capture` MethodChannel has no handler
/// on the native side, so every call from Dart (`querySupport`, `start`,
/// `finish`, …) fails with `MissingPluginException` and nothing captures. This is
/// the glue that makes the LiDAR pipeline actually run on device.
///
/// `flutter create .` (run once in the repo root) generates the rest of the iOS
/// Runner (Runner.xcodeproj, Flutter build configs, the Runner-Bridging-Header,
/// GeneratedPluginRegistrant). This file replaces the default AppDelegate it
/// makes, adding the one line that wires our plugin.
@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register any auto-discovered Flutter plugins (share_plus, gal, etc.).
    GeneratedPluginRegistrant.register(with: self)

    // Register OUR capture plugin against the root Flutter engine's messenger.
    if let controller = window?.rootViewController as? FlutterViewController {
      if #available(iOS 13.4, *) {
        StructuraCapturePlugin.register(
          with: registrar(forPlugin: "StructuraCapturePlugin")!
        )
        _ = controller // silence unused when the plugin registers via registrar
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

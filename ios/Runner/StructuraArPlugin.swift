import Foundation
import Flutter
import ARKit
import QuickLook

/// iOS AR bridge — view a scan at real scale via **AR Quick Look**.
///
/// Implements the `structura/ar` MethodChannel that `lib/ar/ar_service.dart` calls:
///   • `isSupported` → true when the device does AR (ARKit world tracking).
///   • `viewInAR(path)` → present the USDZ at `path` in QLPreviewController's AR
///     mode, so the user can place + walk the scan at true metric scale. The scan
///     is exported to USDZ by the export channel first; here we just present it.
///
/// AR Quick Look handles placement, real-world scale, occlusion, and walk-around
/// for free — no custom renderer needed for v1, and it's honest by construction
/// (the mesh is in metres, so it lands at real size).
///
/// Wiring (AppDelegate):
///   StructuraArPlugin.register(with: registrar(forPlugin: "StructuraArPlugin")!)
@available(iOS 12.0, *)
final class StructuraArPlugin: NSObject, FlutterPlugin {

  private var previewItemURL: URL?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StructuraArPlugin()
    let channel = FlutterMethodChannel(name: "structura/ar",
                                       binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isSupported":
      result(ARWorldTrackingConfiguration.isSupported)
    case "viewInAR":
      guard let args = call.arguments as? [String: Any],
            let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      presentAR(path: path, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func presentAR(path: String, result: @escaping FlutterResult) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
      result(FlutterError(code: "no_file", message: "USDZ not found at \(path)", details: nil))
      return
    }
    guard let root = UIApplication.shared.keyWindow?.rootViewController
            ?? UIApplication.shared.windows.first?.rootViewController else {
      result(FlutterError(code: "no_vc", message: "no view controller to present from", details: nil))
      return
    }
    self.previewItemURL = url
    let preview = QLPreviewController()
    preview.dataSource = self
    // AR Quick Look is the default preview for a .usdz; the user taps "AR" to place.
    root.present(preview, animated: true) { result(nil) }
  }
}

@available(iOS 12.0, *)
extension StructuraArPlugin: QLPreviewControllerDataSource {
  func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewItemURL == nil ? 0 : 1
  }
  func previewController(_ controller: QLPreviewController,
                         previewItemAt index: Int) -> QLPreviewItem {
    previewItemURL! as QLPreviewItem
  }
}

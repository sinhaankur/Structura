import 'package:flutter/services.dart';

import '../export/export_service.dart';
import '../export/exporters.dart';
import '../model/scan.dart';

/// ar_service — view/walk the scanned space at REAL scale in AR.
///
/// The scan is measured in metres, so it can be placed back into the world at
/// true size: stand your captured condo in the room as a hologram, walk around a
/// scanned object on your desk. On iOS this uses **AR Quick Look** — export the
/// scan to USDZ (the native Model I/O exporter already exists), then hand the file
/// to the system AR viewer, which handles placement, scale, and walk-around for
/// free. No custom AR renderer needed for v1; honest real-scale by construction.
///
/// Android: ARCore Scene Viewer takes a glTF/GLB the same way (wired later).
class ArService {
  static const _channel = MethodChannel('structura/ar');

  final ExportService _export;
  ArService([ExportService? export]) : _export = export ?? ExportService();

  /// True when this device can present AR (has ARKit/ARCore + the viewer).
  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// Export the scan to an AR-ready file and open the system AR viewer on it, so
  /// the user can place + walk the scan at real scale. Returns when the viewer is
  /// dismissed. Throws [ArException] on failure (no support, export failed).
  Future<void> viewInAR(Scan scan) async {
    // USDZ for Apple AR Quick Look; the native exporter round-trips the mesh.
    final String path;
    try {
      path = await _export.writeToFile(scan, ExportFormat.usdz);
    } on Object catch (e) {
      throw ArException('Could not prepare the scan for AR: $e');
    }
    try {
      await _channel.invokeMethod<void>('viewInAR', {'path': path});
    } on PlatformException catch (e) {
      throw ArException(e.message ?? 'AR view failed');
    }
  }
}

class ArException implements Exception {
  ArException(this.message);
  final String message;
  @override
  String toString() => 'ArException: $message';
}

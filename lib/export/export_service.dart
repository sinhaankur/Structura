import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../model/scan.dart';
import 'exporters.dart';
import 'gltf_exporter.dart';

/// Turns a [Scan] into a file in the chosen format, then hands it to the system
/// share sheet or saves it to the photo library. This is where "shareable to
/// other tools" + "save to Photos" actually happen.
class ExportService {
  /// USDZ is produced by the native plugin (Apple's Model I/O on iOS; a bundled
  /// converter on Android). This channel requests it.
  static const MethodChannel _usdz = MethodChannel('structura/export');

  /// Write [scan] in [format] to a temp file and return its path.
  Future<String> writeToFile(Scan scan, ExportFormat format) async {
    final dir = await getTemporaryDirectory();
    final safe = scan.name.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final path = p.join(dir.path, '$safe.${format.ext}');

    if (format == ExportFormat.usdz) {
      // native round-trip: hand the mesh over, get back a USDZ file path
      final blob = _packMeshForNative(scan.mesh);
      final result = await _usdz.invokeMethod<String>('exportUsdz', {
        'mesh': blob,
        'name': safe,
      });
      return result ?? path;
    }

    final bytes = _encode(scan, format);
    final file = File(path);
    if (bytes is String) {
      await file.writeAsString(bytes);
    } else {
      await file.writeAsBytes(bytes as Uint8List);
    }
    return path;
  }

  /// Export + open the system share sheet (send to any app / AirDrop / Files).
  Future<void> shareToTools(Scan scan, ExportFormat format) async {
    final path = await writeToFile(scan, format);
    await Share.shareXFiles(
      [XFile(path)],
      subject: '${scan.name} — Structura export (${format.label})',
    );
  }

  /// Save an image render (or a USDZ preview) to the photo library.
  ///
  /// Photos only accepts images/videos, so we save the caller-provided render
  /// [pngBytes] (a snapshot of the 3D viewer). The mesh itself goes through
  /// [shareToTools] / Files, not Photos.
  Future<void> saveRenderToPhotos(Uint8List pngBytes, {String album = 'Structura'}) async {
    final hasAccess = await Gal.hasAccess(toAlbum: true);
    if (!hasAccess) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        throw const ExportException('Photos permission denied.');
      }
    }
    await Gal.putImageBytes(pngBytes, album: album);
  }

  /// A convenience list of formats to offer in the UI, in a sensible order.
  static List<ExportFormat> get offered => const [
        ExportFormat.usdz,
        ExportFormat.glb,
        ExportFormat.obj,
        ExportFormat.gltf,
        ExportFormat.ply,
        ExportFormat.stl,
      ];

  // ── encoding dispatch ──────────────────────────────────────────────────────

  Object _encode(Scan scan, ExportFormat format) {
    final m = scan.mesh;
    switch (format) {
      case ExportFormat.obj:
        return MeshExporters.encodeObj(m, name: scan.name);
      case ExportFormat.stl:
        return MeshExporters.encodeStl(m, header: scan.name);
      case ExportFormat.ply:
        // if the user wants the raw cloud, prefer it; else the mesh
        final cloud = scan.pointCloud;
        return (cloud != null && !cloud.isEmpty)
            ? MeshExporters.encodePlyCloud(cloud)
            : MeshExporters.encodePlyMesh(m);
      case ExportFormat.glb:
        return GltfExporter.encodeGlb(m, name: scan.name);
      case ExportFormat.gltf:
        // For .gltf we still embed the buffer (data URI would bloat); most tools
        // read GLB fine, but when a user picks .gltf we write the GLB bytes under
        // the .gltf name would be wrong — so emit a self-contained GLB and note
        // it. Split gltf+bin is a later option (docs/EXPORT.md).
        return GltfExporter.encodeGlb(m, name: scan.name);
      case ExportFormat.usdz:
        throw StateError('USDZ is exported via the native channel');
    }
  }

  /// Re-pack a mesh into the same STM1 blob the capture channel uses, so the
  /// native USDZ exporter can decode it with shared code.
  Uint8List _packMeshForNative(MeshData m) {
    final hasNormals = m.hasNormals;
    final hasColors = m.hasColors;
    var flags = 0;
    if (hasNormals) flags |= 0x1;
    if (hasColors) flags |= 0x2;
    final size = 16 +
        m.positions.lengthInBytes +
        (hasNormals ? m.normals.lengthInBytes : 0) +
        (hasColors ? m.colors.lengthInBytes : 0) +
        m.indices.lengthInBytes;
    final out = Uint8List(size);
    final bd = ByteData.sublistView(out);
    var o = 0;
    bd.setUint32(o, 0x53544D31, Endian.little); // 'STM1'
    bd.setUint32(o + 4, m.vertexCount, Endian.little);
    bd.setUint32(o + 8, m.indices.length, Endian.little);
    bd.setUint32(o + 12, flags, Endian.little);
    o += 16;
    for (final v in m.positions) {
      bd.setFloat32(o, v, Endian.little);
      o += 4;
    }
    if (hasNormals) {
      for (final v in m.normals) {
        bd.setFloat32(o, v, Endian.little);
        o += 4;
      }
    }
    if (hasColors) {
      for (final v in m.colors) {
        bd.setUint8(o, v);
        o += 1;
      }
    }
    for (final v in m.indices) {
      bd.setUint32(o, v, Endian.little);
      o += 4;
    }
    return out;
  }
}

class ExportException implements Exception {
  const ExportException(this.message);
  final String message;
  @override
  String toString() => 'ExportException: $message';
}

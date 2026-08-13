import 'dart:convert';
import 'dart:typed_data';

import '../model/scan.dart';

/// The formats Structura can write. USDZ is produced natively (Apple's tooling)
/// and lives in the platform plugin; the rest are pure-Dart encoders here so both
/// platforms export identically.
enum ExportFormat { obj, gltf, glb, ply, stl, usdz }

extension ExportFormatMeta on ExportFormat {
  String get ext => switch (this) {
        ExportFormat.obj => 'obj',
        ExportFormat.gltf => 'gltf',
        ExportFormat.glb => 'glb',
        ExportFormat.ply => 'ply',
        ExportFormat.stl => 'stl',
        ExportFormat.usdz => 'usdz',
      };

  String get label => switch (this) {
        ExportFormat.obj => 'OBJ (Blender / CAD)',
        ExportFormat.gltf => 'glTF (web / three.js)',
        ExportFormat.glb => 'GLB (web, single file)',
        ExportFormat.ply => 'PLY (point cloud / MeshLab)',
        ExportFormat.stl => 'STL (3D printing)',
        ExportFormat.usdz => 'USDZ (Apple / AR)',
      };

  /// Whether this exporter runs in Dart (vs. requiring the native plugin, USDZ).
  bool get isDart => this != ExportFormat.usdz;
}

/// Pure-Dart mesh/cloud encoders. Each returns bytes ready to write to a file.
class MeshExporters {
  /// Wavefront OBJ (+ optional MTL). Widely read by Blender, CAD, MeshLab.
  /// Colors aren't standard in OBJ; we emit vertex colors as the common
  /// "v x y z r g b" extension that Blender/MeshLab both accept.
  static String encodeObj(MeshData m, {String name = 'structura'}) {
    final b = StringBuffer();
    b.writeln('# Structura export — $name');
    b.writeln('# ${m.vertexCount} verts, ${m.triangleCount} tris');
    final hasColors = m.hasColors;
    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.positions[v * 3];
      final y = m.positions[v * 3 + 1];
      final z = m.positions[v * 3 + 2];
      if (hasColors) {
        final r = m.colors[v * 4] / 255;
        final g = m.colors[v * 4 + 1] / 255;
        final bl = m.colors[v * 4 + 2] / 255;
        b.writeln('v ${_f(x)} ${_f(y)} ${_f(z)} ${_f(r)} ${_f(g)} ${_f(bl)}');
      } else {
        b.writeln('v ${_f(x)} ${_f(y)} ${_f(z)}');
      }
    }
    if (m.hasNormals) {
      for (var v = 0; v < m.vertexCount; v++) {
        b.writeln('vn ${_f(m.normals[v * 3])} ${_f(m.normals[v * 3 + 1])} ${_f(m.normals[v * 3 + 2])}');
      }
    }
    // OBJ is 1-indexed
    for (var t = 0; t < m.indices.length; t += 3) {
      final a = m.indices[t] + 1;
      final c = m.indices[t + 1] + 1;
      final d = m.indices[t + 2] + 1;
      if (m.hasNormals) {
        b.writeln('f $a//$a $c//$c $d//$d');
      } else {
        b.writeln('f $a $c $d');
      }
    }
    return b.toString();
  }

  /// Binary STL — the 3D-printing lingua franca. No color, no normals reused
  /// (STL stores a face normal per triangle, which we compute).
  static Uint8List encodeStl(MeshData m, {String header = 'Structura'}) {
    final triCount = m.triangleCount;
    // 80-byte header + u32 count + 50 bytes/triangle
    final bytes = Uint8List(84 + triCount * 50);
    final bd = ByteData.sublistView(bytes);
    final head = ascii.encode(header.padRight(80).substring(0, 80));
    bytes.setRange(0, 80, head);
    bd.setUint32(80, triCount, Endian.little);
    var o = 84;
    for (var t = 0; t < m.indices.length; t += 3) {
      final ia = m.indices[t], ib = m.indices[t + 1], ic = m.indices[t + 2];
      final ax = m.positions[ia * 3], ay = m.positions[ia * 3 + 1], az = m.positions[ia * 3 + 2];
      final bx = m.positions[ib * 3], by = m.positions[ib * 3 + 1], bz = m.positions[ib * 3 + 2];
      final cx = m.positions[ic * 3], cy = m.positions[ic * 3 + 1], cz = m.positions[ic * 3 + 2];
      // face normal = (b-a) × (c-a), normalized
      final ux = bx - ax, uy = by - ay, uz = bz - az;
      final vx = cx - ax, vy = cy - ay, vz = cz - az;
      var nx = uy * vz - uz * vy;
      var ny = uz * vx - ux * vz;
      var nz = ux * vy - uy * vx;
      final len = (nx * nx + ny * ny + nz * nz);
      if (len > 1e-20) {
        final l = 1.0 / _sqrt(len);
        nx *= l;
        ny *= l;
        nz *= l;
      }
      bd.setFloat32(o, nx, Endian.little);
      bd.setFloat32(o + 4, ny, Endian.little);
      bd.setFloat32(o + 8, nz, Endian.little);
      o += 12;
      for (final (px, py, pz) in [(ax, ay, az), (bx, by, bz), (cx, cy, cz)]) {
        bd.setFloat32(o, px, Endian.little);
        bd.setFloat32(o + 4, py, Endian.little);
        bd.setFloat32(o + 8, pz, Endian.little);
        o += 12;
      }
      bd.setUint16(o, 0, Endian.little); // attribute byte count
      o += 2;
    }
    return bytes;
  }

  /// Binary PLY — the point-cloud/mesh format MeshLab & CloudCompare love. When
  /// [asPointCloud] uses the scan's cloud; otherwise writes the mesh with faces.
  static Uint8List encodePlyMesh(MeshData m) {
    final hasColors = m.hasColors;
    final header = StringBuffer()
      ..writeln('ply')
      ..writeln('format binary_little_endian 1.0')
      ..writeln('comment Structura export')
      ..writeln('element vertex ${m.vertexCount}')
      ..writeln('property float x')
      ..writeln('property float y')
      ..writeln('property float z');
    if (hasColors) {
      header
        ..writeln('property uchar red')
        ..writeln('property uchar green')
        ..writeln('property uchar blue');
    }
    header
      ..writeln('element face ${m.triangleCount}')
      ..writeln('property list uchar uint vertex_indices')
      ..writeln('end_header');
    final headBytes = ascii.encode(header.toString());

    final vStride = hasColors ? 15 : 12; // 3 f32 (+3 u8)
    final fStride = 1 + 12; // count byte + 3 u32
    final body = Uint8List(m.vertexCount * vStride + m.triangleCount * fStride);
    final bd = ByteData.sublistView(body);
    var o = 0;
    for (var v = 0; v < m.vertexCount; v++) {
      bd.setFloat32(o, m.positions[v * 3], Endian.little);
      bd.setFloat32(o + 4, m.positions[v * 3 + 1], Endian.little);
      bd.setFloat32(o + 8, m.positions[v * 3 + 2], Endian.little);
      o += 12;
      if (hasColors) {
        bd.setUint8(o, m.colors[v * 4]);
        bd.setUint8(o + 1, m.colors[v * 4 + 1]);
        bd.setUint8(o + 2, m.colors[v * 4 + 2]);
        o += 3;
      }
    }
    for (var t = 0; t < m.indices.length; t += 3) {
      bd.setUint8(o, 3);
      bd.setUint32(o + 1, m.indices[t], Endian.little);
      bd.setUint32(o + 5, m.indices[t + 1], Endian.little);
      bd.setUint32(o + 9, m.indices[t + 2], Endian.little);
      o += 13;
    }
    return Uint8List.fromList([...headBytes, ...body]);
  }

  /// Binary PLY of a point cloud (positions + optional color).
  static Uint8List encodePlyCloud(PointCloud c) {
    final hasColors = c.colors.isNotEmpty;
    final header = StringBuffer()
      ..writeln('ply')
      ..writeln('format binary_little_endian 1.0')
      ..writeln('comment Structura point cloud')
      ..writeln('element vertex ${c.count}')
      ..writeln('property float x')
      ..writeln('property float y')
      ..writeln('property float z');
    if (hasColors) {
      header
        ..writeln('property uchar red')
        ..writeln('property uchar green')
        ..writeln('property uchar blue');
    }
    header.writeln('end_header');
    final headBytes = ascii.encode(header.toString());
    final stride = hasColors ? 15 : 12;
    final body = Uint8List(c.count * stride);
    final bd = ByteData.sublistView(body);
    var o = 0;
    for (var i = 0; i < c.count; i++) {
      bd.setFloat32(o, c.positions[i * 3], Endian.little);
      bd.setFloat32(o + 4, c.positions[i * 3 + 1], Endian.little);
      bd.setFloat32(o + 8, c.positions[i * 3 + 2], Endian.little);
      o += 12;
      if (hasColors) {
        bd.setUint8(o, c.colors[i * 4]);
        bd.setUint8(o + 1, c.colors[i * 4 + 1]);
        bd.setUint8(o + 2, c.colors[i * 4 + 2]);
        o += 3;
      }
    }
    return Uint8List.fromList([...headBytes, ...body]);
  }

  static double _sqrt(double x) => x <= 0 ? 0 : _newtonSqrt(x);
  static double _newtonSqrt(double x) {
    var g = x;
    for (var i = 0; i < 20; i++) {
      g = 0.5 * (g + x / g);
    }
    return g;
  }

  static String _f(num v) => v.toStringAsFixed(6);
}

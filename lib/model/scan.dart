import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// The capture quality Structura actually achieved for a scan. We label this
/// honestly and never present a depth-from-motion scan as LiDAR-clean.
enum CaptureQuality {
  /// Dedicated LiDAR / ToF sensor (iPhone Pro, iPad Pro, some Android ToF).
  lidar,

  /// ARCore Depth from a phone WITHOUT a ToF sensor (depth-from-motion). Noisier.
  depthFromMotion,

  /// Unknown / not reported by the platform.
  unknown,
}

extension CaptureQualityLabel on CaptureQuality {
  String get label => switch (this) {
        CaptureQuality.lidar => 'LiDAR',
        CaptureQuality.depthFromMotion => 'Depth (motion)',
        CaptureQuality.unknown => 'Unknown',
      };
}

/// A triangle mesh in Structura's canonical form. Right-handed, Y-up, metres.
///
/// Buffers are flat and typed so they cross the platform channel and feed the GL
/// viewer + exporters without per-vertex object churn:
///   - [positions]  3 floats / vertex  (x, y, z) in metres
///   - [normals]    3 floats / vertex  (unit)          — may be empty (derived)
///   - [colors]     4 bytes  / vertex  (r, g, b, a)    — may be empty (untextured)
///   - [indices]    3 uints  / triangle
class MeshData {
  MeshData({
    required this.positions,
    required this.indices,
    Float32List? normals,
    Uint8List? colors,
  })  : normals = normals ?? Float32List(0),
        colors = colors ?? Uint8List(0);

  final Float32List positions;
  final Uint32List indices;
  Float32List normals;
  Uint8List colors;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;
  bool get hasNormals => normals.isNotEmpty;
  bool get hasColors => colors.isNotEmpty;
  bool get isEmpty => positions.isEmpty || indices.isEmpty;

  /// Axis-aligned bounds in metres. Returns (min, max); zero-vectors when empty.
  (Vector3, Vector3) bounds() {
    if (isEmpty) return (Vector3.zero(), Vector3.zero());
    final min = Vector3.all(double.infinity);
    final max = Vector3.all(double.negativeInfinity);
    for (var i = 0; i < positions.length; i += 3) {
      final x = positions[i], y = positions[i + 1], z = positions[i + 2];
      if (x < min.x) min.x = x;
      if (y < min.y) min.y = y;
      if (z < min.z) min.z = z;
      if (x > max.x) max.x = x;
      if (y > max.y) max.y = y;
      if (z > max.z) max.z = z;
    }
    return (min, max);
  }

  /// Bounding-box dimensions (metres): width (x), height (y), depth (z).
  Vector3 dimensions() {
    final (min, max) = bounds();
    return max - min;
  }

  /// Rough on-disk cost estimate for the UI budget meter (uncompressed, bytes).
  int get approxBytes =>
      positions.lengthInBytes +
      normals.lengthInBytes +
      colors.lengthInBytes +
      indices.lengthInBytes;
}

/// A colored point cloud — the raw fusion product before/besides meshing.
class PointCloud {
  PointCloud({required this.positions, Uint8List? colors, Float32List? confidence})
      : colors = colors ?? Uint8List(0),
        confidence = confidence ?? Float32List(0);

  /// 3 floats / point (x, y, z) metres.
  final Float32List positions;

  /// 4 bytes / point (r, g, b, a) — may be empty.
  final Uint8List colors;

  /// 1 float / point in [0, 1] — sensor confidence; may be empty.
  final Float32List confidence;

  int get count => positions.length ~/ 3;
  bool get isEmpty => positions.isEmpty;
}

/// A completed capture: the mesh (primary), the point cloud, quality, and meta.
class Scan {
  Scan({
    required this.id,
    required this.createdAt,
    required this.quality,
    required this.mesh,
    this.pointCloud,
    this.name = 'Scan',
    this.gravityAligned = false,
  });

  final String id;
  final DateTime createdAt;
  final CaptureQuality quality;

  /// The reconstructed mesh — the primary artifact.
  MeshData mesh;

  /// The colored point cloud, kept for point-cloud export + heatmap view.
  PointCloud? pointCloud;

  String name;

  /// Whether the scan's Y axis has been aligned to gravity (from the sensor).
  bool gravityAligned;
}

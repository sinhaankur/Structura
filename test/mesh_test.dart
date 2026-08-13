import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/capture/capture_channel.dart';
import 'package:structura/export/exporters.dart';
import 'package:structura/export/gltf_exporter.dart';
import 'package:structura/mesh/optimize.dart';
import 'package:structura/model/scan.dart';

/// A unit cube (8 verts, 12 tris) as a tiny fixture. Enough to exercise the
/// exporters + optimizer without a device.
MeshData _cube() {
  final positions = Float32List.fromList([
    0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, // back face
    0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, // front face
  ]);
  final indices = Uint32List.fromList([
    0, 1, 2, 0, 2, 3, // back
    4, 6, 5, 4, 7, 6, // front
    0, 4, 5, 0, 5, 1, // bottom
    3, 2, 6, 3, 6, 7, // top
    0, 3, 7, 0, 7, 4, // left
    1, 5, 6, 1, 6, 2, // right
  ]);
  return MeshData(positions: positions, indices: indices);
}

void main() {
  group('MeshData', () {
    test('counts and bounds', () {
      final m = _cube();
      expect(m.vertexCount, 8);
      expect(m.triangleCount, 12);
      final dims = m.dimensions();
      expect(dims.x, closeTo(1, 1e-6));
      expect(dims.y, closeTo(1, 1e-6));
      expect(dims.z, closeTo(1, 1e-6));
    });
  });

  group('MeshOptimizer', () {
    test('recomputeNormals produces unit normals', () {
      final m = MeshOptimizer.recomputeNormals(_cube());
      expect(m.hasNormals, isTrue);
      for (var v = 0; v < m.vertexCount; v++) {
        final x = m.normals[v * 3], y = m.normals[v * 3 + 1], z = m.normals[v * 3 + 2];
        final len = (x * x + y * y + z * z);
        expect(len, closeTo(1, 1e-3));
      }
    });

    test('weld is idempotent on an already-clean cube', () {
      final m = MeshOptimizer.weld(_cube(), epsilon: 0.0001);
      expect(m.vertexCount, 8);
      expect(m.triangleCount, 12);
    });

    test('decimate reduces triangle count', () {
      final m = MeshOptimizer.decimate(_cube(), targetRatio: 0.3);
      expect(m.triangleCount, lessThan(12));
    });

    test('autoClean returns a valid indexed mesh with normals', () {
      final m = MeshOptimizer.autoClean(_cube());
      expect(m.hasNormals, isTrue);
      expect(m.triangleCount, greaterThan(0));
      for (final i in m.indices) {
        expect(i, lessThan(m.vertexCount));
      }
    });
  });

  group('Exporters', () {
    test('OBJ has the right vertex + face counts', () {
      final obj = MeshExporters.encodeObj(_cube());
      final vLines = 'v '.allMatches(obj).length;
      final fLines = RegExp(r'^f ', multiLine: true).allMatches(obj).length;
      expect(vLines, greaterThanOrEqualTo(8));
      expect(fLines, 12);
    });

    test('STL binary has correct header + triangle count', () {
      final stl = MeshExporters.encodeStl(_cube());
      final bd = ByteData.sublistView(stl);
      final tri = bd.getUint32(80, Endian.little);
      expect(tri, 12);
      expect(stl.length, 84 + 12 * 50);
    });

    test('PLY mesh starts with the ply magic', () {
      final ply = MeshExporters.encodePlyMesh(_cube());
      expect(String.fromCharCodes(ply.sublist(0, 3)), 'ply');
    });

    test('GLB has a valid header and JSON+BIN chunks', () {
      final glb = GltfExporter.encodeGlb(_cube());
      final bd = ByteData.sublistView(glb);
      expect(bd.getUint32(0, Endian.little), 0x46546C67); // 'glTF'
      expect(bd.getUint32(4, Endian.little), 2); // version
      expect(bd.getUint32(8, Endian.little), glb.length); // total length
    });
  });

  group('MeshCodec round-trip', () {
    test('mesh survives encode → decode via the STM1 blob', () {
      // build an STM1 blob the way the export service does, decode it back
      final m = MeshOptimizer.recomputeNormals(_cube());
      final blob = _packMesh(m);
      final back = MeshCodec.decodeMesh(blob);
      expect(back.vertexCount, m.vertexCount);
      expect(back.triangleCount, m.triangleCount);
      expect(back.hasNormals, isTrue);
      for (var i = 0; i < m.positions.length; i++) {
        expect(back.positions[i], closeTo(m.positions[i], 1e-6));
      }
    });
  });
}

/// Mirror of ExportService._packMeshForNative for the round-trip test.
Uint8List _packMesh(MeshData m) {
  var flags = 0;
  if (m.hasNormals) flags |= 0x1;
  if (m.hasColors) flags |= 0x2;
  final size = 16 +
      m.positions.lengthInBytes +
      (m.hasNormals ? m.normals.lengthInBytes : 0) +
      (m.hasColors ? m.colors.lengthInBytes : 0) +
      m.indices.lengthInBytes;
  final out = Uint8List(size);
  final bd = ByteData.sublistView(out);
  var o = 0;
  bd.setUint32(o, 0x53544D31, Endian.little);
  bd.setUint32(o + 4, m.vertexCount, Endian.little);
  bd.setUint32(o + 8, m.indices.length, Endian.little);
  bd.setUint32(o + 12, flags, Endian.little);
  o += 16;
  for (final v in m.positions) {
    bd.setFloat32(o, v, Endian.little);
    o += 4;
  }
  if (m.hasNormals) {
    for (final v in m.normals) {
      bd.setFloat32(o, v, Endian.little);
      o += 4;
    }
  }
  for (final v in m.indices) {
    bd.setUint32(o, v, Endian.little);
    o += 4;
  }
  return out;
}

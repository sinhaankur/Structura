import 'package:flutter_test/flutter_test.dart';
import 'package:structura/capture/synthetic_scan.dart';
import 'package:structura/mesh/scan_processor.dart';
import 'package:structura/model/scan.dart';
import 'package:structura/export/exporters.dart';
import 'package:structura/export/gltf_exporter.dart';

/// End-to-end: a device-free synthetic RAW scan → the real ScanProcessor →
/// exporters. Proves the whole capture→process→export pipeline runs and produces
/// clean, valid output without a LiDAR device (the "make sure things work" test).
void main() {
  group('Full pipeline (synthetic scan)', () {
    test('raw synthetic room is dense, noisy, and un-normalled', () {
      final raw = SyntheticScan.room(seed: 1);
      expect(raw.mesh.triangleCount, greaterThan(1000));
      expect(raw.mesh.hasNormals, isFalse); // raw arrives without normals
      // Real metric bounds (~4×2.6×3.2 m room).
      final dims = raw.mesh.dimensions();
      expect(dims.x, closeTo(4.0, 0.2));
      expect(dims.y, closeTo(2.6, 0.2));
      expect(dims.z, closeTo(3.2, 0.2));
    });

    test('processing cleans the raw scan: welded, de-speckled, normalled', () async {
      final raw = SyntheticScan.room(seed: 2);
      final rawTris = raw.mesh.triangleCount;

      final out = await ScanProcessor.process(raw);

      // Welding merges the duplicated seam verts → far fewer vertices than the
      // raw (which had 4 unique verts per cell, none shared).
      expect(out.mesh.vertexCount, lessThan(raw.mesh.vertexCount));
      // Normals were rebuilt.
      expect(out.mesh.hasNormals, isTrue);
      // Still a real, non-empty surface.
      expect(out.mesh.triangleCount, greaterThan(0));
      expect(out.mesh.triangleCount, lessThanOrEqualTo(rawTris));
      // Every index is in range (no corruption from remap/decimate).
      for (final i in out.mesh.indices) {
        expect(i, lessThan(out.mesh.vertexCount));
      }
      // The room's overall size is preserved through cleanup.
      final dims = out.mesh.dimensions();
      expect(dims.x, closeTo(4.0, 0.3));
      expect(dims.y, closeTo(2.6, 0.3));
      expect(dims.z, closeTo(3.2, 0.3));
    });

    test('cleaned scan exports to every format without error', () async {
      final out = await ScanProcessor.process(SyntheticScan.room(seed: 3));
      final m = out.mesh;

      final obj = MeshExporters.encodeObj(m);
      expect(obj, contains('v '));
      expect(obj, contains('f '));

      final stl = MeshExporters.encodeStl(m);
      expect(stl.length, greaterThan(84)); // header + at least one triangle

      final ply = MeshExporters.encodePlyMesh(m);
      expect(String.fromCharCodes(ply.sublist(0, 3)), 'ply');

      final glb = GltfExporter.encodeGlb(m);
      expect(glb.length, greaterThan(20));
    });

    test('metadata flows through: simulated scan is labelled + gravity-aligned', () async {
      final out = await ScanProcessor.process(SyntheticScan.room());
      expect(out.quality, CaptureQuality.lidar);
      expect(out.gravityAligned, isTrue);
      expect(out.name, 'Simulated room');
    });
  });
}

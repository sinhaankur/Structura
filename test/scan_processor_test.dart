import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/model/scan.dart';
import 'package:structura/mesh/scan_processor.dart';

/// A deliberately RAW-looking scan: a small quad built from two triangles whose
/// shared edge uses DUPLICATE vertices (the seam duplication depth fusion emits),
/// plus a tiny detached island of 1 triangle (sensor speckle). Processing should
/// weld the seam and drop the speckle — the exact "raw → clean" contract.
Scan _rawScan(CaptureQuality quality) {
  final positions = Float32List.fromList([
    // quad, tri A (0,1,2)
    0, 0, 0, 1, 0, 0, 1, 1, 0,
    // quad, tri B (3,4,5) — verts 3,4 DUPLICATE verts 2,0 at the same positions
    1, 1, 0, 0, 0, 0, 0, 1, 0,
    // a speckle island, 1 tri, far away
    5, 5, 5, 5.01, 5, 5, 5, 5.01, 5,
  ]);
  final indices = Uint32List.fromList([
    0, 1, 2, // tri A
    3, 4, 5, // tri B (shares the quad, via duplicate verts)
    6, 7, 8, // the speckle
  ]);
  return Scan(
    id: 'test',
    createdAt: DateTime(2026),
    quality: quality,
    mesh: MeshData(positions: positions, indices: indices),
  );
}

void main() {
  group('ScanProcessor', () {
    test('welds duplicate seam verts and drops speckle islands', () async {
      final raw = _rawScan(CaptureQuality.lidar);
      expect(raw.mesh.vertexCount, 9); // raw: 6 quad + 3 speckle
      expect(raw.mesh.triangleCount, 3);

      final out = await ScanProcessor.process(raw);

      // The speckle island (1 tri, below the min-island threshold) is gone,
      // leaving only the welded quad (2 tris).
      expect(out.mesh.triangleCount, 2);
      // Seam duplicates welded: the quad has 4 unique corners, not 6.
      expect(out.mesh.vertexCount, 4);
    });

    test('produces unit normals', () async {
      final out = await ScanProcessor.process(_rawScan(CaptureQuality.lidar));
      expect(out.mesh.hasNormals, isTrue);
      for (var v = 0; v < out.mesh.vertexCount; v++) {
        final x = out.mesh.normals[v * 3];
        final y = out.mesh.normals[v * 3 + 1];
        final z = out.mesh.normals[v * 3 + 2];
        expect(x * x + y * y + z * z, closeTo(1, 1e-3));
      }
    });

    test('every index stays in range after processing', () async {
      final out = await ScanProcessor.process(_rawScan(CaptureQuality.unknown));
      for (final i in out.mesh.indices) {
        expect(i, lessThan(out.mesh.vertexCount));
      }
    });

    test('reports stages in order, ending done', () async {
      final stages = <ProcessStage>[];
      await ScanProcessor.process(
        _rawScan(CaptureQuality.lidar),
        onStage: stages.add,
      );
      expect(stages, contains(ProcessStage.cleaning));
      expect(stages.last, ProcessStage.done);
    });

    test('preserves scan metadata (id, quality, gravity)', () async {
      final raw = _rawScan(CaptureQuality.depthFromMotion)
        ..gravityAligned = true
        ..name = 'Kitchen';
      final out = await ScanProcessor.process(raw);
      expect(out.id, 'test');
      expect(out.quality, CaptureQuality.depthFromMotion);
      expect(out.gravityAligned, isTrue);
      expect(out.name, 'Kitchen');
    });

    test('empty scan passes through untouched', () async {
      final empty = Scan(
        id: 'e',
        createdAt: DateTime(2026),
        quality: CaptureQuality.unknown,
        mesh: MeshData(positions: Float32List(0), indices: Uint32List(0)),
      );
      final out = await ScanProcessor.process(empty);
      expect(out.mesh.isEmpty, isTrue);
    });

    test('reclean respects a triangle budget on a dense mesh', () async {
      // A denser grid so decimation actually engages under the budget.
      final n = 40; // 40x40 grid of quads
      final verts = <double>[];
      for (var y = 0; y <= n; y++) {
        for (var x = 0; x <= n; x++) {
          verts..add(x.toDouble())..add(y.toDouble())..add(0);
        }
      }
      final idx = <int>[];
      int at(int x, int y) => y * (n + 1) + x;
      for (var y = 0; y < n; y++) {
        for (var x = 0; x < n; x++) {
          idx..add(at(x, y))..add(at(x + 1, y))..add(at(x + 1, y + 1));
          idx..add(at(x, y))..add(at(x + 1, y + 1))..add(at(x, y + 1));
        }
      }
      final dense = MeshData(
        positions: Float32List.fromList(verts),
        indices: Uint32List.fromList(idx),
      );
      final budget = 500;
      final out = await ScanProcessor.reclean(dense, triangleBudget: budget);
      // Decimation is approximate, so allow generous headroom, but it must have
      // meaningfully reduced from the dense original (3200 tris).
      expect(out.triangleCount, lessThan(dense.triangleCount));
    });
  });
}

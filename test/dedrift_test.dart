import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/mesh/dedrift.dart';
import 'package:structura/model/scan.dart';

/// Guards the de-drift fix (the "two toilets" problem). A clean single shell reads
/// ~1× overlap; a doubled shell reads high and merges back down.
void main() {
  // build a grid of vertices on a plane, optionally DUPLICATED at a small offset
  // (simulating tracking drift laying a second copy).
  MeshData plane({bool doubled = false, double offset = 0.02}) {
    final pos = <double>[];
    final idx = <int>[];
    void addGrid(double dx, double dy, double dz) {
      final base = pos.length ~/ 3;
      for (var i = 0; i < 10; i++) {
        for (var j = 0; j < 10; j++) {
          pos..add(i * 0.1 + dx)..add(dy)..add(j * 0.1 + dz);
        }
      }
      for (var i = 0; i < 9; i++) {
        for (var j = 0; j < 9; j++) {
          final a = base + i * 10 + j, b = a + 1, c = a + 10, d = c + 1;
          idx..add(a)..add(b)..add(c)..add(b)..add(d)..add(c);
        }
      }
    }
    addGrid(0, 0, 0);
    if (doubled) addGrid(offset, offset, offset); // a second, drifted copy
    return MeshData(
      positions: Float32List.fromList(pos),
      indices: Uint32List.fromList(idx),
    );
  }

  test('overlapRatio is ~1 for a clean single shell', () {
    final r = DeDrift.overlapRatio(plane());
    expect(r, lessThan(1.4));
    expect(DeDrift.looksDoubled(plane()), false);
  });

  test('overlapRatio flags a drift-doubled shell', () {
    final doubled = plane(doubled: true);
    final r = DeDrift.overlapRatio(doubled);
    expect(r, greaterThanOrEqualTo(1.4)); // two copies in ~the same voxels
    expect(DeDrift.looksDoubled(doubled), true);
  });

  test('merge fuses the doubled copies back to one surface', () {
    final doubled = plane(doubled: true);
    final before = doubled.vertexCount; // 200 (two 100-vert grids)
    final merged = DeDrift.merge(doubled, cell: 0.05);
    expect(merged.vertexCount, lessThan(before)); // copies collapsed
    // and the result is no longer flagged as doubled
    expect(DeDrift.looksDoubled(merged), false);
  });

  test('merge preserves colour by averaging cells', () {
    final pos = Float32List.fromList([0, 0, 0, 0.01, 0, 0, 0, 0, 0.01]);
    final m = MeshData(
      positions: pos,
      indices: Uint32List.fromList([0, 1, 2]),
      colors: Uint8List.fromList([200, 0, 0, 255, 0, 200, 0, 255, 0, 0, 200, 255]),
    );
    final merged = DeDrift.merge(m, cell: 0.1); // all three land in one cell
    expect(merged.hasColors, true);
    // averaged colour of the three verts (~66,66,66)
    expect(merged.colors[0], closeTo(66, 5));
  });

  test('analyze() gives an honest human summary', () {
    final rep = DeDrift.analyze(plane(doubled: true));
    expect(rep.doubled, true);
    expect(rep.summary.toLowerCase().contains('drift'), true);
    final clean = DeDrift.analyze(plane());
    expect(clean.doubled, false);
  });
}

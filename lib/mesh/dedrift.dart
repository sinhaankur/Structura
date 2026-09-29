import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../model/scan.dart';

/// dedrift — detect and fix the "two toilets" problem.
///
/// Handheld LiDAR loses tracking on shiny / feature-poor surfaces (mirrors, glossy
/// tile, blank walls — bathrooms are the worst) and lays a SECOND copy of the same
/// surface slightly offset. The result is duplicated fixtures, doubled tables,
/// merged bunk beds. On a real condo scan we measured ~3× more geometry than the
/// space can hold — the tell-tale of drift-doubling.
///
/// Two tools:
///   • [overlapRatio] — a metric: vertices ÷ occupied voxels. ~1.0 for a clean
///     single shell; >~1.4 means overlapping/doubled geometry.
///   • [merge] — collapse near-duplicate geometry: bin verts into a drift-scale
///     grid and average each cell to ONE vertex (colours averaged too), fusing the
///     offset copies into a single surface. Honest: this removes duplication, it
///     does not invent detail; small real features within a cell are merged, so the
///     cell size is a deliberate trade (default 4 cm ≈ the drift offset we saw).
///
/// Pure Dart, isolate-friendly, no platform. Complements MeshOptimizer.weld (which
/// only merges COINCIDENT verts); de-drift merges verts that are NEAR but offset
/// across separate shells — a different failure weld can't touch.
class DeDrift {
  /// vertices ÷ occupied voxels at [voxel] size. A cheap duplication signal.
  static double overlapRatio(MeshData m, {double voxel = 0.05}) {
    if (m.isEmpty) return 0;
    final occupied = <int>{};
    final (min, _) = m.bounds();
    final inv = 1.0 / voxel;
    for (var v = 0; v < m.vertexCount; v++) {
      final ix = ((m.positions[v * 3] - min.x) * inv).floor();
      final iy = ((m.positions[v * 3 + 1] - min.y) * inv).floor();
      final iz = ((m.positions[v * 3 + 2] - min.z) * inv).floor();
      occupied.add((ix & 0x1FFFFF) | ((iy & 0x1FFFFF) << 21) | ((iz & 0x1FFFFF) << 42));
    }
    return m.vertexCount / math.max(1, occupied.length);
  }

  /// True when the mesh looks drift-doubled (worth offering the user a fix).
  static bool looksDoubled(MeshData m, {double threshold = 1.4}) =>
      overlapRatio(m) >= threshold;

  /// Collapse near-duplicate geometry into one surface. [cell] is the merge scale
  /// (metres) — bigger merges more aggressively (removes more doubling but more
  /// detail). Returns a new mesh; colours are cell-averaged so texture survives.
  static MeshData merge(MeshData m, {double cell = 0.04}) {
    if (m.isEmpty) return m;
    final (min, max) = m.bounds();
    final size = max - min;
    final maxDim = math.max(size.x, math.max(size.y, size.z));
    if (maxDim <= 0 || cell <= 0) return m;
    final inv = 1.0 / cell;

    int key(double x, double y, double z) {
      final ix = ((x - min.x) * inv).floor();
      final iy = ((y - min.y) * inv).floor();
      final iz = ((z - min.z) * inv).floor();
      return (ix & 0x1FFFFF) | ((iy & 0x1FFFFF) << 21) | ((iz & 0x1FFFFF) << 42);
    }

    // accumulate a single averaged vertex per cell (position + colour)
    final acc = <int, _Acc>{};
    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.positions[v * 3], y = m.positions[v * 3 + 1], z = m.positions[v * 3 + 2];
      final a = acc.putIfAbsent(key(x, y, z), () => _Acc());
      a.n++; a.x += x; a.y += y; a.z += z;
      if (m.hasColors) {
        a.r += m.colors[v * 4]; a.g += m.colors[v * 4 + 1]; a.b += m.colors[v * 4 + 2];
      }
    }

    // assign new indices + build reduced buffers
    final cellIndex = <int, int>{};
    final newPos = <double>[];
    final newCol = <int>[];
    var ni = 0;
    for (final e in acc.entries) {
      cellIndex[e.key] = ni++;
      final a = e.value;
      newPos..add(a.x / a.n)..add(a.y / a.n)..add(a.z / a.n);
      if (m.hasColors) {
        newCol..add((a.r / a.n).round())..add((a.g / a.n).round())..add((a.b / a.n).round())..add(255);
      }
    }

    // remap triangles, dropping any that collapse within a cell
    final newIdx = <int>[];
    for (var t = 0; t < m.indices.length; t += 3) {
      final ia = cellIndex[key(m.positions[m.indices[t] * 3], m.positions[m.indices[t] * 3 + 1], m.positions[m.indices[t] * 3 + 2])]!;
      final ib = cellIndex[key(m.positions[m.indices[t + 1] * 3], m.positions[m.indices[t + 1] * 3 + 1], m.positions[m.indices[t + 1] * 3 + 2])]!;
      final ic = cellIndex[key(m.positions[m.indices[t + 2] * 3], m.positions[m.indices[t + 2] * 3 + 1], m.positions[m.indices[t + 2] * 3 + 2])]!;
      if (ia != ib && ib != ic && ia != ic) newIdx..add(ia)..add(ib)..add(ic);
    }

    return MeshData(
      positions: Float32List.fromList(newPos),
      indices: Uint32List.fromList(newIdx),
      colors: m.hasColors ? Uint8List.fromList(newCol) : null,
    );
  }

  /// The honest report the UI shows: how doubled, and what a merge would do.
  static DriftReport analyze(MeshData m) {
    final ratio = overlapRatio(m);
    return DriftReport(
      overlapRatio: ratio,
      doubled: ratio >= 1.4,
      vertexCount: m.vertexCount,
    );
  }
}

class DriftReport {
  DriftReport({required this.overlapRatio, required this.doubled, required this.vertexCount});
  final double overlapRatio;
  final bool doubled;
  final int vertexCount;

  String get summary => doubled
      ? 'This scan looks drift-doubled (${overlapRatio.toStringAsFixed(1)}× overlap) — '
          'likely duplicate copies from tracking loss on shiny/blank surfaces. '
          'Merging will fuse them into one surface.'
      : 'No significant duplication (${overlapRatio.toStringAsFixed(1)}× overlap).';
}

class _Acc {
  int n = 0;
  double x = 0, y = 0, z = 0;
  int r = 0, g = 0, b = 0;
}

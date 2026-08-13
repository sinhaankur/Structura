import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../model/scan.dart';

/// On-device mesh cleanup + reduction. The "optimized data" half of Structura:
/// raw depth fusion is dense and noisy; these make it small, watertight-ish, and
/// pleasant to hand to another tool.
///
/// All ops are pure (return a new [MeshData]); nothing here touches the platform.
class MeshOptimizer {
  /// Weld vertices that share a position within [epsilon] metres, rewriting the
  /// index buffer. Depth fusion emits many near-duplicate verts along chunk
  /// seams; welding them is the cheapest big win and a prerequisite for good
  /// decimation. Default 1mm.
  static MeshData weld(MeshData m, {double epsilon = 0.001}) {
    if (m.isEmpty) return m;
    final inv = 1.0 / epsilon;
    final map = <int, int>{}; // spatial-hash key → new vertex index
    final remap = Int32List(m.vertexCount); // old index → new index
    final newPos = <double>[];
    final newCol = <int>[];
    final hasColors = m.hasColors;

    int hash(double x, double y, double z) {
      final ix = (x * inv).round();
      final iy = (y * inv).round();
      final iz = (z * inv).round();
      // 3D → 1D hash (large primes; collisions only cost a bucket compare below)
      return (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791);
    }

    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.positions[v * 3];
      final y = m.positions[v * 3 + 1];
      final z = m.positions[v * 3 + 2];
      final key = hash(x, y, z);
      final existing = map[key];
      if (existing == null) {
        final ni = newPos.length ~/ 3;
        map[key] = ni;
        remap[v] = ni;
        newPos..add(x)..add(y)..add(z);
        if (hasColors) {
          newCol
            ..add(m.colors[v * 4])
            ..add(m.colors[v * 4 + 1])
            ..add(m.colors[v * 4 + 2])
            ..add(m.colors[v * 4 + 3]);
        }
      } else {
        remap[v] = existing;
      }
    }

    // rewrite indices, dropping degenerate triangles the weld collapsed
    final newIdx = <int>[];
    for (var t = 0; t < m.indices.length; t += 3) {
      final a = remap[m.indices[t]];
      final b = remap[m.indices[t + 1]];
      final c = remap[m.indices[t + 2]];
      if (a != b && b != c && a != c) newIdx..add(a)..add(b)..add(c);
    }

    return MeshData(
      positions: Float32List.fromList(newPos),
      indices: Uint32List.fromList(newIdx),
      colors: hasColors ? Uint8List.fromList(newCol) : null,
    );
  }

  /// Remove floating islands smaller than [minTriangles] triangles — the specks
  /// of noise depth sensors throw off. Uses union-find over shared vertices.
  static MeshData removeSmallIslands(MeshData m, {int minTriangles = 40}) {
    if (m.isEmpty) return m;
    final parent = Int32List(m.vertexCount);
    for (var i = 0; i < parent.length; i++) {
      parent[i] = i;
    }
    int find(int x) {
      while (parent[x] != x) {
        parent[x] = parent[parent[x]];
        x = parent[x];
      }
      return x;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra != rb) parent[ra] = rb;
    }

    for (var t = 0; t < m.indices.length; t += 3) {
      union(m.indices[t], m.indices[t + 1]);
      union(m.indices[t + 1], m.indices[t + 2]);
    }
    // count triangles per component
    final triPerComp = <int, int>{};
    for (var t = 0; t < m.indices.length; t += 3) {
      final root = find(m.indices[t]);
      triPerComp[root] = (triPerComp[root] ?? 0) + 1;
    }
    // keep triangles whose component is big enough
    final keep = <int>[];
    for (var t = 0; t < m.indices.length; t += 3) {
      final root = find(m.indices[t]);
      if ((triPerComp[root] ?? 0) >= minTriangles) {
        keep..add(m.indices[t])..add(m.indices[t + 1])..add(m.indices[t + 2]);
      }
    }
    return _compact(m, Uint32List.fromList(keep));
  }

  /// Recompute smooth per-vertex normals (area-weighted face normals accumulated
  /// onto vertices). Depth meshes often ship without normals; the viewer + most
  /// exporters want them.
  static MeshData recomputeNormals(MeshData m) {
    if (m.isEmpty) return m;
    final n = Float32List(m.vertexCount * 3);
    for (var t = 0; t < m.indices.length; t += 3) {
      final ia = m.indices[t], ib = m.indices[t + 1], ic = m.indices[t + 2];
      final a = _vec(m.positions, ia);
      final b = _vec(m.positions, ib);
      final c = _vec(m.positions, ic);
      final fn = (b - a).cross(c - a); // magnitude = 2*area → area-weighting
      for (final i in [ia, ib, ic]) {
        n[i * 3] += fn.x;
        n[i * 3 + 1] += fn.y;
        n[i * 3 + 2] += fn.z;
      }
    }
    for (var v = 0; v < m.vertexCount; v++) {
      final x = n[v * 3], y = n[v * 3 + 1], z = n[v * 3 + 2];
      final len = math.sqrt(x * x + y * y + z * z);
      if (len > 1e-9) {
        n[v * 3] = x / len;
        n[v * 3 + 1] = y / len;
        n[v * 3 + 2] = z / len;
      }
    }
    return MeshData(
      positions: m.positions,
      indices: m.indices,
      normals: n,
      colors: m.hasColors ? m.colors : null,
    );
  }

  /// Vertex-clustering decimation toward a [targetRatio] of the current triangle
  /// count (0..1). Fast + robust for scan data: snap vertices to a grid sized to
  /// hit the target, average each cell, rebuild triangles, drop degenerates.
  ///
  /// This is not quadric-error-metric (QEM) — it trades a little shape accuracy
  /// for speed and never fails on non-manifold scan meshes. A QEM pass can be
  /// layered on later for hero exports; see docs/ARCHITECTURE.md.
  static MeshData decimate(MeshData m, {required double targetRatio}) {
    if (m.isEmpty || targetRatio >= 1.0) return m;
    final (min, max) = m.bounds();
    final size = max - min;
    final maxDim = math.max(size.x, math.max(size.y, size.z));
    if (maxDim <= 0) return m;

    // Choose a grid resolution so the reduced vertex count ~ target * current.
    // Heuristic: cells ≈ target * vertexCount, so cellsPerAxis ≈ cbrt(that).
    final targetVerts = math.max(8, (m.vertexCount * targetRatio).round());
    final cellsPerAxis = math.max(2, _cbrt(targetVerts.toDouble()).ceil());
    final cell = maxDim / cellsPerAxis;
    final inv = 1.0 / cell;

    final accum = <int, _Cell>{};
    final remap = Int32List(m.vertexCount);

    int key(double x, double y, double z) {
      final ix = ((x - min.x) * inv).floor();
      final iy = ((y - min.y) * inv).floor();
      final iz = ((z - min.z) * inv).floor();
      return (ix & 0x3FF) | ((iy & 0x3FF) << 10) | ((iz & 0x3FF) << 20);
    }

    // first pass: accumulate cell centroids
    for (var v = 0; v < m.vertexCount; v++) {
      final x = m.positions[v * 3];
      final y = m.positions[v * 3 + 1];
      final z = m.positions[v * 3 + 2];
      final k = key(x, y, z);
      final c = accum.putIfAbsent(k, () => _Cell());
      c.add(x, y, z,
          m.hasColors ? m.colors[v * 4] : 0,
          m.hasColors ? m.colors[v * 4 + 1] : 0,
          m.hasColors ? m.colors[v * 4 + 2] : 0);
    }
    // assign each cell a new index + build the reduced vertex buffers
    final cellIndex = <int, int>{};
    final newPos = <double>[];
    final newCol = <int>[];
    var ni = 0;
    for (final entry in accum.entries) {
      cellIndex[entry.key] = ni++;
      final c = entry.value;
      newPos..add(c.x / c.n)..add(c.y / c.n)..add(c.z / c.n);
      if (m.hasColors) {
        newCol
          ..add((c.r / c.n).round())
          ..add((c.g / c.n).round())
          ..add((c.b / c.n).round())
          ..add(255);
      }
    }
    for (var v = 0; v < m.vertexCount; v++) {
      remap[v] = cellIndex[key(
        m.positions[v * 3],
        m.positions[v * 3 + 1],
        m.positions[v * 3 + 2],
      )]!;
    }
    // rebuild triangles, dropping any that collapsed within a cell
    final newIdx = <int>[];
    for (var t = 0; t < m.indices.length; t += 3) {
      final a = remap[m.indices[t]];
      final b = remap[m.indices[t + 1]];
      final c = remap[m.indices[t + 2]];
      if (a != b && b != c && a != c) newIdx..add(a)..add(b)..add(c);
    }
    return MeshData(
      positions: Float32List.fromList(newPos),
      indices: Uint32List.fromList(newIdx),
      colors: m.hasColors ? Uint8List.fromList(newCol) : null,
    );
  }

  /// A one-call "clean up for export" pipeline with a triangle budget.
  static MeshData autoClean(MeshData m, {int triangleBudget = 150000}) {
    var out = weld(m, epsilon: 0.002);
    out = removeSmallIslands(out, minTriangles: 40);
    if (out.triangleCount > triangleBudget) {
      out = decimate(out, targetRatio: triangleBudget / out.triangleCount);
    }
    out = recomputeNormals(out);
    return out;
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static MeshData _compact(MeshData m, Uint32List keptIndices) {
    // remove now-unused vertices and reindex
    final used = <int, int>{};
    final newPos = <double>[];
    final newCol = <int>[];
    final newNorm = <double>[];
    final out = Uint32List(keptIndices.length);
    for (var i = 0; i < keptIndices.length; i++) {
      final old = keptIndices[i];
      var ni = used[old];
      if (ni == null) {
        ni = newPos.length ~/ 3;
        used[old] = ni;
        newPos..add(m.positions[old * 3])..add(m.positions[old * 3 + 1])..add(m.positions[old * 3 + 2]);
        if (m.hasColors) {
          newCol..add(m.colors[old * 4])..add(m.colors[old * 4 + 1])..add(m.colors[old * 4 + 2])..add(m.colors[old * 4 + 3]);
        }
        if (m.hasNormals) {
          newNorm..add(m.normals[old * 3])..add(m.normals[old * 3 + 1])..add(m.normals[old * 3 + 2]);
        }
      }
      out[i] = ni;
    }
    return MeshData(
      positions: Float32List.fromList(newPos),
      indices: out,
      colors: m.hasColors ? Uint8List.fromList(newCol) : null,
      normals: m.hasNormals ? Float32List.fromList(newNorm) : null,
    );
  }

  static Vector3 _vec(Float32List p, int i) =>
      Vector3(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]);

  static double _cbrt(double x) => math.pow(x, 1 / 3).toDouble();
}

class _Cell {
  double x = 0, y = 0, z = 0;
  int r = 0, g = 0, b = 0, n = 0;
  void add(double px, double py, double pz, int cr, int cg, int cb) {
    x += px;
    y += py;
    z += pz;
    r += cr;
    g += cg;
    b += cb;
    n++;
  }
}

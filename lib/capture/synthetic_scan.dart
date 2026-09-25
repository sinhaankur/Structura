import 'dart:math' as math;
import 'dart:typed_data';

import '../model/scan.dart';

/// SyntheticScan — a device-free capture source for testing the whole pipeline.
///
/// Real capture needs a LiDAR iPhone / ARCore-Depth Android. To develop and TEST
/// everything AFTER capture (process → view → measure → export) on a simulator,
/// a plain machine, or in `flutter test`, this builds a *realistic raw scan*: a
/// room-like box (walls + floor + ceiling) at real metric scale, deliberately
/// dirtied the way a depth sensor dirties data —
///   • per-vertex position NOISE (sensor jitter),
///   • duplicated seam vertices (what chunked fusion emits),
///   • a few tiny floating ISLANDS (speckle),
///   • no normals, no colors (as the raw ARKit mesh arrives).
///
/// Feeding this through the *real* `ScanProcessor` proves the clean-up actually
/// works: the output should be welded, de-speckled, decimated, and normal'd. It's
/// the honest stand-in — the same code path a real scan takes, minus the sensor.
class SyntheticScan {
  /// Build a raw, noisy [Scan] of a room [w]×[h]×[d] metres. [seed] makes the
  /// noise reproducible for tests.
  static Scan room({
    double w = 4.0,
    double h = 2.6,
    double d = 3.2,
    int subdivisions = 24,
    double noiseMeters = 0.01,
    int seed = 1,
  }) {
    final rng = math.Random(seed);
    final positions = <double>[];
    final indices = <int>[];

    // Emit one subdivided quad (a wall) into the buffers, with duplicated edge
    // vertices per cell (no shared indices) — this is the seam duplication real
    // fusion produces, and what weld() must collapse.
    void quad(
      _V origin, _V uAxis, _V vAxis, {
      int nu = subdivisions,
      int nv = subdivisions,
    }) {
      for (var i = 0; i < nu; i++) {
        for (var j = 0; j < nv; j++) {
          final u0 = i / nu, u1 = (i + 1) / nu;
          final v0 = j / nv, v1 = (j + 1) / nv;
          final corners = [
            origin + uAxis * u0 + vAxis * v0,
            origin + uAxis * u1 + vAxis * v0,
            origin + uAxis * u1 + vAxis * v1,
            origin + uAxis * u0 + vAxis * v1,
          ];
          final base = positions.length ~/ 3;
          for (final c in corners) {
            // sensor jitter
            positions.add(c.x + (rng.nextDouble() * 2 - 1) * noiseMeters);
            positions.add(c.y + (rng.nextDouble() * 2 - 1) * noiseMeters);
            positions.add(c.z + (rng.nextDouble() * 2 - 1) * noiseMeters);
          }
          indices.addAll([base, base + 1, base + 2, base, base + 2, base + 3]);
        }
      }
    }

    // Floor, ceiling, and four walls of the box (origin at a corner).
    final o = _V(0, 0, 0);
    final x = _V(w, 0, 0), y = _V(0, h, 0), z = _V(0, 0, d);
    quad(o, x, z); // floor  (y=0)
    quad(o + y, x, z); // ceiling (y=h)
    quad(o, x, y); // wall  z=0
    quad(o + z, x, y); // wall  z=d
    quad(o, z, y); // wall  x=0
    quad(o + x, z, y); // wall  x=w

    // A few floating speckle islands (sensor noise) the processor should drop.
    for (var s = 0; s < 5; s++) {
      final cx = rng.nextDouble() * w;
      final cy = rng.nextDouble() * h;
      final cz = rng.nextDouble() * d;
      final base = positions.length ~/ 3;
      positions.addAll([cx, cy, cz, cx + 0.02, cy, cz, cx, cy + 0.02, cz]);
      indices.addAll([base, base + 1, base + 2]);
    }

    return Scan(
      id: 'sim-${DateTime.now().microsecondsSinceEpoch}',
      createdAt: DateTime.now(),
      quality: CaptureQuality.lidar, // labelled honestly by the caller as simulated
      name: 'Simulated room',
      gravityAligned: true,
      mesh: MeshData(
        positions: Float32List.fromList(positions),
        indices: Uint32List.fromList(indices),
      ),
    );
  }
}

/// A tiny 3-vector for readable geometry construction (no dependency needed).
class _V {
  const _V(this.x, this.y, this.z);
  final double x, y, z;
  _V operator +(_V o) => _V(x + o.x, y + o.y, z + o.z);
  _V operator *(double k) => _V(x * k, y * k, z * k);
}

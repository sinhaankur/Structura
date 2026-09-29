import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// coverage — know what's been scanned, and guide the user to the gaps.
///
/// The #1 complaint about a phone scan is "a lot is missing": occluded areas,
/// ceilings, dark corners the beam never reached. The fix is not more cleanup —
/// it's telling the user WHILE they scan where the holes are, so they fill them.
///
/// This is the deterministic coverage model the capture UI drives:
///   • the growing mesh's vertices are dropped into a coarse voxel grid,
///   • each voxel remembers how many verts landed in it (a density = confidence),
///   • from that we derive: total coverage %, and the biggest UNSEEN direction /
///     region so the UI can say "scan the ceiling" or "cover the far-left corner".
///
/// Pure Dart, cheap (incremental voxel inserts), no platform. On-device.
class CoverageGrid {
  CoverageGrid({this.voxel = 0.25});

  /// Voxel edge in metres. 25 cm is a good room-scale coverage cell — fine enough
  /// to spot a missing wall section, coarse enough to stay cheap.
  final double voxel;

  final Map<int, int> _cells = {}; // packed voxel key → vert count (density)
  Vector3? _min, _max;

  int get filledCells => _cells.length;

  int _key(double x, double y, double z) {
    final ix = (x / voxel).floor();
    final iy = (y / voxel).floor();
    final iz = (z / voxel).floor();
    return (ix & 0x1FFFFF) | ((iy & 0x1FFFFF) << 21) | ((iz & 0x1FFFFF) << 42);
  }

  /// Insert a batch of world-space vertices (the growing mesh). Incremental.
  void addVertices(Float32List positions) {
    for (var i = 0; i + 2 < positions.length; i += 3) {
      final x = positions[i], y = positions[i + 1], z = positions[i + 2];
      _cells.update(_key(x, y, z), (c) => c + 1, ifAbsent: () => 1);
      _min ??= Vector3(x, y, z);
      _max ??= Vector3(x, y, z);
      _min!..x = math.min(_min!.x, x)..y = math.min(_min!.y, y)..z = math.min(_min!.z, z);
      _max!..x = math.max(_max!.x, x)..y = math.max(_max!.y, y)..z = math.max(_max!.z, z);
    }
  }

  /// Fraction of the scanned bounding volume's floor-plan cells that have data —
  /// a 0..1 "how complete does this look" estimate (honest: it can't know rooms
  /// you never entered, so it measures completeness of what you've touched).
  double coverage() {
    if (_min == null || _cells.isEmpty) return 0;
    final span = _max! - _min!;
    // expected cells across the scanned footprint (x–z plane), 1 layer deep:
    final nx = math.max(1, (span.x / voxel).ceil());
    final nz = math.max(1, (span.z / voxel).ceil());
    final expected = nx * nz;
    // distinct (ix,iz) columns we actually have data in
    final columns = <int>{};
    for (final k in _cells.keys) {
      final ix = (k & 0x1FFFFF);
      final iz = ((k >> 42) & 0x1FFFFF);
      columns.add((ix & 0x1FFFFF) | (iz << 21));
    }
    return math.min(1.0, columns.length / expected);
  }

  /// The most under-covered direction, as a hint the UI can turn into words.
  /// Returns null when coverage is even / not enough data yet.
  CoverageHint? biggestGap() {
    if (_min == null || _cells.length < 8) return null;
    final ctr = (_min! + _max!) * 0.5;

    // Bucket density into 6 directions from the centre; the emptiest = the gap.
    final dir = <String, int>{'left': 0, 'right': 0, 'up': 0, 'down': 0, 'front': 0, 'back': 0};
    for (final e in _cells.entries) {
      final ix = (e.key & 0x1FFFFF).toSigned(21);
      final iy = ((e.key >> 21) & 0x1FFFFF).toSigned(21);
      final iz = ((e.key >> 42) & 0x1FFFFF).toSigned(21);
      final wx = ix * voxel, wy = iy * voxel, wz = iz * voxel;
      if (wx < ctr.x) dir['left'] = dir['left']! + e.value; else dir['right'] = dir['right']! + e.value;
      if (wy < ctr.y) dir['down'] = dir['down']! + e.value; else dir['up'] = dir['up']! + e.value;
      if (wz < ctr.z) dir['back'] = dir['back']! + e.value; else dir['front'] = dir['front']! + e.value;
    }
    // find the emptiest axis end with a meaningful imbalance
    final entries = dir.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    final emptiest = entries.first;
    final fullest = entries.last;
    if (fullest.value == 0) return null;
    final ratio = emptiest.value / fullest.value;
    if (ratio > 0.5) return null; // coverage is fairly even — no strong hint
    return CoverageHint(direction: emptiest.key, ratio: ratio);
  }

  void clear() {
    _cells.clear();
    _min = _max = null;
  }
}

class CoverageHint {
  CoverageHint({required this.direction, required this.ratio});
  final String direction;
  final double ratio;

  /// A short, human instruction for the capture overlay.
  String get message => switch (direction) {
        'up' => 'Tilt up — the ceiling needs coverage',
        'down' => 'Aim down — scan the floor',
        'left' => 'Pan left — that side is thin',
        'right' => 'Pan right — that side is thin',
        'front' => 'Move forward — the far end is unscanned',
        'back' => 'Turn around — behind you is unscanned',
        _ => 'Keep moving to fill the gaps',
      };
}

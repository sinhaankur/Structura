import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../model/scan.dart';

/// scan_summary — describe a scan from its REAL measured data.
///
/// Ankur's doctrine, applied: the deterministic core does the work; an on-device
/// tiny LLM is optional and only *rephrases*. So everything here is computed from
/// the mesh + classification — dimensions, floor area, what surfaces are present —
/// and turned into an honest name + description with plain templates. If a tiny
/// LLM is available it can make the wording warmer (see LlmNamer, opt-in); with no
/// model, these strings are the product, fully functional.
///
/// Never invents: it only names surface classes ARKit actually reported, and
/// numbers actually measured. "A room" it can't classify stays "a scanned space".

/// ARKit ARMeshClassification values (kept as ints so this stays platform-free;
/// the native side maps `ARMeshClassification` → these). 0 = none/unknown.
enum SurfaceClass { none, wall, floor, ceiling, table, seat, window, door }

extension on SurfaceClass {
  String get noun => switch (this) {
        SurfaceClass.wall => 'wall',
        SurfaceClass.floor => 'floor',
        SurfaceClass.ceiling => 'ceiling',
        SurfaceClass.table => 'table',
        SurfaceClass.seat => 'seat',
        SurfaceClass.window => 'window',
        SurfaceClass.door => 'door',
        SurfaceClass.none => 'surface',
      };
}

SurfaceClass surfaceClassFromInt(int v) => switch (v) {
      1 => SurfaceClass.wall,
      2 => SurfaceClass.floor,
      3 => SurfaceClass.ceiling,
      4 => SurfaceClass.table,
      5 => SurfaceClass.seat,
      6 => SurfaceClass.window,
      7 => SurfaceClass.door,
      _ => SurfaceClass.none,
    };

/// The measured facts of a scan — all real, all from geometry/classification.
class ScanFacts {
  ScanFacts({
    required this.dimensions,
    required this.floorAreaM2,
    required this.triangleCount,
    required this.classCounts,
    required this.hasColor,
    required this.quality,
  });

  final Vector3 dimensions; // metres (w, h, d)
  final double floorAreaM2; // footprint estimate
  final int triangleCount;
  final Map<SurfaceClass, int> classCounts; // faces per class
  final bool hasColor;
  final CaptureQuality quality;

  bool get isRoomLike =>
      dimensions.x > 1.5 && dimensions.z > 1.5 && dimensions.y > 1.8;

  /// Classes present in a meaningful amount (drop trace noise).
  List<SurfaceClass> get salientClasses {
    final total = classCounts.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return const [];
    final out = <SurfaceClass>[];
    for (final e in classCounts.entries) {
      if (e.key == SurfaceClass.none) continue;
      if (e.value / total >= 0.02) out.add(e.key); // ≥2% of faces
    }
    out.sort((a, b) => classCounts[b]!.compareTo(classCounts[a]!));
    return out;
  }
}

class ScanSummary {
  /// Compute the real facts. [faceClasses] is one SurfaceClass-int per triangle
  /// (from ARKit classification); pass null/empty when unavailable.
  static ScanFacts facts(Scan scan, {List<int>? faceClasses}) {
    final mesh = scan.mesh;
    final dims = mesh.dimensions();

    // Footprint: project onto the ground (x–z), take the bounding rectangle. A
    // rough but honest floor-area estimate; we label it "footprint", not exact.
    final floorArea = dims.x * dims.z;

    final counts = <SurfaceClass, int>{};
    if (faceClasses != null && faceClasses.isNotEmpty) {
      for (final c in faceClasses) {
        final k = surfaceClassFromInt(c);
        counts[k] = (counts[k] ?? 0) + 1;
      }
    }

    return ScanFacts(
      dimensions: dims,
      floorAreaM2: floorArea,
      triangleCount: mesh.triangleCount,
      classCounts: counts,
      hasColor: mesh.hasColors,
      quality: scan.quality,
    );
  }

  /// A deterministic, honest NAME for the scan (no LLM). Uses what we actually
  /// know: room-like vs object, footprint size, dominant classes.
  static String suggestName(ScanFacts f) {
    final d = f.dimensions;
    if (f.isRoomLike) {
      final area = f.floorAreaM2;
      final size = area >= 30
          ? 'Large'
          : area >= 14
              ? 'Mid'
              : 'Small';
      // if we can see a window, say "sunlit"; a door, "with entry" — only if real
      final hasWindow = f.classCounts[SurfaceClass.window] != null;
      final tag = hasWindow ? 'sunlit ' : '';
      return '$size ${tag}room · ${d.x.toStringAsFixed(1)}×${d.z.toStringAsFixed(1)} m';
    }
    // object-scale
    final longest = math.max(d.x, math.max(d.y, d.z));
    final scale = longest < 0.3
        ? 'Small object'
        : longest < 1.0
            ? 'Object'
            : 'Large object';
    return '$scale · ${(longest * 100).round()} cm';
  }

  /// A deterministic, honest DESCRIPTION — plain sentences from measured facts.
  /// This is the fallback (and the ground truth) the LLM only rephrases.
  static String describe(ScanFacts f) {
    final d = f.dimensions;
    final parts = <String>[];
    if (f.isRoomLike) {
      parts.add(
          'A scanned space, ${d.x.toStringAsFixed(1)} × ${d.z.toStringAsFixed(1)} m '
          'with ${d.y.toStringAsFixed(1)} m ceilings (footprint ≈ ${f.floorAreaM2.round()} m²).');
    } else {
      final longest = math.max(d.x, math.max(d.y, d.z));
      parts.add('A scanned object, about ${(longest * 100).round()} cm across.');
    }
    final classes = f.salientClasses;
    if (classes.isNotEmpty) {
      final nouns = classes.map((c) => _plural(c.noun)).toList();
      parts.add('Structura recognised ${_list(nouns)}.');
    }
    parts.add(f.hasColor
        ? 'Captured with colour (${f.quality.label}).'
        : 'Geometry only, no colour in this capture (${f.quality.label}).');
    parts.add('${(f.triangleCount / 1000).toStringAsFixed(1)}k triangles.');
    return parts.join(' ');
  }

  static String _plural(String n) => switch (n) {
        'floor' => 'floor',
        'ceiling' => 'ceiling',
        _ => '${n}s',
      };

  static String _list(List<String> items) {
    if (items.isEmpty) return '';
    if (items.length == 1) return items.first;
    if (items.length == 2) return '${items[0]} and ${items[1]}';
    return '${items.sublist(0, items.length - 1).join(', ')}, and ${items.last}';
  }
}

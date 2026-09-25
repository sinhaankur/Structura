import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../model/scan.dart';
import 'optimize.dart';

/// ScanProcessor — the stage that turns a RAW capture into a usable scan.
///
/// This is the piece that was missing: capture produced a dense, noisy,
/// seam-duplicated ARKit/ARCore mesh and handed it straight to the viewer, so the
/// app "took something but didn't know what to process." ScanProcessor owns the
/// "raw → clean" transform — it decides the parameters from the capture quality,
/// runs the [MeshOptimizer] pipeline **on a background isolate** (so a
/// half-million-triangle scan never janks the UI), and reports staged progress.
///
/// One place owns raw→clean. Both the post-capture auto-pass and the viewer's
/// manual "Optimize" button call [process] / [reclean] here, never MeshOptimizer
/// directly — so the behaviour can't drift between the two entry points.
class ScanProcessor {
  ScanProcessor._();

  /// Process a freshly-finished [scan] in place-returning a new cleaned [Scan].
  ///
  /// Runs off the UI thread. [onStage] reports human-readable progress for the
  /// capture screen's spinner. Safe on an empty scan (returns it untouched).
  static Future<Scan> process(
    Scan scan, {
    void Function(ProcessStage stage)? onStage,
  }) async {
    if (scan.mesh.isEmpty) {
      onStage?.call(ProcessStage.done);
      return scan;
    }

    // Parameters scale with how trustworthy the sensor was. LiDAR is clean, so we
    // weld tight and keep small features; depth-from-motion is noisy, so we weld
    // looser and cull more aggressively. This is the "knows what to process" part
    // — the decision the raw hand-off never made.
    final params = _ProcessParams.forQuality(scan.quality);

    onStage?.call(ProcessStage.preparing);
    final request = _ProcessRequest(
      positions: scan.mesh.positions,
      indices: scan.mesh.indices,
      normals: scan.mesh.normals,
      colors: scan.mesh.colors,
      params: params,
    );

    onStage?.call(ProcessStage.cleaning);
    // compute() hops to an isolate; the heavy weld/island/decimate/normals run
    // there. The top-level entry point [_runProcess] must be a free function.
    final result = await compute(_runProcess, request);

    onStage?.call(ProcessStage.done);
    return Scan(
      id: scan.id,
      createdAt: scan.createdAt,
      quality: scan.quality,
      name: scan.name,
      gravityAligned: scan.gravityAligned,
      pointCloud: scan.pointCloud,
      mesh: MeshData(
        positions: result.positions,
        indices: result.indices,
        normals: result.normals,
        colors: result.colors.isEmpty ? null : result.colors,
      ),
    );
  }

  /// Re-run cleanup on an already-loaded mesh (the viewer's manual button), at a
  /// caller-chosen triangle budget. Same isolate path as [process].
  static Future<MeshData> reclean(
    MeshData mesh, {
    int triangleBudget = 150000,
  }) async {
    if (mesh.isEmpty) return mesh;
    final request = _ProcessRequest(
      positions: mesh.positions,
      indices: mesh.indices,
      normals: mesh.normals,
      colors: mesh.colors,
      params: _ProcessParams(
        weldEpsilon: 0.002,
        minIslandTriangles: 40,
        triangleBudget: triangleBudget,
      ),
    );
    final r = await compute(_runProcess, request);
    return MeshData(
      positions: r.positions,
      indices: r.indices,
      normals: r.normals,
      colors: r.colors.isEmpty ? null : r.colors,
    );
  }
}

/// Coarse stages surfaced to the capture UI while processing runs.
enum ProcessStage { preparing, cleaning, done }

extension ProcessStageLabel on ProcessStage {
  String get label => switch (this) {
        ProcessStage.preparing => 'Preparing scan…',
        ProcessStage.cleaning => 'Cleaning & optimizing…',
        ProcessStage.done => 'Done',
      };
}

/// Cleanup parameters chosen from the capture quality.
class _ProcessParams {
  const _ProcessParams({
    required this.weldEpsilon,
    required this.minIslandTriangles,
    required this.triangleBudget,
  });

  /// Metres — verts within this distance are merged. Looser for noisy sensors.
  final double weldEpsilon;

  /// Components smaller than this are treated as sensor speckle and dropped.
  final int minIslandTriangles;

  /// Decimate down to (at most) this many triangles for a phone-friendly result.
  final int triangleBudget;

  factory _ProcessParams.forQuality(CaptureQuality q) => switch (q) {
        // LiDAR: trustworthy geometry — weld tight, keep detail, cull light.
        CaptureQuality.lidar => const _ProcessParams(
            weldEpsilon: 0.0015,
            minIslandTriangles: 30,
            triangleBudget: 200000,
          ),
        // Depth-from-motion: noisy — weld looser, cull harder, smaller budget.
        CaptureQuality.depthFromMotion => const _ProcessParams(
            weldEpsilon: 0.004,
            minIslandTriangles: 80,
            triangleBudget: 120000,
          ),
        CaptureQuality.unknown => const _ProcessParams(
            weldEpsilon: 0.003,
            minIslandTriangles: 60,
            triangleBudget: 150000,
          ),
      };
}

/// Isolate request payload. Only transferable typed data + plain fields cross the
/// isolate boundary; [MeshData]'s methods stay on the main side.
class _ProcessRequest {
  _ProcessRequest({
    required this.positions,
    required this.indices,
    required this.normals,
    required this.colors,
    required this.params,
  });
  final Float32List positions;
  final Uint32List indices;
  final Float32List normals;
  final Uint8List colors;
  final _ProcessParams params;
}

class _ProcessResult {
  _ProcessResult({
    required this.positions,
    required this.indices,
    required this.normals,
    required this.colors,
  });
  final Float32List positions;
  final Uint32List indices;
  final Float32List normals;
  final Uint8List colors;
}

/// Top-level isolate entry — runs the full clean pipeline. Must be a free
/// function (compute() can't take a closure or a static method with captured
/// state). Mirrors [MeshOptimizer.autoClean] but with quality-tuned parameters.
_ProcessResult _runProcess(_ProcessRequest req) {
  final p = req.params;
  var m = MeshData(
    positions: req.positions,
    indices: req.indices,
    normals: req.normals.isEmpty ? null : req.normals,
    colors: req.colors.isEmpty ? null : req.colors,
  );

  m = MeshOptimizer.weld(m, epsilon: p.weldEpsilon);
  m = MeshOptimizer.removeSmallIslands(m, minTriangles: p.minIslandTriangles);
  if (m.triangleCount > p.triangleBudget) {
    m = MeshOptimizer.decimate(m, targetRatio: p.triangleBudget / m.triangleCount);
  }
  m = MeshOptimizer.recomputeNormals(m);

  return _ProcessResult(
    positions: m.positions,
    indices: m.indices,
    normals: m.normals,
    colors: m.colors,
  );
}

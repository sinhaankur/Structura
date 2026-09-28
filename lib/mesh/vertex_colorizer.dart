import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../model/scan.dart';

/// vertex_colorizer — put real colour on a scan.
///
/// The single biggest let-down of a raw depth scan is that it comes out grey:
/// accurate geometry, no colour. (We saw this first-hand — a LiDAR export of a
/// whole condo, correct to the centimetre, but a white shell.) Structura's answer
/// is to sample the camera frames the sensor already saw and project their colour
/// onto the mesh vertices (glTF `COLOR_0`), so every export is coloured by default.
///
/// This is the on-device, dependency-free projective texturing step. Native
/// capture (ARKit/ARCore) may fill colours directly; when it doesn't — or for a
/// mesh imported without colour — this fills them from a set of posed camera
/// frames. Pure Dart, isolate-friendly (flat typed buffers), honest: a vertex no
/// camera actually saw is left at a neutral fallback, never invented.
///
/// The maths is the standard pinhole projection:
///   p_cam   = worldToCam * p_world              (camera-space vertex)
///   u = fx * x/z + cx ,  v = fy * y/z + cy       (pixel)
/// A vertex is coloured by the frame that saw it best — facing the camera, in
/// front of it, inside the image, nearest — a simple, robust "best view" score.

/// One posed camera frame: the RGB image + where the camera was + its intrinsics.
class CameraFrame {
  CameraFrame({
    required this.width,
    required this.height,
    required this.rgba, // width*height*4, row-major, top-left origin
    required this.worldToCamera, // 4x4: world → camera space
    required this.cameraPositionWorld, // camera origin in world space
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });

  final int width;
  final int height;
  final Uint8List rgba;
  final Matrix4 worldToCamera;

  /// The camera's position in world space — used for the facing test without any
  /// matrix inversion (native reports this directly from the AR pose).
  final Vector3 cameraPositionWorld;
  final double fx, fy, cx, cy;

  /// Sample colour at pixel (u,v). Returns null if outside the image.
  int? sampleRGBA(double u, double v) {
    final xi = u.round(), yi = v.round();
    if (xi < 0 || yi < 0 || xi >= width || yi >= height) return null;
    return (yi * width + xi) * 4;
  }
}

class ColorizeResult {
  ColorizeResult(this.colors, this.covered, this.vertexCount);

  /// vCount*4 RGBA, ready for MeshData.colors / glTF COLOR_0.
  final Uint8List colors;

  /// How many vertices were coloured by a real camera view (rest = fallback).
  final int covered;
  final int vertexCount;

  double get coverage => vertexCount == 0 ? 0 : covered / vertexCount;
}

class VertexColorizer {
  /// Neutral fallback for vertices no frame saw (a soft warm grey, not pure white
  /// — reads as "uncoloured" honestly rather than pretending to be a surface).
  static const List<int> _fallback = [180, 176, 170, 255];

  /// Project [frames] onto [mesh] vertices and return per-vertex RGBA.
  ///
  /// [needsNormals] the mesh should have normals for the facing test; if it has
  /// none we skip that term (still correct, just less selective).
  static ColorizeResult colorize(
    MeshData mesh,
    List<CameraFrame> frames, {
    double maxDepth = 6.0,
  }) {
    final vCount = mesh.vertexCount;
    final out = Uint8List(vCount * 4);
    final pos = mesh.positions;
    final nrm = mesh.normals;
    final hasN = mesh.hasNormals;

    var covered = 0;
    final pw = Vector3.zero();
    final pc = Vector3.zero();

    for (var vi = 0; vi < vCount; vi++) {
      final i3 = vi * 3, i4 = vi * 4;
      pw.setValues(pos[i3], pos[i3 + 1], pos[i3 + 2]);

      var bestScore = -1.0;
      int bestR = 0, bestG = 0, bestB = 0;

      for (final f in frames) {
        // world → camera. transform3 applies the full 4x4 (rotation+translation)
        // to a point, writing the result back into the passed vector.
        pc.setValues(pw.x, pw.y, pw.z);
        f.worldToCamera.transform3(pc);
        final z = pc.z;
        if (z <= 0.02 || z > maxDepth) continue; // behind camera or too far

        final u = f.fx * (pc.x / z) + f.cx;
        final v = f.fy * (pc.y / z) + f.cy;
        final at = f.sampleRGBA(u, v);
        if (at == null) continue; // outside the frame

        // "best view" score: closer is better; facing the camera is better.
        var score = 1.0 / z;
        if (hasN) {
          // facing test in WORLD space (no matrix inversion needed): the view
          // direction is simply (cameraPos - vertexPos); if the vertex normal
          // points back toward the camera, the camera sees its front.
          final nx = nrm[i3], ny = nrm[i3 + 1], nz = nrm[i3 + 2];
          var vx = f.cameraPositionWorld.x - pw.x;
          var vy = f.cameraPositionWorld.y - pw.y;
          var vz = f.cameraPositionWorld.z - pw.z;
          final vlen = math.sqrt(vx * vx + vy * vy + vz * vz);
          if (vlen > 1e-6) {
            vx /= vlen; vy /= vlen; vz /= vlen;
          }
          final facing = nx * vx + ny * vy + nz * vz;
          if (facing <= 0.05) continue; // camera sees the back of this vertex
          score *= facing;
        }

        if (score > bestScore) {
          bestScore = score;
          bestR = f.rgba[at];
          bestG = f.rgba[at + 1];
          bestB = f.rgba[at + 2];
        }
      }

      if (bestScore > 0) {
        out[i4] = bestR;
        out[i4 + 1] = bestG;
        out[i4 + 2] = bestB;
        out[i4 + 3] = 255;
        covered++;
      } else {
        out[i4] = _fallback[0];
        out[i4 + 1] = _fallback[1];
        out[i4 + 2] = _fallback[2];
        out[i4 + 3] = _fallback[3];
      }
    }

    return ColorizeResult(out, covered, vCount);
  }

  /// Convenience: return a new MeshData that carries the projected colours.
  static MeshData applied(MeshData mesh, List<CameraFrame> frames,
      {double maxDepth = 6.0}) {
    final r = colorize(mesh, frames, maxDepth: maxDepth);
    return MeshData(
      positions: mesh.positions,
      indices: mesh.indices,
      normals: mesh.hasNormals ? mesh.normals : null,
      colors: r.colors,
    );
  }
}

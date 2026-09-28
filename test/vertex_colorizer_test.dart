import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/mesh/vertex_colorizer.dart';
import 'package:structura/model/scan.dart';
import 'package:vector_math/vector_math_64.dart';

/// Guards the projective texturing step — the fix for "accurate geometry, no
/// colour". A vertex a camera actually saw must get that camera's pixel colour;
/// a vertex no camera saw must fall back honestly (never invented as a real hue).
void main() {
  // A tiny 2x2 solid-red image (RGBA), used by the frame that faces the vertex.
  Uint8List solid(int r, int g, int b, [int w = 4, int h = 4]) {
    final px = Uint8List(w * h * 4);
    for (var i = 0; i < w * h; i++) {
      px[i * 4] = r; px[i * 4 + 1] = g; px[i * 4 + 2] = b; px[i * 4 + 3] = 255;
    }
    return px;
  }

  // A camera at +Z looking toward the origin (world → camera is a translation of
  // -camPos plus a flip so the vertex lands in front at +z in camera space).
  CameraFrame frameLookingDownZ({
    required Uint8List rgba,
    int w = 4,
    int h = 4,
    double camZ = 2.0,
  }) {
    // Camera at (0,0,camZ). It looks toward -Z (world). In our simple convention
    // camera-space z is POSITIVE in front, so worldToCamera maps a world point
    // p to (p.x, p.y, camZ - p.z): a vertex at the origin → (0,0,camZ), z>0. ✓
    final wtc = Matrix4.identity()
      ..setEntry(2, 2, -1.0) // negate z
      ..setEntry(2, 3, camZ); // + camZ
    return CameraFrame(
      width: w,
      height: h,
      rgba: rgba,
      worldToCamera: wtc,
      cameraPositionWorld: Vector3(0, 0, camZ),
      fx: 1.0, fy: 1.0,
      cx: w / 2, cy: h / 2, // origin projects to image centre
    );
  }

  MeshData oneVertex({bool withNormalTowardCamera = true}) {
    // one triangle (degenerate is fine for colouring) at the origin
    final pos = Float32List.fromList([0, 0, 0, 0, 0, 0, 0, 0, 0]);
    final idx = Uint32List.fromList([0, 1, 2]);
    final nrm = withNormalTowardCamera
        ? Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]) // faces +Z (the camera)
        : Float32List.fromList([0, 0, -1, 0, 0, -1, 0, 0, -1]); // faces away
    return MeshData(positions: pos, indices: idx, normals: nrm);
  }

  test('a vertex the camera sees gets that camera colour', () {
    final mesh = oneVertex();
    final frame = frameLookingDownZ(rgba: solid(220, 30, 40)); // red
    final r = VertexColorizer.colorize(mesh, [frame]);

    expect(r.covered, 3); // all three (coincident) verts coloured
    expect(r.coverage, 1.0);
    expect(r.colors[0], 220);
    expect(r.colors[1], 30);
    expect(r.colors[2], 40);
    expect(r.colors[3], 255);
  });

  test('a vertex no camera saw falls back (not invented)', () {
    final mesh = oneVertex(withNormalTowardCamera: false); // faces away from cam
    final frame = frameLookingDownZ(rgba: solid(220, 30, 40));
    final r = VertexColorizer.colorize(mesh, [frame]);

    expect(r.covered, 0); // camera saw the back → no real colour
    // fallback is the neutral grey, never the red it couldn't legitimately sample
    expect(r.colors[0], isNot(220));
    expect(r.colors[3], 255);
  });

  test('a vertex behind the camera is skipped', () {
    // put the vertex behind the camera (z beyond camZ so camera-space z < 0)
    final pos = Float32List.fromList([0, 0, 5, 0, 0, 5, 0, 0, 5]);
    final mesh = MeshData(
      positions: pos,
      indices: Uint32List.fromList([0, 1, 2]),
      normals: Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
    );
    final frame = frameLookingDownZ(rgba: solid(10, 200, 10), camZ: 2.0);
    final r = VertexColorizer.colorize(mesh, [frame]);
    expect(r.covered, 0); // camera-space z = 2 - 5 = -3 < 0 → behind → skipped
  });

  test('applied() returns a mesh carrying the colours', () {
    final mesh = oneVertex();
    final frame = frameLookingDownZ(rgba: solid(15, 120, 240));
    final out = VertexColorizer.applied(mesh, [frame]);
    expect(out.hasColors, true);
    expect(out.colors.length, mesh.vertexCount * 4);
    expect(out.colors[2], 240); // blue channel of the sampled pixel
    // geometry is preserved
    expect(out.positions, mesh.positions);
    expect(out.indices, mesh.indices);
  });

  test('the winning frame is the closer / better-facing one', () {
    final mesh = oneVertex();
    final near = frameLookingDownZ(rgba: solid(255, 0, 0), camZ: 1.0); // red, close
    final far = frameLookingDownZ(rgba: solid(0, 0, 255), camZ: 5.0); // blue, far
    final r = VertexColorizer.colorize(mesh, [far, near]);
    expect(r.colors[0], 255); // the near (red) frame wins on score
    expect(r.colors[2], 0);
  });
}

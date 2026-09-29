import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../model/scan.dart';

/// splat — seed a 3D Gaussian Splatting radiance field from a captured cloud.
///
/// Gaussian Splatting is the current state of the art for "looks EXACTLY like the
/// room": the scene is thousands of tiny coloured, oriented gaussians rather than
/// a mesh. Full training (differentiable rendering + optimisation over posed
/// frames) is a heavy on-device research build — see docs/SPLATTING-SPEC.md for
/// the honest plan. But the FIRST step of every splat pipeline is an initial point
/// set, and Structura already captures exactly that: coloured points with
/// confidence. This writes that seed as a standard 3DGS `.ply` — loadable in any
/// splat viewer/trainer (Inria, gsplat, PlayCanvas, Nerfstudio).
///
/// Honest labelling: this is an INITIAL isotropic splat set (one gaussian per
/// captured point: colour → SH DC term, confidence → opacity, a small uniform
/// scale, identity rotation). It is not a trained radiance field — training refines
/// it. We never present the seed as a finished splat.
class SplatExporter {
  /// SH C0 term: converting an sRGB [0,1] colour to the degree-0 spherical-harmonic
  /// coefficient that 3DGS PLYs store in f_dc_*. (c = (rgb - 0.5) / C0.)
  static const double _shC0 = 0.28209479177387814;

  /// Encode the scan's point cloud as a 3D Gaussian Splatting seed PLY.
  /// [pointScale] is the initial gaussian radius in metres (isotropic).
  static Uint8List encodeSeedPly(Scan scan, {double pointScale = 0.02}) {
    final cloud = scan.pointCloud;
    if (cloud == null || cloud.isEmpty) {
      // fall back to mesh vertices if there's no cloud
      return _fromMeshVerts(scan.mesh, pointScale);
    }
    final n = cloud.count;
    final hasColor = cloud.colors.isNotEmpty;
    final hasConf = cloud.confidence.isNotEmpty;

    // 3DGS PLY property layout (the de-facto standard the viewers expect):
    //   x y z · f_dc_0 f_dc_1 f_dc_2 · opacity · scale_0..2 · rot_0..3   (all f32)
    final header = StringBuffer()
      ..writeln('ply')
      ..writeln('format binary_little_endian 1.0')
      ..writeln('comment Structura 3DGS seed (initial isotropic splats, untrained)')
      ..writeln('element vertex $n')
      ..writeln('property float x')
      ..writeln('property float y')
      ..writeln('property float z')
      ..writeln('property float f_dc_0')
      ..writeln('property float f_dc_1')
      ..writeln('property float f_dc_2')
      ..writeln('property float opacity')
      ..writeln('property float scale_0')
      ..writeln('property float scale_1')
      ..writeln('property float scale_2')
      ..writeln('property float rot_0')
      ..writeln('property float rot_1')
      ..writeln('property float rot_2')
      ..writeln('property float rot_3')
      ..writeln('end_header');
    final headBytes = ascii.encode(header.toString());

    const floatsPerPoint = 14;
    final body = Uint8List(n * floatsPerPoint * 4);
    final bd = ByteData.sublistView(body);
    final logScale = math.log(pointScale); // 3DGS stores scale in log space

    var o = 0;
    void putF(double v) { bd.setFloat32(o, v, Endian.little); o += 4; }

    for (var i = 0; i < n; i++) {
      putF(cloud.positions[i * 3]);
      putF(cloud.positions[i * 3 + 1]);
      putF(cloud.positions[i * 3 + 2]);

      // colour → SH degree-0 DC coefficients
      double r = 0.5, g = 0.5, b = 0.5;
      if (hasColor) {
        r = cloud.colors[i * 4] / 255.0;
        g = cloud.colors[i * 4 + 1] / 255.0;
        b = cloud.colors[i * 4 + 2] / 255.0;
      }
      putF((r - 0.5) / _shC0);
      putF((g - 0.5) / _shC0);
      putF((b - 0.5) / _shC0);

      // opacity from confidence (logit space, as 3DGS stores it). High conf →
      // more opaque; unknown → a moderate default.
      final conf = hasConf ? cloud.confidence[i].clamp(0.05, 0.99) : 0.6;
      putF(_logit(conf));

      // isotropic scale (log space) + identity rotation quaternion
      putF(logScale); putF(logScale); putF(logScale);
      putF(1.0); putF(0.0); putF(0.0); putF(0.0);
    }
    return Uint8List.fromList([...headBytes, ...body]);
  }

  static Uint8List _fromMeshVerts(MeshData m, double scale) {
    // reuse the same layout, one splat per mesh vertex
    final n = m.vertexCount;
    final hasColor = m.hasColors;
    final header = StringBuffer()
      ..writeln('ply')
      ..writeln('format binary_little_endian 1.0')
      ..writeln('comment Structura 3DGS seed from mesh verts (untrained)')
      ..writeln('element vertex $n')
      ..writeln('property float x')..writeln('property float y')..writeln('property float z')
      ..writeln('property float f_dc_0')..writeln('property float f_dc_1')..writeln('property float f_dc_2')
      ..writeln('property float opacity')
      ..writeln('property float scale_0')..writeln('property float scale_1')..writeln('property float scale_2')
      ..writeln('property float rot_0')..writeln('property float rot_1')..writeln('property float rot_2')..writeln('property float rot_3')
      ..writeln('end_header');
    final headBytes = ascii.encode(header.toString());
    final body = Uint8List(n * 14 * 4);
    final bd = ByteData.sublistView(body);
    final logScale = math.log(scale);
    var o = 0;
    void putF(double v) { bd.setFloat32(o, v, Endian.little); o += 4; }
    for (var v = 0; v < n; v++) {
      putF(m.positions[v * 3]); putF(m.positions[v * 3 + 1]); putF(m.positions[v * 3 + 2]);
      double r = 0.5, g = 0.5, b = 0.5;
      if (hasColor) { r = m.colors[v * 4] / 255.0; g = m.colors[v * 4 + 1] / 255.0; b = m.colors[v * 4 + 2] / 255.0; }
      putF((r - 0.5) / _shC0); putF((g - 0.5) / _shC0); putF((b - 0.5) / _shC0);
      putF(_logit(0.6));
      putF(logScale); putF(logScale); putF(logScale);
      putF(1.0); putF(0.0); putF(0.0); putF(0.0);
    }
    return Uint8List.fromList([...headBytes, ...body]);
  }

  static double _logit(double p) {
    final x = p.clamp(1e-4, 1 - 1e-4);
    return math.log(x / (1 - x));
  }
}

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import '../model/scan.dart';
import 'camera_math.dart';

/// How the mesh is drawn in [MeshView].
enum ShadeMode { solid, wireframe, points, heatmap }

extension ShadeModeLabel on ShadeMode {
  String get label => switch (this) {
        ShadeMode.solid => 'Solid',
        ShadeMode.wireframe => 'Wire',
        ShadeMode.points => 'Points',
        ShadeMode.heatmap => 'Confidence',
      };
  IconData get icon => switch (this) {
        ShadeMode.solid => Icons.view_in_ar,
        ShadeMode.wireframe => Icons.grid_3x3,
        ShadeMode.points => Icons.grain,
        ShadeMode.heatmap => Icons.thermostat,
      };
}

/// An interactive, dependency-light 3D view of a scan.
///
/// This is a **software renderer** (CustomPainter): it projects the mesh through
/// an orbit camera, depth-sorts the triangles (painter's algorithm), and shades
/// them with a simple headlight lambert. No GL plugin, no platform texture — so
/// it runs identically on iOS + Android + the simulator, and a
/// `RepaintBoundary → toImage` gives us the Photos render for free.
///
/// It's tuned for the scan sizes people actually export (after Optimize, tens of
/// thousands of triangles). Above [maxTrianglesForSolid] it auto-drops to points
/// so the UI stays responsive; the real export is unaffected.
class MeshView extends StatefulWidget {
  const MeshView({
    super.key,
    required this.scan,
    this.mode = ShadeMode.solid,
    this.background = const Color(0xFF0A0C10),
  });

  final Scan scan;
  final ShadeMode mode;
  final Color background;

  /// Above this, solid/wire fall back to point rendering for responsiveness.
  static const int maxTrianglesForSolid = 60000;

  @override
  State<MeshView> createState() => _MeshViewState();
}

class _MeshViewState extends State<MeshView> {
  // orbit camera state (held; no snap-back)
  double _yaw = 0.6;
  double _pitch = 0.5;
  // Zoom factor around a FOV-fit framing: 1.0 = the whole model just fits;
  // <1 zooms out, >1 zooms in. (Not a raw distance — the painter converts it to
  // a camera distance that always frames the bounding sphere.)
  double _distance = 1.0;
  vm.Vector2 _pan = vm.Vector2.zero();

  // gesture bookkeeping
  double _startYaw = 0, _startPitch = 0, _startDist = 0;
  vm.Vector2 _startPan = vm.Vector2.zero();
  Offset _lastFocal = Offset.zero;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (d) {
        _startYaw = _yaw;
        _startPitch = _pitch;
        _startDist = _distance;
        _startPan = _pan.clone();
        _lastFocal = d.localFocalPoint;
      },
      onScaleUpdate: (d) {
        setState(() {
          if (d.pointerCount >= 2) {
            // pinch → zoom (factor around the fit framing); two-finger drag → pan
            _distance = (_startDist * d.scale).clamp(0.3, 6.0);
            final dp = d.localFocalPoint - _lastFocal;
            _pan = _startPan + vm.Vector2(dp.dx, dp.dy) * 0.002 / _distance;
          } else {
            // one finger → orbit
            final dp = d.localFocalPoint - _lastFocal;
            _yaw = _startYaw + dp.dx * 0.01;
            _pitch = (_startPitch + dp.dy * 0.01)
                .clamp(-math.pi / 2 + 0.05, math.pi / 2 - 0.05);
          }
        });
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: CustomPaint(
          painter: _MeshPainter(
            scan: widget.scan,
            mode: widget.mode,
            yaw: _yaw,
            pitch: _pitch,
            distance: _distance,
            pan: _pan,
            background: widget.background,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// The software rasterizer. Kept as a plain painter so it can be reused for the
/// off-screen render (Photos snapshot) with a fixed camera.
class _MeshPainter extends CustomPainter {
  _MeshPainter({
    required this.scan,
    required this.mode,
    required this.yaw,
    required this.pitch,
    required this.distance,
    required this.pan,
    required this.background,
  });

  final Scan scan;
  final ShadeMode mode;
  final double yaw, pitch, distance;
  final vm.Vector2 pan;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final m = scan.mesh;
    if (m.isEmpty && (scan.pointCloud?.isEmpty ?? true)) {
      _drawEmpty(canvas, size);
      return;
    }

    // Fit: centre on the model and frame it by its bounding radius.
    final (bmin, bmax) = m.isEmpty
        ? _cloudBounds(scan.pointCloud!)
        : m.bounds();
    final center = (bmin + bmax) * 0.5;
    final radius = math.max(1e-3, (bmax - bmin).length * 0.5);

    // Camera: orbit around the centre. Distance is derived from the FOV so the
    // bounding sphere just fills the frame at zoom `distance == 1`, then divided
    // by `distance` as a zoom factor.
    const fovY = 45 * math.pi / 180;
    final aspect = size.width / math.max(1, size.height);
    final fitDist = CameraMath.fitDistance(radius, fovY, aspect);
    final camDist = fitDist / distance.clamp(0.3, 6.0);
    final eye = center +
        vm.Vector3(
          math.cos(pitch) * math.sin(yaw),
          math.sin(pitch),
          math.cos(pitch) * math.cos(yaw),
        ) *
            camDist;
    final view = CameraMath.lookAt(eye, center, vm.Vector3(0, 1, 0));
    final proj =
        CameraMath.perspective(fovY, aspect, camDist * 0.01, camDist * 4 + radius * 4);
    final mvp = proj * view;

    // light comes from just above the camera (a headlight)
    final lightDir = (center - eye).normalized();

    final w = size.width, h = size.height;
    final panPx = Offset(pan.x * w * 0.25, pan.y * h * 0.25);

    // Project a world point → screen (with pan). Returns null if behind camera.
    // Depth sorting uses _vertZ directly, so this only needs the 2D result.
    Offset? project(vm.Vector3 p) {
      final clip = mvp.transform(vm.Vector4(p.x, p.y, p.z, 1));
      if (clip.w <= 1e-6) return null;
      final ndcX = clip.x / clip.w;
      final ndcY = clip.y / clip.w;
      final sx = (ndcX * 0.5 + 0.5) * w + panPx.dx;
      final sy = (1 - (ndcY * 0.5 + 0.5)) * h + panPx.dy;
      return Offset(sx, sy);
    }

    final tris = m.triangleCount;
    final forcePoints = tris > MeshView.maxTrianglesForSolid;

    if (mode == ShadeMode.points || m.isEmpty || forcePoints) {
      _paintPoints(canvas, m, scan.pointCloud, project);
      if (forcePoints && mode != ShadeMode.points) {
        _hint(canvas, size, 'Large mesh — showing points. Optimize to view solid.');
      }
      return;
    }

    _paintTriangles(canvas, m, mvp, lightDir, project, w, h);
  }

  // ── triangle rasterization via painter's algorithm ──────────────────────────

  void _paintTriangles(
    Canvas canvas,
    MeshData m,
    vm.Matrix4 mvp,
    vm.Vector3 lightDir,
    Offset? Function(vm.Vector3) project,
    double w,
    double h,
  ) {
    final wire = mode == ShadeMode.wireframe;
    final heat = mode == ShadeMode.heatmap;

    // Build per-triangle records with a depth key, then sort back-to-front.
    final count = m.triangleCount;
    final order = List<int>.generate(count, (i) => i);
    final depth = Float32List(count);

    for (var t = 0; t < count; t++) {
      final ia = m.indices[t * 3], ib = m.indices[t * 3 + 1], ic = m.indices[t * 3 + 2];
      final az = _vertZ(m, ia, mvp);
      final bz = _vertZ(m, ib, mvp);
      final cz = _vertZ(m, ic, mvp);
      depth[t] = (az + bz + cz) / 3;
    }
    order.sort((a, b) => depth[b].compareTo(depth[a])); // far → near

    final fill = Paint()..style = PaintingStyle.fill;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = const Color(0xFF4CC2FF).withOpacity(0.55);

    for (final t in order) {
      final ia = m.indices[t * 3], ib = m.indices[t * 3 + 1], ic = m.indices[t * 3 + 2];
      final pa = _vert(m, ia), pb = _vert(m, ib), pc = _vert(m, ic);
      final sa = project(pa);
      final sb = project(pb);
      final sc = project(pc);
      if (sa == null || sb == null || sc == null) continue;

      // back-face cull in screen space (signed area)
      final area = (sb.dx - sa.dx) * (sc.dy - sa.dy) -
          (sc.dx - sa.dx) * (sb.dy - sa.dy);
      if (area <= 0) continue;

      final path = Path()
        ..moveTo(sa.dx, sa.dy)
        ..lineTo(sb.dx, sb.dy)
        ..lineTo(sc.dx, sc.dy)
        ..close();

      if (wire) {
        canvas.drawPath(path, stroke);
        continue;
      }

      // face normal (world) → lambert with the headlight
      final n = (pb - pa).cross(pc - pa);
      final nl = n.length;
      final lambert = nl < 1e-9 ? 0.5 : (0.35 + 0.65 * (n.dot(lightDir) / nl).abs());

      Color base;
      if (heat) {
        base = _heatColor(scan, ia, ib, ic);
      } else if (m.hasColors) {
        base = _avgVertexColor(m, ia, ib, ic);
      } else {
        base = const Color(0xFFBFC7D2);
      }
      fill.color = Color.fromARGB(
        255,
        (base.red * lambert).clamp(0, 255).toInt(),
        (base.green * lambert).clamp(0, 255).toInt(),
        (base.blue * lambert).clamp(0, 255).toInt(),
      );
      canvas.drawPath(path, fill);
    }
  }

  // ── point rendering (cloud, or mesh verts as fallback) ─────────────────────

  void _paintPoints(
    Canvas canvas,
    MeshData m,
    PointCloud? cloud,
    Offset? Function(vm.Vector3) project,
  ) {
    final dot = Paint()..style = PaintingStyle.fill;
    if (cloud != null && !cloud.isEmpty) {
      final hasColor = cloud.colors.isNotEmpty;
      for (var i = 0; i < cloud.count; i++) {
        final p = vm.Vector3(
            cloud.positions[i * 3], cloud.positions[i * 3 + 1], cloud.positions[i * 3 + 2]);
        final s = project(p);
        if (s == null) continue;
        dot.color = hasColor
            ? Color.fromARGB(255, cloud.colors[i * 4], cloud.colors[i * 4 + 1], cloud.colors[i * 4 + 2])
            : const Color(0xFF4CC2FF);
        canvas.drawCircle(s, 1.1, dot);
      }
      return;
    }
    // mesh vertices
    for (var v = 0; v < m.vertexCount; v++) {
      final s = project(_vert(m, v));
      if (s == null) continue;
      dot.color = m.hasColors
          ? Color.fromARGB(255, m.colors[v * 4], m.colors[v * 4 + 1], m.colors[v * 4 + 2])
          : const Color(0xFF8FB7CC);
      canvas.drawCircle(s, 1.0, dot);
    }
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  vm.Vector3 _vert(MeshData m, int i) =>
      vm.Vector3(m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2]);

  double _vertZ(MeshData m, int i, vm.Matrix4 mvp) {
    final v = mvp.transform(vm.Vector4(
        m.positions[i * 3], m.positions[i * 3 + 1], m.positions[i * 3 + 2], 1));
    return v.w.abs() < 1e-6 ? 0 : v.z / v.w;
  }

  Color _avgVertexColor(MeshData m, int a, int b, int c) {
    int ch(int i, int o) => m.colors[i * 4 + o];
    return Color.fromARGB(
      255,
      (ch(a, 0) + ch(b, 0) + ch(c, 0)) ~/ 3,
      (ch(a, 1) + ch(b, 1) + ch(c, 1)) ~/ 3,
      (ch(a, 2) + ch(b, 2) + ch(c, 2)) ~/ 3,
    );
  }

  Color _heatColor(Scan scan, int a, int b, int c) {
    final cloud = scan.pointCloud;
    if (cloud == null || cloud.confidence.isEmpty) return const Color(0xFF888888);
    // mesh verts don't map 1:1 to cloud confidence; approximate with a mid value.
    // A real heatmap samples the fused confidence field — tracked in ROADMAP.
    return const Color(0xFF33CC88);
  }

  (vm.Vector3, vm.Vector3) _cloudBounds(PointCloud c) {
    final min = vm.Vector3.all(double.infinity);
    final max = vm.Vector3.all(double.negativeInfinity);
    for (var i = 0; i < c.count; i++) {
      final x = c.positions[i * 3], y = c.positions[i * 3 + 1], z = c.positions[i * 3 + 2];
      if (x < min.x) min.x = x;
      if (y < min.y) min.y = y;
      if (z < min.z) min.z = z;
      if (x > max.x) max.x = x;
      if (y > max.y) max.y = y;
      if (z > max.z) max.z = z;
    }
    return (min, max);
  }

  void _drawEmpty(Canvas canvas, Size size) {
    final tp = TextPainter(
      text: const TextSpan(
          text: 'No geometry', style: TextStyle(color: Colors.white24)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
  }

  void _hint(Canvas canvas, Size size, String text) {
    final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: const TextStyle(color: Colors.white38, fontSize: 11)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    tp.paint(canvas, Offset(12, size.height - tp.height - 10));
  }

  // camera math
  @override
  bool shouldRepaint(_MeshPainter old) =>
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.distance != distance ||
      old.pan != pan ||
      old.mode != mode ||
      old.scan.mesh != scan.mesh;
}

/// Render a scan to a PNG off-screen (fixed 3/4 camera) for "Save to Photos".
/// Uses the same painter, so what you save matches what you see.
Future<Uint8List> renderScanToPng(
  Scan scan, {
  Size size = const Size(1200, 1200),
  Color background = const Color(0xFF0A0C10),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final painter = _MeshPainter(
    scan: scan,
    mode: ShadeMode.solid,
    yaw: 0.6,
    pitch: 0.5,
    distance: 1.0,
    pan: vm.Vector2.zero(),
    background: background,
  );
  painter.paint(canvas, size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width.toInt(), size.height.toInt());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/ui/camera_math.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

/// Guards the viewport camera math. The perspective matrix once shipped with its
/// w/z terms swapped, which collapsed the perspective divide and blew the
/// projection up ~16× (the model spilled off every edge). These tests pin the
/// two invariants that catch that: (1) clip.w equals the view-space depth, and
/// (2) a fitted bounding sphere lands fully on-screen and fills most of it.
void main() {
  const fovY = 45 * math.pi / 180;

  group('perspective matrix', () {
    test('clip.w equals view-space depth (perspective divide intact)', () {
      final p = CameraMath.perspective(fovY, 1.0, 0.1, 100);
      // a point 3 units in front of the camera (view space -z)
      final clip = p.transform(vm.Vector4(0.5, 0, -3, 1));
      expect(clip.w, closeTo(3.0, 1e-6));
      // ndcX = f * x / d, f = 1/tan(22.5°) = 2.4142
      final f = 1 / math.tan(fovY / 2);
      expect(clip.x / clip.w, closeTo(f * 0.5 / 3, 1e-4));
    });

    test('nearer points have smaller depth after divide', () {
      final p = CameraMath.perspective(fovY, 1.0, 0.1, 100);
      final near = p.transform(vm.Vector4(0, 0, -2, 1));
      final far = p.transform(vm.Vector4(0, 0, -8, 1));
      expect(near.z / near.w, lessThan(far.z / far.w));
    });
  });

  group('fit framing', () {
    /// Project the 8 corners of a unit cube and assert they all land on-screen
    /// and the model fills a healthy fraction of it.
    void expectFits(double aspect, double w, double h) {
      const s = 0.5;
      final radius = math.sqrt(3) * s; // cube half-diagonal
      final center = vm.Vector3.zero();
      const yaw = 0.6, pitch = 0.5;
      final fitDist = CameraMath.fitDistance(radius, fovY, aspect);
      final eye = vm.Vector3(
        math.cos(pitch) * math.sin(yaw),
        math.sin(pitch),
        math.cos(pitch) * math.cos(yaw),
      )..scale(fitDist);
      final view = CameraMath.lookAt(eye, center, vm.Vector3(0, 1, 0));
      final proj =
          CameraMath.perspective(fovY, aspect, fitDist * 0.01, fitDist * 4 + radius * 4);
      final mvp = proj * view;

      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final x in [-s, s]) {
        for (final y in [-s, s]) {
          for (final z in [-s, s]) {
            final clip = mvp.transform(vm.Vector4(x, y, z, 1));
            expect(clip.w, greaterThan(0)); // in front of camera
            final sx = (clip.x / clip.w * 0.5 + 0.5) * w;
            final sy = (1 - (clip.y / clip.w * 0.5 + 0.5)) * h;
            minX = math.min(minX, sx);
            maxX = math.max(maxX, sx);
            minY = math.min(minY, sy);
            maxY = math.max(maxY, sy);
          }
        }
      }
      // fully on-screen (1px slack)
      expect(minX, greaterThanOrEqualTo(-1));
      expect(maxX, lessThanOrEqualTo(w + 1));
      expect(minY, greaterThanOrEqualTo(-1));
      expect(maxY, lessThanOrEqualTo(h + 1));
      // fills a healthy fraction (not a tiny speck, not overflowing)
      final fill = math.max((maxX - minX) / w, (maxY - minY) / h);
      expect(fill, greaterThan(0.5));
      expect(fill, lessThanOrEqualTo(1.0));
    }

    test('square viewport', () => expectFits(1.0, 1000, 1000));
    test('portrait phone', () => expectFits(0.6, 600, 1000));
    test('landscape', () => expectFits(1.6, 1000, 625));
    test('photos render (1200²)', () => expectFits(1.0, 1200, 1200));
  });
}

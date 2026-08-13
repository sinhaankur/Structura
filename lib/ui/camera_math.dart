import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart' as vm;

/// Pure camera math for the software 3D viewport, factored out of the painter so
/// it's unit-testable (the projection had a subtle swapped-term bug that only a
/// test catches — see test/camera_math_test.dart).
class CameraMath {
  /// Right-handed look-at (view matrix), matching gluLookAt conventions.
  static vm.Matrix4 lookAt(vm.Vector3 eye, vm.Vector3 target, vm.Vector3 up) {
    final z = (eye - target).normalized();
    final x = up.cross(z).normalized();
    final y = z.cross(x);
    return vm.Matrix4(
      x.x, y.x, z.x, 0,
      x.y, y.y, z.y, 0,
      x.z, y.z, z.z, 0,
      -x.dot(eye), -y.dot(eye), -z.dot(eye), 1,
    );
  }

  /// Perspective projection. NOTE the term placement: the perspective-divide
  /// term (w = -z_view) is at setEntry(3, 2); the z-remap at setEntry(2, 3).
  /// Swapping them collapses w and blows the projection up ~16×.
  static vm.Matrix4 perspective(double fovY, double aspect, double near, double far) {
    final f = 1 / math.tan(fovY / 2);
    final m = vm.Matrix4.zero();
    m.setEntry(0, 0, f / aspect);
    m.setEntry(1, 1, f);
    m.setEntry(2, 2, (far + near) / (near - far));
    m.setEntry(3, 2, -1);
    m.setEntry(2, 3, (2 * far * near) / (near - far));
    return m;
  }

  /// Distance at which a bounding sphere of [radius] just fits the frame at
  /// [fovY]/[aspect], with a little margin. Zoom is applied by the caller as a
  /// divisor. Portrait frames fit against the narrower (vertical) field.
  static double fitDistance(double radius, double fovY, double aspect, {double margin = 1.15}) {
    final fovMin = aspect >= 1 ? fovY : 2 * math.atan(math.tan(fovY / 2) * aspect);
    return radius / math.tan(fovMin / 2) * margin;
  }
}

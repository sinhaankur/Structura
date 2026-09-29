import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/capture/coverage.dart';

/// Guards guided capture — the fix for "a lot is missing". Coverage rises as data
/// comes in, and a lopsided scan produces a directional gap hint.
void main() {
  Float32List grid(double x0, double x1, double z0, double z1, {double y = 0, double step = 0.25}) {
    final out = <double>[];
    for (var x = x0; x <= x1; x += step) {
      for (var z = z0; z <= z1; z += step) {
        out..add(x)..add(y)..add(z);
      }
    }
    return Float32List.fromList(out);
  }

  test('coverage is 0 empty, rises with data', () {
    final g = CoverageGrid();
    expect(g.coverage(), 0);
    g.addVertices(grid(0, 2, 0, 2));
    expect(g.coverage(), greaterThan(0.5)); // a filled floor patch
  });

  test('a full floor reads near-complete coverage', () {
    final g = CoverageGrid();
    g.addVertices(grid(0, 3, 0, 3));
    expect(g.coverage(), greaterThan(0.9));
  });

  test('a lopsided scan hints the empty direction', () {
    final g = CoverageGrid();
    // dense on the left half only (x 0..1), nothing on the right (x 2..4)
    g.addVertices(grid(0, 1, 0, 3));
    final hint = g.biggestGap();
    expect(hint, isNotNull);
    expect(hint!.direction, 'right');
    expect(hint.message.toLowerCase().contains('right'), true);
  });

  test('an even scan gives no strong hint', () {
    final g = CoverageGrid();
    g.addVertices(grid(0, 3, 0, 3)); // symmetric
    // may or may not hint; if it does, it must be a real imbalance, not noise
    final hint = g.biggestGap();
    if (hint != null) expect(hint.ratio, lessThanOrEqualTo(0.5));
  });

  test('clear resets', () {
    final g = CoverageGrid();
    g.addVertices(grid(0, 2, 0, 2));
    g.clear();
    expect(g.coverage(), 0);
    expect(g.filledCells, 0);
  });
}

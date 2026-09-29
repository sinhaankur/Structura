import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/mesh/scan_summary.dart';
import 'package:structura/mesh/llm_namer.dart';
import 'package:structura/model/scan.dart';

/// Guards the honest scan describer + the LLM-as-rephraser contract. The core is
/// deterministic and never invents; the LLM only rewords and falls back cleanly.
void main() {
  Scan roomScan({bool colored = true}) {
    // an 4×2.5×5 m box (room-like), one triangle is enough for the facts we test;
    // dimensions come from the vertex spread.
    final pos = Float32List.fromList([
      0, 0, 0,
      4, 0, 0,
      0, 2.5, 5,
    ]);
    return Scan(
      id: 'x',
      createdAt: DateTime(2026),
      quality: CaptureQuality.lidar,
      mesh: MeshData(
        positions: pos,
        indices: Uint32List.fromList([0, 1, 2]),
        colors: colored ? Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]) : null,
      ),
    );
  }

  test('facts are measured from geometry', () {
    final f = ScanSummary.facts(roomScan());
    expect(f.dimensions.x, closeTo(4, 1e-6));
    expect(f.dimensions.y, closeTo(2.5, 1e-6));
    expect(f.dimensions.z, closeTo(5, 1e-6));
    expect(f.floorAreaM2, closeTo(20, 1e-6)); // 4 × 5
    expect(f.isRoomLike, true);
    expect(f.hasColor, true);
  });

  test('classification histogram + salient classes (only what was seen)', () {
    // 100 faces: 60 wall, 30 floor, 8 window, 2 none → window is 8% (salient),
    // none excluded.
    final classes = <int>[
      ...List.filled(60, 1), // wall
      ...List.filled(30, 2), // floor
      ...List.filled(8, 6),  // window
      ...List.filled(2, 0),  // none
    ];
    final f = ScanSummary.facts(roomScan(), faceClasses: classes);
    final salient = f.salientClasses;
    expect(salient.contains(SurfaceClass.wall), true);
    expect(salient.contains(SurfaceClass.window), true);
    expect(salient.contains(SurfaceClass.none), false); // never surfaced
  });

  test('a window makes the name "sunlit" — but only when really seen', () {
    final withWin = ScanSummary.facts(roomScan(),
        faceClasses: [...List.filled(90, 1), ...List.filled(10, 6)]);
    expect(ScanSummary.suggestName(withWin).contains('sunlit'), true);

    final noWin = ScanSummary.facts(roomScan(), faceClasses: List.filled(100, 1));
    expect(ScanSummary.suggestName(noWin).contains('sunlit'), false);
  });

  test('describe() is honest about missing colour', () {
    final grey = ScanSummary.describe(ScanSummary.facts(roomScan(colored: false)));
    expect(grey.toLowerCase().contains('no colour'), true);
  });

  test('LlmNamer falls back to the deterministic name with no model', () async {
    final namer = LlmNamer(const NoTinyLlm());
    final f = ScanSummary.facts(roomScan());
    final name = await namer.name(f);
    expect(name, ScanSummary.suggestName(f)); // identical without a model
  });

  test('LlmNamer rejects an over-long or empty model answer (keeps the honest one)', () async {
    final f = ScanSummary.facts(roomScan());
    final det = ScanSummary.suggestName(f);
    expect(await LlmNamer(_FakeLlm('')).name(f), det);
    expect(await LlmNamer(_FakeLlm('x' * 200)).name(f), det);
    expect(await LlmNamer(_FakeLlm('Cozy studio')).name(f), 'Cozy studio');
  });
}

class _FakeLlm implements TinyLlm {
  _FakeLlm(this._out);
  final String _out;
  @override
  bool get available => true;
  @override
  Future<String?> rephrase({required String system, required String text}) async => _out;
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:structura/mesh/splat.dart';
import 'package:structura/model/scan.dart';

/// Guards the 3DGS seed exporter — an HONEST initial splat set (one gaussian per
/// captured point), loadable in any splat viewer/trainer. Not a trained field.
void main() {
  Scan scanWithCloud() => Scan(
        id: 's',
        createdAt: DateTime(2026),
        quality: CaptureQuality.lidar,
        mesh: MeshData(positions: Float32List(0), indices: Uint32List(0)),
        pointCloud: PointCloud(
          positions: Float32List.fromList([0, 0, 0, 1, 0, 0]),
          colors: Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
          confidence: Float32List.fromList([1.0, 0.5]),
        ),
      );

  String headerOf(Uint8List ply) {
    final end = utf8.decode(ply.sublist(0, 800), allowMalformed: true);
    return end.substring(0, end.indexOf('end_header') + 'end_header'.length);
  }

  test('writes a valid 3DGS PLY header with the standard properties', () {
    final ply = SplatExporter.encodeSeedPly(scanWithCloud());
    final h = headerOf(ply);
    expect(h.contains('format binary_little_endian 1.0'), true);
    expect(h.contains('element vertex 2'), true);
    for (final p in ['f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity',
      'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3']) {
      expect(h.contains('property float $p'), true, reason: 'missing $p');
    }
  });

  test('body is 14 floats per point after the header', () {
    final ply = SplatExporter.encodeSeedPly(scanWithCloud());
    final h = headerOf(ply);
    final headerLen = ascii.encode('$h\n').length;
    final bodyLen = ply.length - headerLen;
    expect(bodyLen, 2 * 14 * 4); // 2 points × 14 f32
  });

  test('is honestly labelled as an untrained seed', () {
    final h = headerOf(SplatExporter.encodeSeedPly(scanWithCloud()));
    expect(h.toLowerCase().contains('untrained') || h.toLowerCase().contains('seed'), true);
  });

  test('falls back to mesh verts when there is no cloud', () {
    final scan = Scan(
      id: 'm', createdAt: DateTime(2026), quality: CaptureQuality.lidar,
      mesh: MeshData(
        positions: Float32List.fromList([0, 0, 0, 1, 1, 1, 2, 0, 2]),
        indices: Uint32List.fromList([0, 1, 2]),
        colors: Uint8List.fromList([10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255]),
      ),
    );
    final ply = SplatExporter.encodeSeedPly(scan);
    expect(headerOf(ply).contains('element vertex 3'), true);
  });
}

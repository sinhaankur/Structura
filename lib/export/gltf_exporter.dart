import 'dart:convert';
import 'dart:typed_data';

import '../model/scan.dart';

/// glTF 2.0 / GLB exporter — the format for web (three.js, model-viewer) and a
/// clean interchange for most DCC tools. Emits a single binary buffer with
/// POSITION, optional NORMAL, optional COLOR_0, and the index buffer.
///
/// GLB (single file) is what the UI offers by default; a split .gltf + .bin is
/// available for pipelines that want the JSON separately.
class GltfExporter {
  /// Build the glTF JSON + the binary buffer. Returns both so the caller can
  /// pack a .glb or write .gltf/.bin. Positions are metres, Y-up (glTF's axis).
  static ({Map<String, dynamic> json, Uint8List bin}) build(
    MeshData m, {
    String name = 'structura',
  }) {
    final hasNormals = m.hasNormals;
    final hasColors = m.hasColors;

    // Assemble the binary buffer as concatenated, 4-byte-aligned bufferViews.
    final chunks = <Uint8List>[];
    final views = <Map<String, dynamic>>[];
    final accessors = <Map<String, dynamic>>[];
    var byteOffset = 0;

    int addView(Uint8List data, int target) {
      // pad to 4-byte alignment
      final pad = (4 - (data.lengthInBytes % 4)) % 4;
      final padded = pad == 0
          ? data
          : (Uint8List(data.lengthInBytes + pad)..setRange(0, data.lengthInBytes, data));
      chunks.add(padded);
      final view = {
        'buffer': 0,
        'byteOffset': byteOffset,
        'byteLength': data.lengthInBytes,
        'target': target,
      };
      views.add(view);
      byteOffset += padded.lengthInBytes;
      return views.length - 1;
    }

    // POSITION
    final posBytes = _f32Bytes(m.positions);
    final posView = addView(posBytes, 34962 /* ARRAY_BUFFER */);
    final (pmin, pmax) = m.bounds();
    accessors.add({
      'bufferView': posView,
      'componentType': 5126, // FLOAT
      'count': m.vertexCount,
      'type': 'VEC3',
      'min': [pmin.x, pmin.y, pmin.z],
      'max': [pmax.x, pmax.y, pmax.z],
    });
    final posAccessor = accessors.length - 1;

    int? normAccessor;
    if (hasNormals) {
      final nView = addView(_f32Bytes(m.normals), 34962);
      accessors.add({
        'bufferView': nView,
        'componentType': 5126,
        'count': m.vertexCount,
        'type': 'VEC3',
      });
      normAccessor = accessors.length - 1;
    }

    int? colorAccessor;
    if (hasColors) {
      // glTF COLOR_0 as normalized UNSIGNED_BYTE VEC4
      final cView = addView(m.colors, 34962);
      accessors.add({
        'bufferView': cView,
        'componentType': 5121, // UNSIGNED_BYTE
        'count': m.vertexCount,
        'type': 'VEC4',
        'normalized': true,
      });
      colorAccessor = accessors.length - 1;
    }

    // indices (UNSIGNED_INT)
    final idxView = addView(_u32Bytes(m.indices), 34963 /* ELEMENT_ARRAY_BUFFER */);
    accessors.add({
      'bufferView': idxView,
      'componentType': 5125, // UNSIGNED_INT
      'count': m.indices.length,
      'type': 'SCALAR',
    });
    final idxAccessor = accessors.length - 1;

    // concat buffer
    final total = chunks.fold<int>(0, (s, c) => s + c.lengthInBytes);
    final bin = Uint8List(total);
    var o = 0;
    for (final c in chunks) {
      bin.setRange(o, o + c.lengthInBytes, c);
      o += c.lengthInBytes;
    }

    final attributes = <String, int>{'POSITION': posAccessor};
    if (normAccessor != null) attributes['NORMAL'] = normAccessor;
    if (colorAccessor != null) attributes['COLOR_0'] = colorAccessor;

    final json = {
      'asset': {'version': '2.0', 'generator': 'Structura'},
      'scene': 0,
      'scenes': [
        {'nodes': [0]}
      ],
      'nodes': [
        {'mesh': 0, 'name': name}
      ],
      'meshes': [
        {
          'name': name,
          'primitives': [
            {
              'attributes': attributes,
              'indices': idxAccessor,
              'mode': 4, // TRIANGLES
              'material': 0,
            }
          ],
        }
      ],
      'materials': [
        {
          'name': 'structura',
          'pbrMetallicRoughness': {
            'baseColorFactor': [1, 1, 1, 1],
            'metallicFactor': 0.0,
            'roughnessFactor': 0.9,
          },
          'doubleSided': true,
        }
      ],
      'accessors': accessors,
      'bufferViews': views,
      'buffers': [
        {'byteLength': bin.lengthInBytes}
      ],
    };
    return (json: json, bin: bin);
  }

  /// Pack a self-contained .glb (12-byte header + JSON chunk + BIN chunk).
  static Uint8List encodeGlb(MeshData m, {String name = 'structura'}) {
    final built = build(m, name: name);
    // embed the buffer via the BIN chunk → drop the buffer.uri
    final jsonStr = jsonEncode(built.json);
    var jsonBytes = utf8.encode(jsonStr);
    // pad JSON chunk to 4 bytes with spaces
    final jpad = (4 - (jsonBytes.length % 4)) % 4;
    if (jpad != 0) {
      jsonBytes = Uint8List.fromList([...jsonBytes, ...List.filled(jpad, 0x20)]);
    }
    var bin = built.bin;
    final bpad = (4 - (bin.lengthInBytes % 4)) % 4;
    if (bpad != 0) {
      bin = Uint8List(built.bin.lengthInBytes + bpad)
        ..setRange(0, built.bin.lengthInBytes, built.bin);
    }

    final totalLen = 12 + 8 + jsonBytes.length + 8 + bin.lengthInBytes;
    final out = Uint8List(totalLen);
    final bd = ByteData.sublistView(out);
    var o = 0;
    // header
    bd.setUint32(o, 0x46546C67, Endian.little); // 'glTF'
    bd.setUint32(o + 4, 2, Endian.little); // version
    bd.setUint32(o + 8, totalLen, Endian.little);
    o += 12;
    // JSON chunk
    bd.setUint32(o, jsonBytes.length, Endian.little);
    bd.setUint32(o + 4, 0x4E4F534A, Endian.little); // 'JSON'
    o += 8;
    out.setRange(o, o + jsonBytes.length, jsonBytes);
    o += jsonBytes.length;
    // BIN chunk
    bd.setUint32(o, bin.lengthInBytes, Endian.little);
    bd.setUint32(o + 4, 0x004E4942, Endian.little); // 'BIN\0'
    o += 8;
    out.setRange(o, o + bin.lengthInBytes, bin);
    return out;
  }

  static Uint8List _f32Bytes(Float32List f) =>
      f.buffer.asUint8List(f.offsetInBytes, f.lengthInBytes);
  static Uint8List _u32Bytes(Uint32List u) =>
      u.buffer.asUint8List(u.offsetInBytes, u.lengthInBytes);
}

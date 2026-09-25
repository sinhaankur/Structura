import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/scan.dart';
import 'synthetic_scan.dart';

/// The Dart side of the native capture bridge.
///
/// Depth capture is platform-specific (ARKit on iOS, ARCore Depth on Android), so
/// only the *capture* is native — a thin plugin on each platform. Everything after
/// (viewer, editing, optimization, export) is shared Dart. This class is the whole
/// contract between the two.
///
/// Mesh/point data comes back as ONE binary blob per event (not per-vertex calls):
/// see [MeshCodec] for the layout. That keeps the channel cheap even at hundreds
/// of thousands of vertices.
class CaptureChannel {
  CaptureChannel._();
  static final CaptureChannel instance = CaptureChannel._();

  static const MethodChannel _method = MethodChannel('structura/capture');
  static const EventChannel _events = EventChannel('structura/capture/events');

  Stream<CaptureEvent>? _stream;

  /// Device-free test mode. When true, capture returns a SYNTHETIC raw scan
  /// (`SyntheticScan`) instead of talking to the native plugin — so the whole
  /// capture→process→view→export pipeline runs on a simulator / plain machine /
  /// in `flutter test`, with no LiDAR device. Off by default (real capture).
  /// The capture UI can flip this on when `querySupport()` reports no sensor, so
  /// the app is demonstrable everywhere and honestly labelled "Simulated".
  bool simulate = false;

  /// Whether this device can do depth capture at all, and at what quality.
  /// Called before showing the capture UI so we can guide the user honestly.
  Future<CaptureSupport> querySupport() async {
    try {
      final Map<Object?, Object?> r =
          await _method.invokeMethod('querySupport') as Map<Object?, Object?>;
      return CaptureSupport(
        supported: r['supported'] as bool? ?? false,
        quality: _qualityFromString(r['quality'] as String?),
        reason: r['reason'] as String?,
      );
    } on PlatformException catch (e) {
      return CaptureSupport(
        supported: false,
        quality: CaptureQuality.unknown,
        reason: e.message,
      );
    } on MissingPluginException {
      return const CaptureSupport(
        supported: false,
        quality: CaptureQuality.unknown,
        reason: 'Capture plugin not available on this platform build.',
      );
    }
  }

  /// Start a live capture session. Native begins pushing [CaptureEvent]s on the
  /// event stream (progress, incremental mesh chunks, coverage). In [simulate]
  /// mode there's no native session — the synthetic coverage stream drives the UI.
  Future<void> start({double voxelSizeMeters = 0.03}) {
    if (simulate) return Future<void>.value();
    return _method.invokeMethod('start', {'voxelSize': voxelSizeMeters});
  }

  /// Pause without discarding accumulated geometry.
  Future<void> pause() =>
      simulate ? Future<void>.value() : _method.invokeMethod('pause');

  /// Resume a paused session.
  Future<void> resume() =>
      simulate ? Future<void>.value() : _method.invokeMethod('resume');

  /// Stop + finalize. Native fuses everything and returns the completed [Scan]
  /// (mesh + point cloud + quality). Also ends the event stream.
  Future<Scan> finish() async {
    if (simulate) {
      // A realistic noisy raw scan, so the rest of the pipeline runs for real.
      return SyntheticScan.room();
    }
    final Map<Object?, Object?> r =
        await _method.invokeMethod('finish') as Map<Object?, Object?>;
    final meshBlob = r['mesh'] as Uint8List?;
    final cloudBlob = r['pointCloud'] as Uint8List?;
    return Scan(
      id: r['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
      quality: _qualityFromString(r['quality'] as String?),
      mesh: meshBlob != null ? MeshCodec.decodeMesh(meshBlob) : _emptyMesh(),
      pointCloud: cloudBlob != null ? MeshCodec.decodeCloud(cloudBlob) : null,
      gravityAligned: r['gravityAligned'] as bool? ?? false,
    );
  }

  /// Discard the session entirely.
  Future<void> cancel() =>
      simulate ? Future<void>.value() : _method.invokeMethod('cancel');

  /// Live events during capture (coverage %, incremental mesh, frame count). In
  /// [simulate] mode, a synthetic coverage ramp drives the progress ring so the
  /// capture screen behaves exactly as it would with a real sensor.
  Stream<CaptureEvent> events() {
    if (simulate) return _simulatedEvents();
    return _stream ??= _events
        .receiveBroadcastStream()
        .map((dynamic e) => CaptureEvent.fromMap(e as Map<Object?, Object?>))
        .handleError((Object err) {
      if (kDebugMode) debugPrint('capture event error: $err');
    });
  }

  /// A coverage ramp 0→1 over ~3.5s, ~6 updates/sec, mimicking a live scan.
  Stream<CaptureEvent> _simulatedEvents() async* {
    const steps = 20;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 175));
      final t = i / steps;
      yield CaptureEvent(
        coverage: t,
        frameCount: i * 10,
        vertexCount: (t * 12000).round(),
      );
    }
  }

  static CaptureQuality _qualityFromString(String? s) => switch (s) {
        'lidar' => CaptureQuality.lidar,
        'depthFromMotion' => CaptureQuality.depthFromMotion,
        _ => CaptureQuality.unknown,
      };

  static MeshData _emptyMesh() =>
      MeshData(positions: Float32List(0), indices: Uint32List(0));
}

/// What capture this device can do, surfaced before the user starts.
class CaptureSupport {
  const CaptureSupport({
    required this.supported,
    required this.quality,
    this.reason,
  });
  final bool supported;
  final CaptureQuality quality;

  /// Human-readable reason when [supported] is false (no ToF, ARCore missing…).
  final String? reason;
}

/// A live update during a capture session.
class CaptureEvent {
  CaptureEvent({
    required this.coverage,
    required this.frameCount,
    required this.vertexCount,
    this.incrementalMesh,
  });

  /// 0..1 rough scanned-coverage estimate (drives the progress ring).
  final double coverage;
  final int frameCount;
  final int vertexCount;

  /// Optional incremental mesh preview (decimated) for the live overlay.
  final MeshData? incrementalMesh;

  factory CaptureEvent.fromMap(Map<Object?, Object?> m) {
    final blob = m['preview'] as Uint8List?;
    return CaptureEvent(
      coverage: (m['coverage'] as num?)?.toDouble() ?? 0,
      frameCount: (m['frameCount'] as num?)?.toInt() ?? 0,
      vertexCount: (m['vertexCount'] as num?)?.toInt() ?? 0,
      incrementalMesh: blob != null ? MeshCodec.decodeMesh(blob) : null,
    );
  }
}

/// Binary layout for mesh/cloud blobs crossing the channel.
///
/// Little-endian. A tiny header then packed buffers. This is intentionally simple
/// (no protobuf dep) and symmetric with the native encoders in the plugins.
///
/// MESH blob:
///   magic  u32  0x53544D31 ('STM1')
///   vCount u32
///   iCount u32
///   flags  u32   bit0 = has normals, bit1 = has colors
///   positions  vCount*3  f32
///   normals    vCount*3  f32   (if bit0)
///   colors     vCount*4  u8    (if bit1)
///   indices    iCount    u32
///
/// CLOUD blob:
///   magic  u32  0x53544331 ('STC1')
///   pCount u32
///   flags  u32   bit0 = has colors, bit1 = has confidence
///   positions  pCount*3  f32
///   colors     pCount*4  u8    (if bit0)
///   confidence pCount     f32   (if bit1)
class MeshCodec {
  static const int meshMagic = 0x53544D31;
  static const int cloudMagic = 0x53544331;

  static MeshData decodeMesh(Uint8List blob) {
    final bd = ByteData.sublistView(blob);
    var o = 0;
    final magic = bd.getUint32(o, Endian.little);
    o += 4;
    if (magic != meshMagic) {
      throw const FormatException('bad mesh blob magic');
    }
    final vCount = bd.getUint32(o, Endian.little);
    o += 4;
    final iCount = bd.getUint32(o, Endian.little);
    o += 4;
    final flags = bd.getUint32(o, Endian.little);
    o += 4;
    final hasNormals = flags & 0x1 != 0;
    final hasColors = flags & 0x2 != 0;

    final positions = Float32List(vCount * 3);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = bd.getFloat32(o, Endian.little);
      o += 4;
    }
    Float32List normals = Float32List(0);
    if (hasNormals) {
      normals = Float32List(vCount * 3);
      for (var i = 0; i < normals.length; i++) {
        normals[i] = bd.getFloat32(o, Endian.little);
        o += 4;
      }
    }
    Uint8List colors = Uint8List(0);
    if (hasColors) {
      colors = Uint8List(vCount * 4);
      for (var i = 0; i < colors.length; i++) {
        colors[i] = bd.getUint8(o);
        o += 1;
      }
    }
    final indices = Uint32List(iCount);
    for (var i = 0; i < iCount; i++) {
      indices[i] = bd.getUint32(o, Endian.little);
      o += 4;
    }
    return MeshData(
      positions: positions,
      indices: indices,
      normals: normals,
      colors: colors,
    );
  }

  static PointCloud decodeCloud(Uint8List blob) {
    final bd = ByteData.sublistView(blob);
    var o = 0;
    final magic = bd.getUint32(o, Endian.little);
    o += 4;
    if (magic != cloudMagic) {
      throw const FormatException('bad cloud blob magic');
    }
    final pCount = bd.getUint32(o, Endian.little);
    o += 4;
    final flags = bd.getUint32(o, Endian.little);
    o += 4;
    final hasColors = flags & 0x1 != 0;
    final hasConf = flags & 0x2 != 0;

    final positions = Float32List(pCount * 3);
    for (var i = 0; i < positions.length; i++) {
      positions[i] = bd.getFloat32(o, Endian.little);
      o += 4;
    }
    Uint8List colors = Uint8List(0);
    if (hasColors) {
      colors = Uint8List(pCount * 4);
      for (var i = 0; i < colors.length; i++) {
        colors[i] = bd.getUint8(o);
        o += 1;
      }
    }
    Float32List conf = Float32List(0);
    if (hasConf) {
      conf = Float32List(pCount);
      for (var i = 0; i < pCount; i++) {
        conf[i] = bd.getFloat32(o, Endian.little);
        o += 4;
      }
    }
    return PointCloud(positions: positions, colors: colors, confidence: conf);
  }
}

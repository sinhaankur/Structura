import Foundation
import Flutter
import ARKit

/// iOS capture bridge — ARKit LiDAR Scene Reconstruction.
///
/// Implements the `structura/capture` MethodChannel + `structura/capture/events`
/// EventChannel that lib/capture/capture_channel.dart talks to. Depth mesh comes
/// from `ARMeshAnchor`s (requires a LiDAR device); we fuse them into one buffer
/// and hand it back as the STM1 blob the Dart `MeshCodec` decodes.
///
/// Wiring: register in AppDelegate:
///   StructuraCapturePlugin.register(with: registrar(forPlugin: "Structura")!)
@available(iOS 13.4, *)
final class StructuraCapturePlugin: NSObject, FlutterPlugin, ARSessionDelegate {

  private var eventSink: FlutterEventSink?
  private var session: ARSession?
  private var meshAnchors: [UUID: ARMeshAnchor] = [:]
  private var frameCount = 0

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = StructuraCapturePlugin()
    let method = FlutterMethodChannel(name: "structura/capture",
                                      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: method)
    let events = FlutterEventChannel(name: "structura/capture/events",
                                     binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  // MARK: - MethodChannel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "querySupport":
      result(querySupport())
    case "start":
      start()
      result(nil)
    case "pause":
      session?.pause()
      result(nil)
    case "resume":
      if let cfg = makeConfig() { session?.run(cfg) }
      result(nil)
    case "finish":
      result(finish())
    case "cancel":
      session?.pause(); session = nil; meshAnchors.removeAll()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func querySupport() -> [String: Any] {
    let hasLidar = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    if hasLidar {
      return ["supported": true, "quality": "lidar"]
    }
    // No LiDAR: ARKit can still world-track but won't give a real depth mesh.
    return [
      "supported": false,
      "quality": "unknown",
      "reason": "This iPhone has no LiDAR scanner. Structura needs a Pro model (iPhone 12 Pro or later) for depth capture.",
    ]
  }

  private func makeConfig() -> ARWorldTrackingConfiguration? {
    guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else { return nil }
    let cfg = ARWorldTrackingConfiguration()
    cfg.sceneReconstruction = .mesh          // request the LiDAR mesh
    cfg.environmentTexturing = .automatic
    if type(of: cfg).supportsFrameSemantics(.sceneDepth) {
      cfg.frameSemantics.insert(.sceneDepth) // per-pixel depth for the point cloud
    }
    return cfg
  }

  private func start() {
    guard let cfg = makeConfig() else { return }
    let session = ARSession()
    session.delegate = self
    session.run(cfg, options: [.resetSceneReconstruction, .removeExistingAnchors])
    self.session = session
    self.frameCount = 0
    self.meshAnchors.removeAll()
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    frameCount += 1
    // throttle: emit an event ~6×/sec
    if frameCount % 10 != 0 { return }
    let verts = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
    // A crude coverage proxy: unique mesh anchors seen, capped. Replace with a
    // real scanned-area metric once the fuse step lands.
    let coverage = min(1.0, Double(meshAnchors.count) / 40.0)
    eventSink?([
      "coverage": coverage,
      "frameCount": frameCount,
      "vertexCount": verts,
    ])
  }

  func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
    for a in anchors { if let m = a as? ARMeshAnchor { meshAnchors[m.identifier] = m } }
  }

  func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
    for a in anchors { if let m = a as? ARMeshAnchor { meshAnchors[m.identifier] = m } }
  }

  func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
    for a in anchors { meshAnchors.removeValue(forKey: a.identifier) }
  }

  // MARK: - Finalize → STM1 blob

  private func finish() -> [String: Any] {
    let blob = fuseMeshToBlob()
    session?.pause()
    let id = UUID().uuidString
    session = nil
    let result: [String: Any] = [
      "id": id,
      "quality": "lidar",
      "gravityAligned": true, // ARKit world Y is gravity-aligned
      "mesh": FlutterStandardTypedData(bytes: blob),
    ]
    meshAnchors.removeAll()
    return result
  }

  /// Concatenate every ARMeshAnchor's geometry (transformed to world space) into
  /// the STM1 layout the Dart MeshCodec decodes. Normals included; colors are
  /// left to the sampled-camera pass (TODO) so flags omit the color bit for now.
  private func fuseMeshToBlob() -> Data {
    var positions: [Float] = []
    var normals: [Float] = []
    var indices: [UInt32] = []
    var base: UInt32 = 0

    for anchor in meshAnchors.values {
      let geo = anchor.geometry
      let transform = anchor.transform
      let vBuf = geo.vertices
      let nBuf = geo.normals
      let vCount = vBuf.count

      let vPtr = vBuf.buffer.contents().advanced(by: vBuf.offset)
      let nPtr = nBuf.buffer.contents().advanced(by: nBuf.offset)

      for i in 0..<vCount {
        let v = vPtr.advanced(by: i * vBuf.stride)
          .assumingMemoryBound(to: (Float, Float, Float).self).pointee
        // local → world
        let world = transform * SIMD4<Float>(v.0, v.1, v.2, 1)
        positions.append(world.x); positions.append(world.y); positions.append(world.z)

        let n = nPtr.advanced(by: i * nBuf.stride)
          .assumingMemoryBound(to: (Float, Float, Float).self).pointee
        let wn = transform * SIMD4<Float>(n.0, n.1, n.2, 0)
        normals.append(wn.x); normals.append(wn.y); normals.append(wn.z)
      }

      // faces: geometry.faces is a triangle index buffer (UInt32 typically)
      let faces = geo.faces
      let idxPtr = faces.buffer.contents()
      let idxCount = faces.count * faces.indexCountPerPrimitive
      for i in 0..<idxCount {
        let idx = idxPtr.advanced(by: i * faces.bytesPerIndex)
          .assumingMemoryBound(to: UInt32.self).pointee
        indices.append(base + idx)
      }
      base += UInt32(vCount)
    }

    return encodeStm1(positions: positions, normals: normals, indices: indices)
  }

  /// STM1 blob: magic, vCount, iCount, flags, positions, normals, indices.
  private func encodeStm1(positions: [Float], normals: [Float], indices: [UInt32]) -> Data {
    let vCount = UInt32(positions.count / 3)
    let iCount = UInt32(indices.count)
    let flags: UInt32 = 0x1 // has normals; no colors yet
    var data = Data()
    func put32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func putF(_ v: Float) { var x = v.bitPattern.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    put32(0x53544D31) // 'STM1'
    put32(vCount)
    put32(iCount)
    put32(flags)
    for f in positions { putF(f) }
    for f in normals { putF(f) }
    for i in indices { put32(i) }
    return data
  }
}

@available(iOS 13.4, *)
extension StructuraCapturePlugin: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }
}

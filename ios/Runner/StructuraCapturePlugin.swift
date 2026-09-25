import Foundation
import Flutter
import ARKit

/// iOS capture bridge — ARKit LiDAR Scene Reconstruction.
///
/// Implements the `structura/capture` MethodChannel + `structura/capture/events`
/// EventChannel that lib/capture/capture_channel.dart talks to. Depth mesh comes
/// from `ARMeshAnchor`s (requires a LiDAR device); on finish() we fuse them into:
///   • an STM1 mesh blob — world-space positions + normals + per-vertex colors
///     sampled from the camera image,
///   • an STC1 point-cloud blob — world-space points from `sceneDepth`, colored,
///     with per-point confidence,
/// both decoded by the Dart `MeshCodec` and then cleaned by `ScanProcessor`.
///
/// Wiring: register in AppDelegate:
///   StructuraCapturePlugin.register(with: registrar(forPlugin: "Structura")!)
@available(iOS 13.4, *)
final class StructuraCapturePlugin: NSObject, FlutterPlugin, ARSessionDelegate {

  private var eventSink: FlutterEventSink?
  private var session: ARSession?
  private var meshAnchors: [UUID: ARMeshAnchor] = [:]
  private var frameCount = 0

  /// The most recent frame, kept so finish() can (a) sample vertex colors by
  /// projecting mesh verts into the camera image and (b) fuse a depth point
  /// cloud. Held weakly-in-spirit: replaced every throttled frame, cleared on
  /// finish/cancel so we never pin an ARFrame's buffers.
  private var lastFrame: ARFrame?

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
      session?.pause(); session = nil; meshAnchors.removeAll(); lastFrame = nil
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
    self.lastFrame = frame
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
    // Sample the camera image once (if we have a frame) so mesh verts get real
    // colors — giving the Dart processing pipeline the colored data it expects.
    let sampler = lastFrame.flatMap { ColorSampler(frame: $0) }
    let meshBlob = fuseMeshToBlob(colorSampler: sampler)
    let cloudBlob = lastFrame.flatMap { fuseCloudToBlob(frame: $0) }
    session?.pause()
    let id = UUID().uuidString
    session = nil
    var result: [String: Any] = [
      "id": id,
      "quality": "lidar",
      "gravityAligned": true, // ARKit world Y is gravity-aligned
      "mesh": FlutterStandardTypedData(bytes: meshBlob),
    ]
    if let cloudBlob { result["pointCloud"] = FlutterStandardTypedData(bytes: cloudBlob) }
    meshAnchors.removeAll()
    lastFrame = nil
    return result
  }

  /// Concatenate every ARMeshAnchor's geometry (transformed to world space) into
  /// the STM1 layout the Dart MeshCodec decodes. Normals always included; per-vertex
  /// colors are sampled from the camera image when a [ColorSampler] is available.
  private func fuseMeshToBlob(colorSampler: ColorSampler?) -> Data {
    var positions: [Float] = []
    var normals: [Float] = []
    var colors: [UInt8] = []
    var indices: [UInt32] = []
    var base: UInt32 = 0
    let wantColor = colorSampler != nil

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

        if wantColor {
          // Project the world vertex into the camera image and read its RGB.
          // Verts behind the camera / off-frame get a neutral grey so the buffer
          // stays complete (the processor averages colors on weld/decimate).
          let rgb = colorSampler?.color(atWorld: SIMD3<Float>(world.x, world.y, world.z))
            ?? (128, 128, 128)
          colors.append(rgb.0); colors.append(rgb.1); colors.append(rgb.2); colors.append(255)
        }
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

    return encodeStm1(positions: positions, normals: normals,
                      colors: wantColor ? colors : nil, indices: indices)
  }

  /// STM1 blob: magic, vCount, iCount, flags, positions, normals, [colors], indices.
  private func encodeStm1(positions: [Float], normals: [Float],
                          colors: [UInt8]?, indices: [UInt32]) -> Data {
    let vCount = UInt32(positions.count / 3)
    let iCount = UInt32(indices.count)
    var flags: UInt32 = 0x1 // bit0 = has normals
    if colors != nil { flags |= 0x2 } // bit1 = has colors
    var data = Data()
    func put32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func putF(_ v: Float) { var x = v.bitPattern.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    put32(0x53544D31) // 'STM1'
    put32(vCount)
    put32(iCount)
    put32(flags)
    for f in positions { putF(f) }
    for f in normals { putF(f) }
    if let colors { data.append(contentsOf: colors) }
    for i in indices { put32(i) }
    return data
  }

  // MARK: - Point cloud (STC1) from sceneDepth

  /// Fuse the frame's LiDAR depth map into a world-space colored point cloud with
  /// per-point confidence — the STC1 blob Dart's MeshCodec.decodeCloud reads. This
  /// is the raw fusion product the heatmap view + point-cloud export need; without
  /// it those features had no data. Subsampled so the cloud stays phone-sized.
  private func fuseCloudToBlob(frame: ARFrame, stride: Int = 4) -> Data? {
    guard let depth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
    let depthMap = depth.depthMap
    let confMap = depth.confidenceMap
    let sampler = ColorSampler(frame: frame)

    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
    let w = CVPixelBufferGetWidth(depthMap)
    let h = CVPixelBufferGetHeight(depthMap)
    guard let dBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
    let dRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

    var confBase: UnsafeMutableRawPointer?
    var confRow = 0
    if let confMap {
      CVPixelBufferLockBaseAddress(confMap, .readOnly)
      confBase = CVPixelBufferGetBaseAddress(confMap)
      confRow = CVPixelBufferGetBytesPerRow(confMap)
    }
    defer { if let confMap { CVPixelBufferUnlockBaseAddress(confMap, .readOnly) } }

    // Unproject: depth pixel → camera-space ray → world. Uses the frame's camera
    // intrinsics (scaled to the depth-map resolution) and the inverse view.
    let cam = frame.camera
    let intr = cam.intrinsics
    let refW = Float(cam.imageResolution.width)
    let sx = Float(w) / refW
    let sy = Float(h) / Float(cam.imageResolution.height)
    let fx = intr[0][0] * sx, fy = intr[1][1] * sy
    let cx = intr[2][0] * sx, cy = intr[2][1] * sy
    let viewToWorld = cam.transform

    var positions: [Float] = []
    var colors: [UInt8] = []
    var confs: [Float] = []

    for y in Swift.stride(from: 0, to: h, by: stride) {
      let dRow = dBase.advanced(by: y * dRowBytes).assumingMemoryBound(to: Float32.self)
      let cRow = confBase?.advanced(by: y * confRow).assumingMemoryBound(to: UInt8.self)
      for x in Swift.stride(from: 0, to: w, by: stride) {
        let z = dRow[x]
        if !z.isFinite || z <= 0 || z > 8 { continue } // valid depth window (m)
        // ARKit confidence: 0 low, 1 medium, 2 high. Keep medium+.
        let confRaw = cRow?[x] ?? 2
        if confRaw < 1 { continue }
        // pixel → camera-space point (camera looks down -Z)
        let px = (Float(x) - cx) / fx
        let py = (Float(y) - cy) / fy
        let camPt = SIMD4<Float>(px * z, py * z, -z, 1)
        let world = viewToWorld * camPt
        positions.append(world.x); positions.append(world.y); positions.append(world.z)

        let rgb = sampler.color(atWorld: SIMD3<Float>(world.x, world.y, world.z))
          ?? (128, 128, 128)
        colors.append(rgb.0); colors.append(rgb.1); colors.append(rgb.2); colors.append(255)
        confs.append(Float(confRaw) / 2.0) // → 0..1
      }
    }
    if positions.isEmpty { return nil }
    return encodeStc1(positions: positions, colors: colors, confidence: confs)
  }

  /// STC1 blob: magic, pCount, flags, positions, [colors], [confidence].
  private func encodeStc1(positions: [Float], colors: [UInt8], confidence: [Float]) -> Data {
    let pCount = UInt32(positions.count / 3)
    let flags: UInt32 = 0x1 | 0x2 // bit0 colors, bit1 confidence
    var data = Data()
    func put32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    func putF(_ v: Float) { var x = v.bitPattern.littleEndian; data.append(Data(bytes: &x, count: 4)) }
    put32(0x53544331) // 'STC1'
    put32(pCount)
    put32(flags)
    for f in positions { putF(f) }
    data.append(contentsOf: colors)
    for c in confidence { putF(c) }
    return data
  }
}

/// Samples the frame's captured camera image (YCbCr) at a projected world point,
/// returning an sRGB (r,g,b) triple. Used to color mesh verts + cloud points.
@available(iOS 13.4, *)
final class ColorSampler {
  private let frame: ARFrame
  private let width: Int
  private let height: Int

  init(frame: ARFrame) {
    self.frame = frame
    self.width = CVPixelBufferGetWidth(frame.capturedImage)
    self.height = CVPixelBufferGetHeight(frame.capturedImage)
  }

  /// Project a world point into the image and read its color. Returns nil when the
  /// point falls behind the camera or outside the frame.
  func color(atWorld p: SIMD3<Float>) -> (UInt8, UInt8, UInt8)? {
    let cam = frame.camera
    // World → normalized image point (0..1), accounting for current orientation.
    let pt = cam.projectPoint(
      p, orientation: .portrait,
      viewportSize: cam.imageResolution
    )
    let u = Float(pt.x) / Float(cam.imageResolution.width)
    let v = Float(pt.y) / Float(cam.imageResolution.height)
    if u < 0 || u > 1 || v < 0 || v > 1 { return nil }
    return sampleYCbCr(u: u, v: v)
  }

  /// Read the biplanar YCbCr420 captured image at (u,v) and convert to sRGB.
  private func sampleYCbCr(u: Float, v: Float) -> (UInt8, UInt8, UInt8)? {
    let img = frame.capturedImage
    CVPixelBufferLockBaseAddress(img, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
    guard let yBase = CVPixelBufferGetBaseAddressOfPlane(img, 0),
          let cBase = CVPixelBufferGetBaseAddressOfPlane(img, 1) else { return nil }
    let yRow = CVPixelBufferGetBytesPerRowOfPlane(img, 0)
    let cRow = CVPixelBufferGetBytesPerRowOfPlane(img, 1)
    let px = Int(u * Float(width - 1))
    let py = Int(v * Float(height - 1))
    let yVal = Float(yBase.advanced(by: py * yRow + px)
      .assumingMemoryBound(to: UInt8.self).pointee)
    // Chroma plane is half-resolution (4:2:0), interleaved Cb,Cr.
    let cbcr = cBase.advanced(by: (py / 2) * cRow + (px / 2) * 2)
      .assumingMemoryBound(to: UInt8.self)
    let cb = Float(cbcr[0]) - 128
    let cr = Float(cbcr[1]) - 128
    // BT.601 full-range YCbCr → RGB.
    let r = yVal + 1.402 * cr
    let g = yVal - 0.344136 * cb - 0.714136 * cr
    let b = yVal + 1.772 * cb
    func clamp(_ x: Float) -> UInt8 { UInt8(max(0, min(255, x))) }
    return (clamp(r), clamp(g), clamp(b))
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

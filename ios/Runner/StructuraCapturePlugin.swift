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

  /// The most recent frame, kept so finish() can fuse a depth point cloud and, as
  /// a fallback, sample colors. Cleared on finish/cancel so we never pin buffers.
  private var lastFrame: ARFrame?

  /// A sparse ring of posed keyframes captured through the WHOLE scan, so vertex
  /// coloring can draw on views of the whole space — not just wherever the camera
  /// happened to point at finish(). Without this, only the last frame's field of
  /// view got real color and the rest of the export came out grey (the exact
  /// grey-scan problem we set out to fix). Bounded, sampled by travel distance.
  private var keyframes: [ColorSampler] = []
  private var lastKeyframePosition: SIMD3<Float>?
  private let maxKeyframes = 24
  private let keyframeSpacingMeters: Float = 0.35

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
      keyframes.removeAll(); lastKeyframePosition = nil
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
    let cfg = ARWorldTrackingConfiguration()
    // Prefer meshWithClassification — ARKit tags each face wall/floor/ceiling/
    // table/window/door/seat for FREE. That's the "well-defined, labelled" scan
    // (surfaced as named submeshes on export). Fall back to plain mesh if a device
    // supports reconstruction but not classification.
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
      cfg.sceneReconstruction = .meshWithClassification
    } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      cfg.sceneReconstruction = .mesh
    } else {
      return nil
    }
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
    self.keyframes.removeAll()
    self.lastKeyframePosition = nil
  }

  // MARK: - ARSessionDelegate

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    frameCount += 1

    // Keyframe ring: whenever the camera has travelled far enough since the last
    // keyframe, snapshot a ColorSampler for this pose. Sampled by DISTANCE (not
    // time) so a slow, thorough scan and a quick one both get even coverage. This
    // is what lets finish() color the whole space, not just the final view.
    let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x,
                              frame.camera.transform.columns.3.y,
                              frame.camera.transform.columns.3.z)
    if shouldCaptureKeyframe(at: camPos) {
      captureKeyframe(frame: frame, at: camPos)
    }

    // throttle events ~6×/sec
    if frameCount % 10 != 0 { return }
    self.lastFrame = frame
    let verts = meshAnchors.values.reduce(0) { $0 + $1.geometry.vertices.count }
    let coverage = min(1.0, Double(meshAnchors.count) / 40.0)
    eventSink?([
      "coverage": coverage,
      "frameCount": frameCount,
      "vertexCount": verts,
      "keyframes": keyframes.count,
    ])
  }

  /// True when the camera has moved at least `keyframeSpacingMeters` from the last
  /// keyframe (or there is none yet).
  private func shouldCaptureKeyframe(at pos: SIMD3<Float>) -> Bool {
    guard let last = lastKeyframePosition else { return true }
    return simd_distance(pos, last) >= keyframeSpacingMeters
  }

  /// Snapshot a posed color sampler for this frame, evicting the oldest when full
  /// so memory stays bounded (a ColorSampler copies the small pose + intrinsics;
  /// it does NOT retain the ARFrame's pixel buffers — it reads them now).
  private func captureKeyframe(frame: ARFrame, at pos: SIMD3<Float>) {
    let sampler = ColorSampler(frame: frame, retainPixels: true)
    keyframes.append(sampler)
    lastKeyframePosition = pos
    if keyframes.count > maxKeyframes { keyframes.removeFirst() }
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
    // Color mesh verts from the WHOLE keyframe ring (each vertex gets the best
    // view that saw it), not just the last frame — so the entire space is colored,
    // not only the final field of view. Falls back to lastFrame if no keyframes.
    var samplers = keyframes
    if samplers.isEmpty, let f = lastFrame { samplers = [ColorSampler(frame: f, retainPixels: true)] }
    let meshBlob = fuseMeshToBlob(samplers: samplers)
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
    keyframes.removeAll()
    lastKeyframePosition = nil
    return result
  }

  /// Concatenate every ARMeshAnchor's geometry (transformed to world space) into
  /// the STM1 layout the Dart MeshCodec decodes. Normals always included. Each
  /// vertex is colored by the BEST keyframe that saw it (in front, in-frame,
  /// facing the camera, nearest) — so the whole space gets color, not just the
  /// last view. A vertex no keyframe saw stays neutral grey (honest, not invented).
  private func fuseMeshToBlob(samplers: [ColorSampler]) -> Data {
    var positions: [Float] = []
    var normals: [Float] = []
    var colors: [UInt8] = []
    var indices: [UInt32] = []
    var base: UInt32 = 0
    let wantColor = !samplers.isEmpty

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
        let world = transform * SIMD4<Float>(v.0, v.1, v.2, 1)
        positions.append(world.x); positions.append(world.y); positions.append(world.z)

        let n = nPtr.advanced(by: i * nBuf.stride)
          .assumingMemoryBound(to: (Float, Float, Float).self).pointee
        let wn = transform * SIMD4<Float>(n.0, n.1, n.2, 0)
        normals.append(wn.x); normals.append(wn.y); normals.append(wn.z)

        if wantColor {
          let wp = SIMD3<Float>(world.x, world.y, world.z)
          let wnorm = simd_normalize(SIMD3<Float>(wn.x, wn.y, wn.z))
          let rgb = bestColor(atWorld: wp, normal: wnorm, samplers: samplers) ?? (180, 176, 170)
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

  /// Pick the color for a world vertex from the best keyframe that saw it. Scores
  /// each candidate by proximity × facing (a camera looking at the vertex's front,
  /// from close, wins). Mirrors the Dart VertexColorizer so native + fallback agree.
  private func bestColor(atWorld p: SIMD3<Float>, normal n: SIMD3<Float>,
                         samplers: [ColorSampler]) -> (UInt8, UInt8, UInt8)? {
    var bestScore: Float = 0
    var best: (UInt8, UInt8, UInt8)?
    for s in samplers {
      guard let rgb = s.color(atWorld: p) else { continue }
      let toCam = s.cameraPositionWorld - p
      let dist = simd_length(toCam)
      if dist < 1e-4 { continue }
      let facing = simd_dot(n, toCam / dist)
      if facing <= 0.05 { continue } // camera sees the back
      let score = facing / dist
      if score > bestScore { bestScore = score; best = rgb }
    }
    return best
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

/// Samples a captured camera frame (YCbCr) at a projected world point, returning
/// an sRGB (r,g,b) triple. Used to color mesh verts + cloud points.
///
/// A ColorSampler can be a KEYFRAME kept for the whole scan: pass `retainPixels:
/// true` and it DEEP-COPIES the Y + CbCr planes at init (into `Data`) plus the
/// pose/intrinsics it needs, so it never touches the ARFrame again. This is
/// essential — ARKit recycles a frame's pixel buffers, so holding an ARFrame
/// across delegate callbacks would read freed memory / crash. The copy is small
/// (~a few MB per keyframe, bounded by maxKeyframes).
@available(iOS 13.4, *)
final class ColorSampler {
  private let width: Int
  private let height: Int

  // Pose + intrinsics captured at init (small, always copied).
  let cameraPositionWorld: SIMD3<Float>
  private let projectPoint: (SIMD3<Float>) -> CGPoint?

  // Deep-copied image planes (only when retainPixels). If nil we read live from
  // the retained frame (transient, single-frame use like the point cloud).
  private let yPlane: Data?
  private let cbcrPlane: Data?
  private let yRowBytes: Int
  private let cbcrRowBytes: Int
  private let liveFrame: ARFrame?

  init(frame: ARFrame, retainPixels: Bool = false) {
    let img = frame.capturedImage
    self.width = CVPixelBufferGetWidth(img)
    self.height = CVPixelBufferGetHeight(img)
    let cam = frame.camera
    let res = cam.imageResolution
    self.cameraPositionWorld = SIMD3<Float>(cam.transform.columns.3.x,
                                            cam.transform.columns.3.y,
                                            cam.transform.columns.3.z)
    // Capture the projection as a closure over an immutable copy of camera state,
    // so keyframes don't reference the ARFrame.
    let camCopy = cam
    self.projectPoint = { p in
      let pt = camCopy.projectPoint(p, orientation: .portrait, viewportSize: res)
      let u = Float(pt.x) / Float(res.width)
      let v = Float(pt.y) / Float(res.height)
      if u < 0 || u > 1 || v < 0 || v > 1 { return nil }
      return CGPoint(x: CGFloat(u), y: CGFloat(v))
    }

    if retainPixels {
      CVPixelBufferLockBaseAddress(img, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
      self.yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(img, 0)
      self.cbcrRowBytes = CVPixelBufferGetBytesPerRowOfPlane(img, 1)
      let yH = CVPixelBufferGetHeightOfPlane(img, 0)
      let cH = CVPixelBufferGetHeightOfPlane(img, 1)
      if let yb = CVPixelBufferGetBaseAddressOfPlane(img, 0),
         let cb = CVPixelBufferGetBaseAddressOfPlane(img, 1) {
        self.yPlane = Data(bytes: yb, count: yRowBytes * yH)
        self.cbcrPlane = Data(bytes: cb, count: cbcrRowBytes * cH)
      } else {
        self.yPlane = nil; self.cbcrPlane = nil
      }
      self.liveFrame = nil
    } else {
      self.yPlane = nil; self.cbcrPlane = nil
      self.yRowBytes = 0; self.cbcrRowBytes = 0
      self.liveFrame = frame
    }
  }

  /// Project a world point into the image and read its color. Returns nil when the
  /// point falls behind the camera or outside the frame.
  func color(atWorld p: SIMD3<Float>) -> (UInt8, UInt8, UInt8)? {
    guard let uv = projectPoint(p) else { return nil }
    return sampleYCbCr(u: Float(uv.x), v: Float(uv.y))
  }

  private func sampleYCbCr(u: Float, v: Float) -> (UInt8, UInt8, UInt8)? {
    let px = Int(u * Float(width - 1))
    let py = Int(v * Float(height - 1))
    let yVal: Float
    let cb: Float
    let cr: Float

    if let yData = yPlane, let cData = cbcrPlane {
      // read from the deep copies
      yVal = yData.withUnsafeBytes { raw -> Float in
        Float(raw.load(fromByteOffset: py * yRowBytes + px, as: UInt8.self)) }
      let (a, b) = cData.withUnsafeBytes { raw -> (Float, Float) in
        let off = (py / 2) * cbcrRowBytes + (px / 2) * 2
        return (Float(raw.load(fromByteOffset: off, as: UInt8.self)),
                Float(raw.load(fromByteOffset: off + 1, as: UInt8.self)))
      }
      cb = a - 128; cr = b - 128
    } else if let frame = liveFrame {
      let img = frame.capturedImage
      CVPixelBufferLockBaseAddress(img, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(img, .readOnly) }
      guard let yBase = CVPixelBufferGetBaseAddressOfPlane(img, 0),
            let cBase = CVPixelBufferGetBaseAddressOfPlane(img, 1) else { return nil }
      let yRow = CVPixelBufferGetBytesPerRowOfPlane(img, 0)
      let cRow = CVPixelBufferGetBytesPerRowOfPlane(img, 1)
      yVal = Float(yBase.advanced(by: py * yRow + px).assumingMemoryBound(to: UInt8.self).pointee)
      let cbcr = cBase.advanced(by: (py / 2) * cRow + (px / 2) * 2).assumingMemoryBound(to: UInt8.self)
      cb = Float(cbcr[0]) - 128; cr = Float(cbcr[1]) - 128
    } else {
      return nil
    }

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

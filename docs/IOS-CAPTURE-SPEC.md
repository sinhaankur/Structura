# Structura — iOS capture spec (using the platform's best)

> Goal: not just replicate Polycam, but build on the **best of what iOS uniquely
> offers**. This is the blueprint for the native capture project — deliberately
> detailed, because ARKit LiDAR capture is the deep, high-value part of Structura.
>
> Contract it must satisfy: emit `STM1` mesh / `STC1` cloud blobs (see
> `lib/capture/capture_channel.dart`) over the method channel to the Dart core,
> which already does optimize + export + view. On-device, private, offline.

## 1. The iOS capabilities worth building on (ranked)

| Apple tech | What it gives Structura | Use it for |
|---|---|---|
| **ARKit `sceneReconstruction` + `ARMeshAnchor`** | Live, fused LiDAR mesh with per-face **classification** (wall/floor/ceiling/table/window/door/seat) | The core room/space scan — geometry **already semantically labelled** |
| **`ARFrame.sceneDepth` (+ `smoothedSceneDepth`)** | Per-pixel LiDAR depth + **confidence** map | Point-cloud fusion, confidence-weighted cleaning |
| **`ARFrame.capturedImage`** (YCbCr) + camera intrinsics/transform | The RGB the sensor saw, posed | **Vertex colouring** (feeds `VertexColorizer`) — the fix for grey scans |
| **RealityKit `PhotogrammetrySession`** (Object Capture) | Photo → high-detail **textured USDZ** on-device | A second "Object / detail" mode: small objects at far higher fidelity than LiDAR |
| **TrueDepth (front camera)** | Structured-light depth, ~25–50 cm | A **face / bust** scan mode (rear LiDAR can't do close faces well) |
| **Model I/O (`MDLAsset`)** | Native **USDZ** read/write, AR Quick Look | USDZ export + "view in your room" via Quick Look |
| **Vision (`VNClassify`, `VNRecognizeText`)** | On-device object + text labels from the RGB frames | Room/object labelling, capture a sign/label into scan metadata |
| **Metal** | GPU point-cloud + mesh preview, TSDF | Fast live capture preview, heavy fusion off the CPU |
| **Foundation Models (on-device LLM, iOS 18+)** | Tiny on-device language model | See §4 — naming/describing only, never the geometry |

**The standout advantage over Polycam:** ARKit's `ARMeshAnchor` returns **face
classification for free** — every triangle already tagged wall/floor/window/door/
seat/table. That's the "well-defined, labelled" scan the raw export lacked, and
it's a platform gift we should surface, not throw away.

## 2. Capture modes (what the user picks)

1. **Room / Space** — `sceneReconstruction: .meshWithClassification`, rear LiDAR.
   Live coverage feedback; fuse `ARMeshAnchor`s; colour verts from `capturedImage`;
   carry the per-face class through to export as vertex groups / named submeshes.
2. **Object** — RealityKit `PhotogrammetrySession`: capture a ring of stills →
   on-device photogrammetry → textured USDZ. Far more detail than LiDAR for a
   sculpture, a machine part, a product.
3. **Face / Bust** — front **TrueDepth**; short range; for a head/face capture.

All three emit the same `STM1`/`STC1` contract, so the Dart side is mode-agnostic.

## 3. The capture flow (Room mode, the primary)

```
ARSession (worldTracking + .sceneDepth + .meshWithClassification)
  every frame:
    - accumulate ARMeshAnchors  → geometry + per-face classification
    - keep a sparse ring of posed keyframes (capturedImage + intrinsics + transform)
      throttled (e.g. 1 / 0.5 m of travel) so colouring has views without bloat
  live UI:
    - Metal preview of the growing mesh, coverage heat (confidence)
  on finish():
    - consolidate anchors → one MeshData (positions, normals, indices)
    - project keyframes → COLOR_0 (native, or hand geometry-only to VertexColorizer)
    - pack STM1 (+ STC1 cloud) → method channel → Dart
```

`StructuraCapturePlugin.swift` (stub exists) grows into: an `ARSCNView`/Metal
platform view, `ARSessionDelegate` accumulation, the keyframe ring, the STM1/STC1
encoders (symmetric with `MeshCodec`), and `finish()`.

## 4. tinyLLM — optional, phrasing only (Ankur's rule)

The deterministic core does all the real work (geometry, classification, measures).
An **on-device tiny LLM** (Apple Foundation Models on iOS 18+, else skip) is
**opt-in and only phrases**:
- **Name a scan** — "Sunlit corner studio, 5.9 × 8.4 m" from the real dims + the
  dominant `ARMeshAnchor` classes (never invents rooms it can't see).
- **Describe / label** — turn the *measured* class histogram ("62% wall, a window,
  a table, two seats") into a sentence for the scan card.
- **Q&A over a scan** — "how big is the kitchen area?" answered from real measured
  numbers the core computes; the LLM only words the answer.
Fed data at runtime, not trained. No LLM → the app is fully functional (templated
strings). Same doctrine as the rest of Ankur's stack: **model-free by default,
LLM = a nicety on top.**

## 5. Honesty + privacy (non-negotiable)
- Label the capture quality truthfully (`CaptureQuality.lidar` vs `depthFromMotion`)
  — never present depth-from-motion as LiDAR-clean.
- A vertex/region no sensor saw is left honest (grey / unlabelled), never invented.
- Everything on-device; nothing uploaded; `PRIVACY.md` already states this.

## 6. Build order (native)
1. ARSession + Metal live preview (see the mesh grow).
2. `ARMeshAnchor` consolidation → STM1 → Dart (real scan end-to-end).
3. Keyframe ring → vertex colour (kills the grey-scan problem).
4. Carry face classification → named submeshes on export.
5. USDZ via Model I/O + AR Quick Look ("view in your room").
6. Object mode (`PhotogrammetrySession`) and Face mode (TrueDepth).
7. Optional tinyLLM naming/description (Foundation Models), opt-in.
```
```

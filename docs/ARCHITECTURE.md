# Structura — Architecture

One Flutter app, two native capture plugins. Everything after capture is shared
Dart so iOS and Android behave identically.

## Data flow

```
                 ┌──────────────────────────────────────────────┐
   depth sensor  │  NATIVE plugin  (per platform)               │
   ────────────► │  iOS:    ARKit ARMeshAnchor + sceneDepth      │
                 │  Android: ARCore Depth API (16-bit depth)     │
                 │  → fuse frames → mesh + point cloud           │
                 │  → pack as STM1 / STC1 binary blob            │
                 └───────────────┬──────────────────────────────┘
                                 │  MethodChannel "structura/capture"
                                 │  EventChannel  "structura/capture/events"
                 ┌───────────────▼──────────────────────────────┐
                 │  DART  (shared)                               │
                 │  MeshCodec.decode → MeshData / PointCloud     │
                 │  MeshOptimizer   (weld/islands/decimate/norm) │
                 │  GL viewer       (orbit / shade)              │
                 │  Exporters       (OBJ/glTF/GLB/PLY/STL)       │
                 │  ExportService   (share sheet + save Photos)  │
                 │  USDZ ─── MethodChannel "structura/export" ──►│ native USDZ
                 └──────────────────────────────────────────────┘
```

## The capture contract

`lib/capture/capture_channel.dart` is the entire boundary. Methods:

| Method | Direction | Purpose |
|--------|-----------|---------|
| `querySupport` | Dart → native | Can this device capture depth, and at what quality? |
| `start` | Dart → native | Begin a session (`voxelSize` arg). |
| `pause` / `resume` | Dart → native | Hold / continue without discarding geometry. |
| `finish` | Dart → native | Fuse + return the completed scan (STM1 mesh + STC1 cloud). |
| `cancel` | Dart → native | Discard. |
| events stream | native → Dart | `{ coverage, frameCount, vertexCount, preview? }` ~6×/s. |

**Why one binary blob, not per-vertex calls:** a room scan is 100k–1M vertices.
Crossing the platform channel with typed-data blobs (see `MeshCodec`) is O(1)
calls; method-per-vertex would be unusable.

## Binary blob layouts

`MeshCodec` (Dart) ⇄ `encodeStm1` (Swift/Kotlin). Little-endian.

**STM1 (mesh):** `magic u32 | vCount u32 | iCount u32 | flags u32 | positions
vCount·3 f32 | [normals vCount·3 f32] | [colors vCount·4 u8] | indices iCount
u32`. flags bit0 = normals, bit1 = colors.

**STC1 (cloud):** `magic u32 | pCount u32 | flags u32 | positions pCount·3 f32 |
[colors pCount·4 u8] | [confidence pCount f32]`. flags bit0 = colors, bit1 = conf.

## Optimization (`lib/mesh/optimize.dart`)

Pure Dart, pure functions. Order in `autoClean`:

1. **weld** — spatial-hash merge of near-duplicate verts (chunk seams). 1–2mm.
2. **removeSmallIslands** — union-find; drop components under N triangles (noise).
3. **decimate** — vertex-clustering to a triangle budget. Fast + robust on
   non-manifold scan meshes (QEM is a later hero-export option).
4. **recomputeNormals** — area-weighted smooth normals.

> Large meshes should run these in an isolate (`compute()`), tracked as a TODO in
> the viewer. The ops themselves are isolate-safe (no Flutter deps).

## 3D viewport (`lib/ui/mesh_view.dart` + `camera_math.dart`)

A **software renderer** — deliberately no GL plugin / platform texture, so it runs
identically on iOS, Android, and the simulator, and an off-screen render for
"Save to Photos" is free (`ui.PictureRecorder → toImage`).

- Projects verts through an orbit camera, **depth-sorts triangles** (painter's
  algorithm), back-face culls in screen space, shades with a headlight lambert.
- Modes: **solid · wireframe · points · confidence**. Above 60k triangles it
  auto-drops to points so the UI stays smooth (the export is unaffected).
- **Framing** fits the model's bounding sphere to the FOV (`CameraMath.fitDistance`
  uses `radius / tan(fov/2)`), so any scan is framed regardless of size; `distance`
  is a zoom factor around that fit.
- Camera math is factored into `camera_math.dart` and unit-tested
  (`test/camera_math_test.dart`) — the perspective matrix's w/z term placement is
  load-bearing (swapping them blows the projection up ~16×), so it's pinned.

`renderScanToPng(scan)` runs the same painter with a fixed 3/4 camera → PNG bytes
for `ExportService.saveRenderToPhotos`.

## Export (`lib/export/`)

- `exporters.dart` — OBJ (+ vertex colors), binary STL, binary PLY (mesh + cloud).
- `gltf_exporter.dart` — glTF 2.0 JSON + a packed GLB (POSITION/NORMAL/COLOR_0).
- `export_service.dart` — format → temp file → **share sheet** (`share_plus`) or
  **Photos** (`gal`, image renders only). USDZ round-trips to the native plugin.

## Native wiring checklist (post-scaffold)

- iOS: register `StructuraCapturePlugin` in `AppDelegate`; add the AR camera
  platform view; implement the USDZ exporter via Model I/O (`MDLAsset`).
- Android: register `StructuraCapturePlugin` from `MainActivity`; add the GLSurface
  render loop that acquires depth + fuses; USDZ via a bundled converter.

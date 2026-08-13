# Structura

**Scan real structures with your phone's depth sensor, view them in 3D, clean the
data, and export to every tool you use.** One app, both platforms — iPhone
(ARKit LiDAR) and Android (ARCore Depth).

> Point your phone at a room, a building facade, a machine, a sculpture. Structura
> reconstructs a real, measured 3D mesh on-device — no cloud, no account — then
> lets you trim it, decimate it, measure it, and share it as USDZ, OBJ, glTF/GLB,
> PLY, or STL.

---

## Why

Good 3D capture is gate-kept behind expensive scanners and pro software. Modern
phones already carry a depth sensor and enough compute to do it. Structura turns
that sensor into an open, honest capture tool: **real measured geometry, exported
in open formats, editable in the tools people already have** (Blender, CAD,
three.js, MeshLab, a 3D printer).

Built to the same bar as the rest of the work: fidelity over spectacle, real data
never faked, on-device and private by default.

## What it does

| Stage | Detail |
|-------|--------|
| **Capture** | Real-time depth mesh from the LiDAR/ToF sensor (ARKit `sceneReconstruction` on iOS, ARCore Depth on Android). Live coverage feedback so you know what you've scanned. |
| **Reconstruct** | Fuse per-frame depth into one consistent mesh + a colored point cloud. Confidence-weighted so noisy points are dropped. |
| **View** | Orbit / pan / zoom the result in a real 3D viewer. Wireframe, solid, point-cloud, and confidence-heatmap shading. |
| **Optimize** | Decimate (quadric edge-collapse), remove floating islands, fill small holes, weld duplicate verts, cap texture size — with a live triangle/size budget. |
| **Measure** | Tap two points for a distance; area + bounding-box dimensions of the whole scan. |
| **Edit** | Crop to a box, delete selected regions, re-orient / set the ground plane. |
| **Export** | **USDZ · OBJ (+MTL) · glTF/GLB · PLY · STL.** Draco/meshopt compression for glTF; ASCII or binary PLY. |
| **Share** | System share sheet to any app, **plus save a render or the USDZ straight to Photos.** |

Everything runs **on-device and offline.** Nothing is uploaded.

## Platform support

| | iOS | Android |
|--|-----|---------|
| Capture API | ARKit Scene Reconstruction (LiDAR) | ARCore Depth API (ToF where present, depth-from-motion otherwise) |
| Best devices | iPhone Pro / iPad Pro (LiDAR) | Pixel / Samsung with depth; ARCore-supported phones |
| Min OS | iOS 17 | Android 10 (API 29) |

> LiDAR gives the cleanest mesh; ARCore Depth works on a wide range of phones but
> is noisier. Structura labels the capture quality it actually achieved — it never
> pretends a depth-from-motion scan is LiDAR-clean.

## Architecture

```
Flutter (Dart) — UI, 3D viewer, editing, optimization, export, Photos
   │
   ├── MethodChannel  "structura/capture"
   │
   ├── iOS   plugin (Swift)  → ARKit ARMeshAnchor → depth frames + mesh chunks
   └── Android plugin (Kotlin) → ARCore Depth Image → point cloud + TSDF fuse
```

- **Capture** is native (thin plugins) because the depth APIs are platform-specific.
- **Everything after capture is shared Dart** — one implementation of the mesh
  ops, viewer, exporters, and share logic, so the two platforms stay identical.
- Mesh data crosses the channel as a compact binary blob (positions / normals /
  colors / indices), never per-vertex method calls.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full data flow and the
capture-plugin contract.

## Status

🚧 Early scaffold. The Dart architecture, plugin interface, data model, exporter
specs, and platform stubs are in place. Native capture wiring + the mesh-ops
implementations are the next build.

## Build

```bash
# one-time: install Flutter (https://docs.flutter.dev/get-started/install)
flutter pub get
flutter run            # on a connected iPhone Pro or ARCore-Depth Android phone
```

The Simulator/Emulator can run the UI but **not** depth capture — you need a real
device with a depth sensor.

## Privacy

On-device only. No account, no analytics, no network calls for capture or
processing. Camera + depth are used solely to build your scan; Photos access is
only used when *you* save an export. See [`PRIVACY.md`](PRIVACY.md).

## License

MIT — see [`LICENSE`](LICENSE). © Ankur Sinha.

# Structura — Roadmap

Scaffold status and the ordered build after it. ✅ done · 🟡 partial · ⬜ next.

## Done (scaffold)
- ✅ Flutter project skeleton (pubspec, theme, home/capture/viewer screens)
- ✅ Scan data model (`MeshData`, `PointCloud`, `Scan`, honest `CaptureQuality`)
- ✅ Capture channel contract + STM1/STC1 binary codec
- ✅ Mesh optimization (weld · islands · vertex-cluster decimate · normals · autoClean)
- ✅ Exporters: OBJ, glTF/GLB, PLY (mesh + cloud), STL
- ✅ Export service (share sheet + save-to-Photos), USDZ native round-trip
- ✅ Native plugin stubs: iOS ARKit (`ARMeshAnchor` fuse), Android ARCore Depth
- ✅ Unit tests for the pure-Dart core
- ✅ Docs (README, ARCHITECTURE, PRIVACY), Info.plist + AndroidManifest privacy

## Next
1. ✅ **3D viewport** (`lib/ui/mesh_view.dart`) — interactive software renderer
   (no GL plugin): orbit/pan/pinch, painter's-algorithm depth sort, headlight
   lambert, solid/wireframe/points/confidence modes, FOV-fit framing, auto
   points-fallback above 60k tris. `renderScanToPng()` gives the Photos render
   (`ui.PictureRecorder → toImage`). Camera math in `camera_math.dart`, tested.
2. ⬜ **iOS capture wiring** — AR camera platform view; register plugin in
   `AppDelegate`; sample camera colors onto mesh verts (COLOR_0).
3. ⬜ **Android capture wiring** — GLSurface render loop: acquire depth image →
   back-project → TSDF fuse → marching cubes at finish.
4. ⬜ **USDZ exporters** — iOS Model I/O (`MDLAsset`); Android converter.
5. ⬜ **Measure tool** — tap-two-points distance; bounding-box readout in-viewport.
6. ⬜ **Editing** — crop-to-box, delete region, set ground plane / re-orient.
7. ⬜ **Isolate the heavy mesh ops** (`compute()`), progress UI.
8. ⬜ **Scan library** — persist scans locally, thumbnails, re-open/export.
9. ⬜ **Install/landing page** (GitHub Pages) once a device build runs.

## Known scaffold limitations
- The 3D viewport is live; the capture screen still shows a placeholder where the
  native AR camera surface will mount.
- Android `finish()` returns an empty mesh until the fuse+march step lands.
- `.gltf` currently emits a self-contained GLB under the name; split gltf+bin later.
- Heavy ops run on the UI isolate for now (fine for small meshes).

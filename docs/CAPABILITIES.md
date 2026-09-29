# Structura — capability map + deep-tech build

> What Polycam (and the best scanners) can do, mapped to what Structura will do —
> open-source, on-device, honest. Ordered roughly by build depth. This is the
> north-star surface; `ROADMAP.md` sequences it, `IOS-CAPTURE-SPEC.md` details the
> native capture, this file is the **full menu** including the deep-tech frontier.
>
> Legend: ✅ built · 🟡 partial/stub · ⬜ planned · 🔬 deep-tech (research-grade)

## A. Capture (get the data)
| Capability | Structura | Notes |
|---|---|---|
| LiDAR mesh (rooms/objects) | 🟡 | ARKit `meshWithClassification` wired; verify on device |
| Depth point cloud + confidence | ✅ | `sceneDepth` → STC1, confidence-weighted |
| **Photo mode (photogrammetry)** | ⬜ | RealityKit `PhotogrammetrySession` → textured USDZ; far more detail than LiDAR for objects |
| **Face/bust mode (front TrueDepth)** | ⬜ | structured-light depth, close range |
| Whole-space vertex colour | ✅ | keyframe ring + projective colouring (`vertex_colorizer`) |
| Live coverage / quality feedback | 🟡 | coverage + keyframe count events; add a coverage HEATMAP so you SEE gaps live |
| **Guided capture** | ⬜ | tell the user what's missing mid-scan (ceiling, that dark corner) — kills "a lot is missing" at the source |

## B. Reconstruct (turn frames into a model)
| Capability | Structura | Notes |
|---|---|---|
| Anchor mesh fusion | ✅ | consolidate `ARMeshAnchor`s |
| TSDF fuse + marching cubes (Android) | 🟡 | stub; the depth→volume→mesh path |
| **De-drift / de-duplicate** | ⬜ | the "two toilets" fix — merge overlapping shells (measured 2.93× overlap on a real scan); confidence-reject shiny-surface ghosts |
| **Hole fill / gap repair** | ⬜ | patch windows/mirrors/occlusion dropouts (honest, flagged as inferred) |
| **🔬 Gaussian Splatting** | 🔬 | photoreal radiance-field capture from the posed frames — the current state of the art for "it looks exactly like the room"; render in-app via a splat renderer, export `.ply`/`.splat` |
| **🔬 NeRF / neural surface** | 🔬 | alternative photoreal reconstruction; heavier, on-device is frontier |

## C. Understand (make it smart, not just a shape)
| Capability | Structura | Notes |
|---|---|---|
| Per-face semantic class | ✅ | ARKit gives wall/floor/ceiling/window/door/table/seat free |
| **Room segmentation** | ⬜ | split a multi-room scan into named rooms (from classes + connectivity) |
| **Object detection / labels** | ⬜ | Vision + the class data → "bunk bed", "sink"; feeds the tinyLLM naming |
| **Auto floor-plan** | ⬜ | project walls → a clean 2D architectural plan with door/window openings + dimensions |
| On-device scan naming/描述 | ✅ | `scan_summary` (deterministic) + `llm_namer` (tinyLLM, phrasing only) |

## D. Interact (view + use it)
| Capability | Structura | Notes |
|---|---|---|
| 3D viewport (orbit/solid/wire/points) | ✅ | software renderer; web reference viewer built |
| Measure (tap-two-points, area, bbox) | ⬜ | real metric measures in-viewport |
| Edit (crop, delete region, re-orient) | ⬜ | clean up a scan by hand |
| **AR mode — view the house in your room** | ⬜ | **you asked for this.** Place the scan at real scale via ARKit + AR Quick Look (USDZ), or a live `ARView`: walk around your captured condo as a hologram, or drop a scanned object onto your real desk |
| **AR mode — walk-through / first person** | ⬜ | stand inside the scanned space in AR/VR, doll-house ↔ life-size |
| **Web share (three.js / <model-viewer>)** | 🟡 | the web viewer is the seed; a shareable link per scan |

## E. Export + share (get it out)
| Capability | Structura | Notes |
|---|---|---|
| OBJ · glTF/GLB · PLY · STL | ✅ | all done, + Draco/meshopt |
| **USDZ** (AR Quick Look) | ⬜ | native Model I/O; the key AR + Apple-ecosystem format |
| Save render / model to Photos | ✅ | share sheet + Photos |
| Point-cloud export (PLY) | ✅ | mesh + cloud |
| Splat export (`.ply`/`.splat`) | 🔬 | with Gaussian Splatting |

## The deep-tech spine (what makes Structura more than a wrapper)
1. **Guided + heatmap capture** — the app shows gaps live, so scans stop coming out
   with "a lot missing". (Highest ROI: fixes the root cause.)
2. **De-drift + hole-repair** — turn a messy handheld scan into a clean model
   (the two-toilets / doubled-table / missing-window problems).
3. **Gaussian Splatting on-device** — photoreal capture that looks like the real
   room, the current frontier; the biggest "wow" and a real research build.
4. **Semantics → floor-plan + AR** — classes → rooms → a clean plan, and view the
   whole thing in AR at real scale.

All on-device, private, open-source, honest (missing/inferred data always labelled).

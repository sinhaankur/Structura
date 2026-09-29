# Structura — Gaussian Splatting (honest plan)

> 3D Gaussian Splatting (3DGS) is the current state of the art for capture that
> **looks exactly like the real room** — the scene is thousands of tiny coloured,
> oriented gaussians, not a mesh. This is the deep-tech frontier for Structura.
>
> **Honesty first:** a full on-device *trained* radiance field is a heavy research
> build (SfM/known poses + differentiable rendering + optimisation, GPU/Metal). We
> do NOT ship fake splatting. What ships now is the real, verifiable first step;
> the rest is specced here so it's built for real, not faked.

## What's built now (real)
`lib/mesh/splat.dart` — **`SplatExporter.encodeSeedPly`**: writes the captured
point cloud (positions + colour + confidence — which Structura already produces)
as a **standard 3DGS `.ply`**: `x y z · f_dc_0..2 (colour→SH DC) · opacity
(confidence→logit) · scale_0..2 (isotropic seed) · rot_0..3 (identity)`. This is
the **initial splat set** every 3DGS pipeline starts from, and it loads directly in
Inria's viewer, gsplat, PlayCanvas, Nerfstudio. Labelled honestly in the header as
an *untrained seed* — never presented as a finished radiance field.

## The full pipeline (to build, in order)
1. **Posed keyframes** — reuse the capture keyframe ring (already added for vertex
   colouring): each keyframe has an RGB image + camera intrinsics + world pose.
   3DGS needs exactly this (poses come free from ARKit — no separate SfM needed,
   a big on-device advantage over desktop 3DGS).
2. **Seed** — `encodeSeedPly` (done): initialise gaussians from the LiDAR points.
3. **Differentiable rasteriser (Metal)** — render the gaussians to each keyframe's
   view; the hard part. Port the 3DGS tile-based rasteriser to Metal compute.
4. **Optimise** — gradient-descent the gaussians (position, scale, rotation, SH
   colour, opacity) to match the keyframe images; adaptive densify/prune. Budgeted
   (fewer iterations / gaussians) so it finishes on a phone.
5. **Render + export** — an in-app Metal splat viewer; export the trained `.ply`/
   `.splat` (the seed format already matches, so export is "write the optimised
   gaussians in the same layout").

## Honest scoping
- Steps 1–2 and 5-export are real and mostly in hand (poses + seed + PLY format).
- Steps 3–4 (Metal rasteriser + optimiser) are the research build — weeks of GPU
  work, verified on-device. Until then Structura still gives a real 3DGS **seed**
  the user can train elsewhere, and its LiDAR mesh + textured export for everything
  else. We ship what's real at each step and label the rest.

## Why this is the right frontier for Structura
Desktop 3DGS needs COLMAP to *recover* camera poses from photos — slow, fragile.
On iOS, **ARKit already gives exact poses**, so Structura can seed + train from a
walk-through with no SfM. That's the genuine edge: on-device, pose-free-for-the-user
photoreal capture. Open-source. Honest about what's trained vs seeded.

# Aurelia Shaders — Phase 4: Luxium-class speed and features

Goal: Balanced holds **80+ FPS at 1920x1080 on the M1 MacBook Air (8 GB)** in an
ordinary Overworld scene, while gaining the cheap effects the Luxium mod has.
Everything stays an Iris shaderpack: forward lighting, one scene target, one
`final` pass.

## Where Luxium's speed comes from (and what we can copy)

Luxium (Vinlanx, 1.20.1 mod) was studied by decompiling it for its feature set
only. Its license forbids reusing its code, shaders or "algorithms as expressed
in the source code", so nothing from it is used here. Every effect below is a
standard, well-known technique written for this pack.

| Luxium trick | Usable in an Iris pack? |
| --- | --- |
| Sun shadow maps rebuilt every ~1 s, not every frame | No. Iris draws the shadow pass every frame. |
| Fog / god rays / lens flare at 0.44x resolution | Partly: we keep them ALU-cheap in `final` instead. |
| Expensive extras off by default | Yes: every Phase 4 effect is an option, priced below. |
| LSR (internal render scale) and TFR (frame generation) | No. Mod-only. |
| Opaque ice | Yes: Iris 1.7.6 reads `layer.solid` in `block.properties`. |

## Measured costs before Phase 4

`tools/bench_gpu.py` (GPU timer queries around each stage of the offline
preview scene, M1, 1920x1080, Balanced, median of 40 frames; about ±0.4 ms
noise). Stage figures include about 0.5 ms of query overhead each.

| Change | GPU time saved |
| --- | --- |
| Cloud layer off, overview camera | ~1.0 ms |
| Cloud layer off, looking at the sky | **~4.9 ms** (sky stage 7.2 -> 2.3 ms) |
| Atmosphere dome off | ~0.9 ms |
| Shadows off | ~0.9 ms (CPU draw-call cost in a city is extra, not measured here) |
| Water surface, foliage translucency off | < 0.5 ms each |

The sky program runs before terrain, so its cost is paid for every pixel on
screen, not just visible sky. The painted cloud layer's hash-based noise (eight
value-noise octaves, four hashes each, per pixel) was the single largest cost
in the pack.

Settings outside the pack that matter: the Metropolis instance is capped at
`maxFps:80`, so it can never show more than 80.

## Work list

Performance (do first, measure each):

- [x] **P4.1 Cloud layer on `noisetex`.** One texture fetch per octave instead of
      four hashes; fewer octaves for the self-shadow tap. Harness binds an
      identical `noisetex` (Java `Random(0)` bytes) so previews stay exact.
- [x] **P4.2 Solid terrain without `discard`.** `gbuffers_terrain_solid` (Iris
      1.7.6 program) has no alpha test, so Apple's tile GPU can skip shading
      hidden fragments, including the sky behind terrain.
- [x] **P4.3 Entity shadow option.** All / player only / off
      (`shadowEntities`, `shadowPlayer`, `shadowBlockEntities`). Cities with
      trains, signs and chests pay heavily for entity casters on the CPU.
- [x] **P4.4 Per-vertex fog colour** for terrain if the bench shows a gain.
- [x] **P4.5 Profile retune.** Balanced = the 80 FPS target; Cinematic carries
      the expensive extras.

Features (all options, all priced with the bench):

- [x] **F1 Waving plants and leaves.** Vertex-only sway with gusts; casters
      sway identically in `shadow.vsh`.
- [x] **F2 Rain wetness, puddles and ripples.** Upward sky-lit faces darken and
      reflect the analytic sky with Fresnel; a `noisetex` mask makes puddles;
      ripple rings in puddles. Zero cost in dry weather.
- [x] **F3 Lens flare and sun glare.** Sun visibility from a few depth reads in
      `final.vsh` (once per vertex), analytic ghosts and halo in `final.fsh`.
- [x] **F4 Height fog and sun scattering.** Fog thins with altitude and glows
      toward the sun.
- [x] **F5 Bloom** from the `colortex0` mip chain in `final`.
- [x] **F6 Second, high cloud layer** with its own wind, scale and rain response.
- [x] **F7 Screen-space god rays** (Cinematic only) in `final`.
- [x] **F8 Opaque ice** through `layer.solid`.
- [x] **F9 Sharpening** (contrast-adaptive) in `final`, optional.

Everything needs an in-game check before it is called done: the tools prove
compilation, offline look and offline GPU cost only. "Done" above means
implemented and passing the validator and tests.

## Results (offline, M1, 1920x1080, median of 40 frames)

Total GPU time per frame, `main` -> this branch, with each profile's new
effects on:

| Profile | Overview camera | Looking at the sky |
| --- | --- | --- |
| Potato | 5.6 -> 4.0 ms | |
| Low | 9.4 -> 6.1 ms | |
| Balanced | 9.5 -> 7.0 ms | 8.3 -> 5.9 ms |
| Cinematic | 10.0 -> 8.2 ms | |
| Adaptive | 10.0 -> 7.2 ms | |

Where it came from: sky stage 4.9 -> 2.9 ms (cloud layer on `noisetex`, sky
palette as flat varyings, early star exit), terrain 2.7 -> 2.3 ms (per-vertex
fog). Sky output is bit-identical to `main` with the cloud layer off.

Price of each effect: wet surfaces ~0.2 ms (rain only), cirrus ~0.6 ms
(looking up), lens flare ~0.6 ms (sun on screen only; the cost is the
fragment math, and culling the ghosts off-axis did not help), god rays
~1.0 ms, bloom ~1.2 ms, sharpen ~0.6 ms, height fog and haze negligible.

Not measurable offline: the hidden-surface-removal gain from solid terrain
without `discard`, and the CPU saving from fewer entity shadow casters. Both
are likely the largest wins in a real city and need an in-game FPS check.

## In-game checklist

Raise Minecraft's `maxFps` above 80 first (the Metropolis instance is capped at
80). Then check, in Balanced: FPS in a busy town; waving plants (double plants
move as one, shadows sway with them); opaque ice; rain puddles and ripples;
lens flare when the sun goes behind blocks; height fog from a mountain; entity
shadows (player only); Cinematic god rays and bloom.

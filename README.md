# Aurelia Shaders

Aurelia is a lightweight, original Iris shaderpack for Minecraft Java 1.20.1,
built for Apple Silicon laptops. The goal is photographic realism (a
physically based sky, water and materials) at a cost an M1 MacBook Air can
carry under a heavy modpack such as Aurelia Metropolis. No temporal history,
no compute, nothing that needs more than a handful of small targets.

## Pipeline

- **Physical sky, computed once.** `prepare` marches single scattering
  through Rayleigh, Mie and ozone into a 128x129 sky-view LUT (`colortex5`);
  `prepare1` integrates the sky's own irradiance from it. Every program reads
  sky radiance, sun and moon light and ambient light from that LUT with one
  fetch, so the sky, the haze, the ambient light, water and reflections all
  agree (`lib/atmosphere.glsl`).
- **Forward lighting, thin deferred stage.** Terrain, entities, textured
  geometry, water, clouds, weather and the sky are lit in their own gbuffers
  programs with one GGX BRDF (`lib/brdf.glsl`, `lib/lighting.glsl`). Opaque
  programs also write a small G-buffer (`colortex1`, RGBA8: octahedral
  normal, smoothness, sky light, metal flag) that one `deferred` pass reads
  for screen-space reflections, blurred by roughness from the scene's mip
  chain, and for the cloud layer on open sky. It then copies the opaque scene
  to `colortex6` for water refraction.
- **Materials without a resource pack.** `block.properties` IDs give each
  block group a smoothness, F0, metalness, emission, foliage translucency and
  porosity (`lib/materials.glsl`). Rain darkens porous surfaces, glazes hard
  ones and leaves puddles on hard ground; soil and turf soak it up.
- **Water as a medium.** Per-channel Beer-Lambert absorption over the real
  column depth, in-scatter lit by the LUT, Snell refraction of the opaque
  copy, Fresnel, SSR and a GGX glint; Snell's window from below
  (`lib/water.glsl`).
- **One scene target.** `colortex0` is linear `RGBA16F`. `composite` meters
  the frame into a 1x1 exposure history (`colortex4`); `final` applies eye
  adaptation, the Purkinje shift, the film curve and the one sRGB transfer,
  plus the optional lens flare, god rays, bloom and sharpening
  (`lib/sun_effects.glsl`, `lib/post.glsl`).
- **Solid terrain without `discard`.** Opaque blocks draw through
  `gbuffers_terrain_solid`, which has no alpha test, so Apple's tile GPUs can
  skip shading hidden fragments. Cutout blocks keep `gbuffers_terrain`.
- **Optional shadow map.** One Iris shadow map, directional sun only. Receivers
  sample `shadowtex0` with hardware depth comparison, so one fetch is already a
  bilinear four-sample PCF. Tiers cost 1, 2 or 4 fetches (`Maximum shadow
  filter` 1, 2, 3; tier 3 may adapt down to two or one fetch with Adaptive
  shadow filtering). Potato turns the map off and also empties the caster pass.
- **Frame-constant hoisting.** Sun and moon directions and their light are
  computed once per vertex and cross to the fragment stage as `flat`
  varyings (`lib/look.glsl`). Terrain, entity and textured fog is computed
  per vertex.
- **Look Contract.** `docs/LOOK-CONTRACT.md` and `shaders/lib/look.glsl` define
  the shared visual quantities (sun, ambient, sky, haze, weather).

## Profiles

| Profile | Shadows | Sky / clouds | Water | Intent |
| --- | --- | --- | --- | --- |
| Potato | off | flat sky, plain clouds | vanilla | cheapest; MakeUp-Potato class |
| Low | 512 map, 64 blocks, 1 fetch | on | surface only | Intel / M1 8 GB integrated |
| Balanced | 1024 map, 96 blocks, 1 fetch | on | all effects | default; 2020 M1 Air at 1080p, 8 chunks |
| Cinematic | 1536 map, 128 blocks, 4 fetches | on | all effects | quality ceiling |
| Adaptive | 1024 map, 96 blocks, 1 or 4 fetches | on | all effects | Balanced allocation, filter budget follows frame time |

Map size and distance are reload-bound Iris options and never change at
runtime. Adaptive uses a CPU-side smoothed frame-time uniform (8-tick
degradation, 80-tick recovery) and changes only the shadow filter. Offline
GPU time at 1080p on the M1 (`tools/bench_gpu.py`, preview city scene):
Potato 6.8 ms, Low 8.0, Balanced 9.5, Cinematic 11.1; in-game numbers are
still to be confirmed (`docs/PHASE5.md`).

Phase 4 effects (`docs/PHASE4.md`), each an option: waving plants and leaves
and height fog with sun haze from Low up; rain wetness and puddles, a high
cirrus layer and a lens flare from Balanced up; god rays and bloom in
Cinematic only; sharpening off everywhere (Post screen). Ice is opaque except
in Cinematic. `Entity shadows` is Off below Balanced, Player only in Balanced
and Adaptive, All in Cinematic. Balanced targets 80+ FPS at 1080p on the M1 Air; raise
Minecraft's own FPS cap (`maxFps`) to see it.

## Installation

1. Install Minecraft Java 1.20.1 with Fabric and a compatible Iris release.
2. Zip the *contents* of this repository so `shaders/` is at the archive root,
   or copy this folder into `.minecraft/shaderpacks/`
   (`tools/install_shaderpack.py` builds that zip and installs it into the dev
   instance).
3. In Iris: Video Settings -> Shader Packs -> **Aurelia Shaders**.
4. Pick a profile, then reload shaders after changing any compile-time option.
5. Debug view (Debug screen) shows lighting, frame pacing, final-colour bypass,
   raw shadow map, shadow factor and adaptive shadow tier; set it back to Off
   for normal play.

## In-game checks

- Sunrise, noon, sunset, night, rain, caves, torch-lit interiors, foliage,
  entities, water (shore and underwater) and shadow-map edges.
- A busy area for two minutes after thermal warm-up.

## Developer tools

- `tools/validate_shaderpack.py` expands Iris includes and compiles and links
  every program pair with `glslangValidator`, under the defaults, every preset,
  every boolean toggled alone, every option value alone, the shadow-filter by
  adaptive grid and the experimental distant-rain curtain. It also checks that
  every option is reachable from a screen, labelled in `lang/en_us.lang`, set by
  every profile and actually tested by a shader, and that custom-uniform
  expressions are well formed. It cannot emulate Iris's runtime.
- `tools/preview.py` renders the pack's own GLSL offscreen for look work; see
  `docs/PREVIEW.md`. `tools/test_*.py` are its regression tests.

A change is not certified by these tools alone; visual claims need an in-game
check on a real Iris install.

## Attribution

All GLSL in this repository is original. MakeUp Ultra Fast was inspected only
as an architectural and performance reference; no MakeUp source was copied or
adapted.

Design history: `docs/PHASE1.md` (baseline), `docs/PHASE2A.md` (shadows),
`docs/PHASE2B-WATER-AUDIT.md` (water), `docs/PHASE3.md` (plan),
`docs/PHASE4.md` (speed and effects), `docs/PHASE5.md` (physically based
realism).

`tools/bench_gpu.py` times each stage on the GPU for A/B work.

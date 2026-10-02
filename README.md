# Aurelia Shaders

Aurelia is a lightweight, original Iris shaderpack for Minecraft Java 1.20.1,
built for Apple Silicon laptops. The goal is the Complementary Reimagined /
Photon look at MakeUp/Potato-class cost: forward lighting, a graded and
filmic image, an analytic sky and water, and nothing that needs history
buffers, extra render targets or compute.

## Pipeline

- **Forward only.** Terrain, entities, lit/unlit textured geometry, water,
  clouds, weather and the sky are lit in their own gbuffers programs. There is
  no deferred or composite pass and no G-buffer.
- **One scene target.** `colortex0` is a single linear `RGBA16F` buffer. Minecraft
  texture, biome, sky and fog colours are decoded to linear on entry
  (`lib/color.glsl`); the `final` pass is the only fullscreen pass and performs
  the one sRGB transfer, a fitted filmic curve, saturation and contrast.
- **Optional shadow map.** One Iris shadow map, directional sun only. Receivers
  sample `shadowtex0` with hardware depth comparison, so one fetch is already a
  bilinear four-sample PCF. Tiers cost 1, 1 or 4 fetches (`Maximum shadow
  filter` 1, 2, 3; tier 3 may adapt down to one fetch with Adaptive shadow
  filtering). Potato turns the map off and also empties the caster pass.
- **Frame-constant hoisting.** Sun and moon directions and the linear sky and fog
  colours depend only on uniforms, so they are computed once per vertex and
  cross to the fragment stage as `flat` varyings (`lib/look.glsl`).
- **Analytic sky, clouds and water.** The sky gradient, sun and moon discs,
  stars, soft clouds, water surface and underwater fog are all ALU only: no
  noise texture, no extra pass, no extra target. Water depth effects read
  `depthtex1` once.
- **Look Contract.** `docs/LOOK-CONTRACT.md` and `shaders/lib/look.glsl` define
  the shared visual quantities (sun, ambient, sky, fog curve, weather).

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
degradation, 80-tick recovery) and changes only the shadow filter. Performance
targets are unmeasured until confirmed on the M1 Air; see `docs/PHASE3.md`.

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
`docs/PHASE2B-WATER-AUDIT.md` (water), `docs/PHASE3.md` (plan).

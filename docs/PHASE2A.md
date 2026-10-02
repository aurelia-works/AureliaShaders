# Aurelia Shaders — Phase 2A

> Current state: the receiver no longer takes manual `step()` taps. It samples
> `shadowtex0` through hardware depth comparison (`shadowHardwareFiltering0`),
> so one fetch is already a bilinear 4-sample PCF; the profile table below is
> the current one. The design notes that follow otherwise still hold.

Phase 2A adds one optional Iris shadow map to the Phase 1 forward pipeline. It
is intentionally a directional-sun system only: no PBR, ray tracing, screen
space effects, extra colour buffers, water reflections, or volumetrics are
introduced here.

## Architecture

`shadow.vsh` and `shadow.fsh` use Iris 1.7.x's single legacy shadow program.
The caster pass writes depth for terrain, alpha-tested foliage/cutouts, entities,
and block entities (all three are switched off in `shaders.properties` when
shadows are off, so Potato's pass draws nothing). `shadowTranslucent=false` excludes water and other blended
geometry because Phase 2A does not yet have a correct translucent-shadow model.

Iris 1.7.x parses the `shadowDistance` directive before GLSL constant folding;
therefore the source assigns it directly from the numeric shader option rather
than wrapping that option in `float(...)`. The development validator enforces
this Iris-specific requirement.

Forward terrain, lit textures, and entities now carry one player-space position
from their vertex stage. The fragment stage projects it with `shadowModelView`
and `shadowProjection`, then samples `shadowtex0` (hardware-compared). This avoids a
depth-buffer reconstruction/sample and another fullscreen pass.

Only direct sunlight is attenuated. Aurelia's cool sky ambient and Minecraft
block light remain present in shadow, which preserves cave/foliage readability.
Rain additionally softens shadow contrast while the established weather dimmer
reduces direct light.

## Phase 2A lighting corrections

The first Phase 2A runtime pass exposed two Phase 1 presentation mistakes. The
receiver projection now uses Iris's `shadowLightPosition`, the exact source of
the shadow camera, while analytical daylight stays on `sunPosition` so the
night-time moon is not treated as warm sunlight. Those vectors are equivalent
during daytime, so direct-light and shadow directions remain aligned while the
sun moves through sunrise and sunset. The forward pass also now remaps the
perceptual lightmap coordinates before adding sunlight, uses a mostly neutral
sky fill, and applies rain only to the direct term. Fog starts farther out and
no longer replaces ordinary daytime terrain with a blue-green wash.

Gbuffer lighting stays linear in one Iris `RGBA16F` colortex. The target is
floating point so direct-light and emissive sums above 1.0 survive until the
final ACES-like grade; the format directive remains in the comment form Iris
parses. The final pass performs the only linear-to-sRGB display transfer.

Minecraft's texture atlas and biome tint arrive as sRGB-encoded color values.
They are decoded before forward lighting, while lightmap coordinates and
terrain AO remain scalar controls. Iris documents `fogColor` and `skyColor` as
non-linear sRGB uniforms, so both are decoded before linear fog/sky operations.
An explicit linear-black colortex clear prevents Iris's default sRGB fog clear
from entering the linear scene before the sky pass covers it.

## Profiles

| Profile | Map edge | Distance | Receiver filter (fetches) |
| --- | ---: | ---: | --- |
| Potato | disabled | — | — |
| Low | 512 | 64 blocks | 1 filtered |
| Balanced | 1024 | 96 blocks | 1 filtered |
| Cinematic | 1536 | 128 blocks | 4-fetch tent |
| Adaptive | 1024 fixed | 96 blocks | 1 or 4 from smoothed quality |

`Maximum shadow filter` 1 and 2 both take the single hardware-filtered fetch;
3 takes the four-fetch tent, or one fetch while Adaptive shadow filtering is
short of headroom.

The square depth allocations are approximately 0.26M, 1.05M, and 2.36M texels.
The 1536 Cinematic cap is deliberate: it is materially cheaper than a 2048 map
while still providing extra detail beyond Balanced.

Adaptive never changes map resolution or distance at runtime. Its smoothed
frame-time signal (8-tick degradation, 80-tick recovery) selects the four-fetch
tent only with sustained headroom above roughly 54 FPS (adaptive quality at or
above 0.82) and the single fetch otherwise. It only matters at filter tier 3.

## Artifact and performance choices

The receiver uses a small normal-slope depth bias (0.00035–0.00125 in shadow
screen depth), no normal-position offset, and a narrow map-edge fade. This is a
low-cost compromise against acne, peter-panning, and hard shadow-map boundary
artifacts. PCF sample locations are fixed rather than time-noised, which avoids
camera shimmer but leaves some normal shadow-map aliasing at long range.

At normal gameplay cost, Balanced adds one `shadowtex0` fetch per lit terrain,
entity, or lit-texture fragment plus the shadow caster pass; Cinematic and
Adaptive's top tier add four. The tier branch is uniform per frame, not per
pixel. The shadow-map caster pass and foliage overdraw remain the primary
expected GPU cost on Apple Silicon, especially in dense forests or moving
through newly visible chunks.

## Debug views

- **Raw shadow map** shows `shadowtex0` depth and is black when shadows are off.
- **Shadow factor** shows the direct-light visibility applied to eligible
  forward geometry as a true grayscale mask (white lit, black shadowed,
  intermediate values filtered). It bypasses Aurelia's colour grade.
- **Adaptive shadow quality** colours the adaptive tier: red lowest, amber middle,
  green top. Only the top tier takes four fetches (filter tier 3).

These are compile-time debug options; select the view then reload shaders.
The terrain pass uses Iris `separateAo` so its Shadow Factor output is not
contaminated by the biome/AO vertex-color packing.

Water followed in Phase 2B (`docs/PHASE2B-WATER-AUDIT.md`).

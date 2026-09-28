# Aurelia Shaders — Phase 3

Phase 3 moves the pack from the Phase 2 forward baseline toward a
"Complementary-Unbound-style" look while keeping the MakeUp-class cost profile
that the M1 MacBook Air target requires. The general architecture is unchanged:
forward-lit gbuffers, one HDR scene target (`colortex0`), a single directional
shadow map, and one `final` pass, with a small post chain added only where a
phase needs it.

Phase 0 of Phase 3 (P3.0) is foundation only. It makes **no visual change** and
adds no features.

## Phase order and gates

| Phase | Scope | Benchmark gate after |
| --- | --- | --- |
| P3.0A | Commit the existing dirty palette baseline | — |
| P3.0B | Aurelia Look Contract + docs + behaviour-neutral shared constants | — |
| P3.0C | Preview multi-target tooling + options/preset/lang scaffolding | — |
| D-LOD | Record-only: does the LOD's `BEFORE_ENTITIES` draw pass through Iris `final`? | — |
| P3.1 | Atmosphere / sky | — |
| P3.2 | Lighting / grade (locks the look) | **G1** |
| P3.3 | Water (animation, waves, depth effects) | **G1W** (water-heavy scene) |
| P3.4 | Vegetation motion (grass/leaves/crops/foliage only; **no water**) | — |
| P3.5A | Procedural clouds only | **G2** |
| P3.5B | Bloom only | **G3** |
| P3.6 | Optional polish (FXAA / light shafts) | measure before enabling |
| P3.7 | Aurelia LOD visual integration (after P3.2 locks the look) | seam check |

Clouds and bloom are split into separate phases and separate benchmark gates so
no single performance test mixes two architecture changes.

## Authority

`OlympiaBench` on the 2020 M1 MacBook Air (8 GB) — 1080p, 8 chunks — is the
authoritative measurement. Every millisecond figure in Phase 3 planning is a
hypothesis until measured. Balanced targets p50 >= 60 FPS with 1% low >= 50 FPS
(to be confirmed, not promised).

## Scope exclusions

PBR/labPBR (vanilla textures only), TAA (no motion vectors), true screen-space
reflections, 3D volumetrics, and true scene-colour refraction from `depthtex0`
alone. `depthtex0` is used only for thickness, shoreline softening, depth
absorption, and underwater fog. Water animation belongs exclusively to P3.3.

## The Look Contract

`docs/LOOK-CONTRACT.md` and `shaders/lib/look.glsl` define the visual quantities
shared by the pack and, later, Aurelia LOD: sun direction/height/visibility/
colour, ambient tint, zenith and horizon colours, the fog curve, weather
attenuation, and the exposure baseline. GLSL is the source of truth; the LOD
mirrors it in Java in P3.7.

## Tooling

- `tools/validate_shaderpack.py` — expands Iris includes and validates every
  `*.vsh`/`*.fsh` pair and preset.
- `tools/preview.py` — offline grading/preview. P3.0C extends it to multi-target.
- In-game Iris 1.20.1 check on a real Overworld — required for any visual claim.

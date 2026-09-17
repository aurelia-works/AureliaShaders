# Aurelia Shaders

Aurelia is a lightweight, original Iris shaderpack for Minecraft Java 1.20.1.
Phase 2A keeps the Phase 1 forward-rendering baseline for Apple Silicon laptops
and adds optional directional sun shadows: textured terrain and entities,
vanilla sky/sun/moon handling, distance fog, one filmic final pass, and a
single compact Iris shadow map.

The scene buffer is kept linear in `RGBA16F` and receives one explicit sRGB
transfer in the final pass. Minecraft texture/biome colors are decoded before
lighting; terrain AO remains a scalar modulation. Analytical daylight uses Iris's
`sunPosition`; shadow receivers use `shadowLightPosition`, the same celestial
direction used by the shadow pass (these vectors match during daytime). Neutral
sky fill and a reduced-distance fog preserve readable daytime terrain.
Shadow-factor debug is an ungraded grayscale mask.

## Performance contract

The default **Balanced** profile is designed as a sensible starting point for a
2020 M1 MacBook Air at 1920x1080 and eight chunks. It targets stable gameplay
frame pacing rather than a benchmark number. Actual performance depends heavily
on mods, world complexity, thermal state, and the Iris/Fabric version.

Balanced uses a 1024 shadow map covering 96 blocks and four manual PCF depth
comparisons on lit fragments. Adaptive keeps that allocation fixed and changes
only its 1/4/9-tap receiver budget from the smoothed frame-time signal. Potato
disables shadows. There is still no PBR, screen-space reflection, volumetrics,
bloom, temporal history, compute shader, or additional colour render target.

## Installation

1. Install Minecraft Java 1.20.1 with Fabric and a compatible Iris release.
2. Zip the *contents* of this repository so `shaders/` is at the archive root,
   or copy this folder directly into `.minecraft/shaderpacks/`.
3. In Iris: Video Settings -> Shader Packs -> select **Aurelia Shaders**.
4. Start with the Balanced profile, 1920x1080, and eight chunks. Reload shaders
   after changing a compile-time option or profile.
5. For diagnosis, set Debug view to Lighting, Frame pacing, Raw shadow map,
   Shadow factor, Adaptive shadow quality, or Final colour;
   return it to Off for normal play.

## Phase 2A validation checklist

- Load a new and an existing Overworld world; confirm terrain, entities,
  cutout foliage, water, sun, and moon render.
- Check sunrise, noon, sunset, rain, caves, torch-lit interiors, foliage,
  entities, and movement through shadow-map boundaries.
- Walk through a busy area for at least two minutes after thermal warm-up.
- Use Debug view -> Frame pacing to inspect the CPU-side smoothed frame-time
  signal and adaptive scalar. Adaptive shadow filtering is the only Phase 2A
  runtime quality consumer; map allocation and distance require a reload.

## Attribution

All GLSL in this repository is original. MakeUp Ultra Fast was inspected only
as an architectural and performance reference; no MakeUp source was copied or
adapted, so this pack contains no reused MakeUp code.

See `docs/PHASE1.md` for the original baseline and `docs/PHASE2A.md` for the
shadow design, budget, limitations, and Phase 2B boundary.

## Developer validation

`tools/validate_shaderpack.py` expands Iris includes, then uses
`glslangValidator` to compile and link each program pair. It validates GLSL
syntax and stage interfaces but is not a substitute for an Iris in-game test.

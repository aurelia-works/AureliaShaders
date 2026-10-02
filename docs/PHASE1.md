# Phase 1 architecture

`gbuffers_terrain` and `gbuffers_entities` are forward passes. They retain the
Minecraft atlas and biome tint, replace the vanilla lightmap multiplication
with a compact lighting model, and write directly to the normal scene colour
buffer. `gbuffers_textured_lit` gives the same treatment to fallback geometry
such as the hand and lit particles; unlit special geometry retains its vanilla
appearance through `gbuffers_textured`. Missing gbuffers programs use Iris
fallbacks.

The lighting model uses the transformed world-space normal, the sun direction,
Minecraft sky/block light levels, rain, and the supplied fog colour. It is
intentionally analytical: it has no shadow lookup and no G-buffer. This means
it is cheap and stable on tile-based Apple GPUs, but direct sunlight is not
occluded yet. Vanilla ambient occlusion remains available through Iris.

`final` is the only fullscreen pass. It applies a compact ACES-like curve,
controlled saturation, a cool shadow/warm highlight split, and a tiny blue-noise
free ordered dither. It performs exactly one `colortex0` read and no history or
blur passes.

`shaders.properties` defines the Iris option screens, five presets, and custom
uniforms. Iris evaluates `aureliaSmoothedFrameTime` on the CPU from the prior
frame's `frameTime`: degradation responds over 8 ticks; recovery responds over
80 ticks. This asymmetric smoothing is the hysteresis mechanism. The derived
`aureliaAdaptiveQuality` grows gradually from 0.70 to 1.0 above 50 FPS, holds
at 0.70 through 38-50 FPS, ramps down to 0.20 between 38-30 FPS, and reaches
0.0 below 30 FPS.

The controller's only runtime consumer is the shadow filter budget (Phase 2A);
the debug view shows the raw signal. Further consumers must be runtime-safe
secondary workloads, such as cloud ray steps, reflection taps, or fog samples.
Shadow-map resolution is a compile-time resource allocation and will remain a
preset/reload setting in Phase 2 rather than being falsely changed per frame.

This file records the Phase 1 baseline; shadows, water, sky and clouds landed
afterwards (see `README.md` for the current pipeline).

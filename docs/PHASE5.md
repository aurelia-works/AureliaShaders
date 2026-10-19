# Aurelia Shaders — Phase 5: physically based realism

Goal: the most realistic image an M1 MacBook Air (8 GB) can carry while it
also runs Aurelia Metropolis, a CPU-bound Fabric modpack. Physical sky,
water and materials; no temporal history, no compute, no 3D textures.
Balanced may spend about 2 ms more GPU time than Phase 4 at 1080p and no
more, because the modpack, not the GPU, sets the frame rate.

## What the realistic packs do

Nine packs were inventoried with REA (archive containment checked; ledger
with SHA-256 and evidence IDs kept with the session) and read for technique
only. No code was copied. Everything below is standard published graphics:
the precomputed sky-view LUT (Bruneton, Hillaire), split-sum environment
BRDF (Karis), Hammon's Smith visibility, Beer-Lambert absorption.

Files whose source matches each technique:

| Pack | sky-view LUT | Purkinje | SSR | mip reads | water absorption | TAA / temporal | voxel / floodfill |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Photon | 13 | 15 | 23 | 2 | 20 | 79 | 35 |
| Complementary Reimagined | 0 | 0 | 4 | 5 | 0 | 37 | 26 |
| Bliss | 0 | 7 | 11 | 3 | 1 | 44 | 15 |
| BSL | 0 | 0 | 3 | 6 | 0 | 36 | 22 |
| Kappa | 1 | 3 | 8 | 5 | 0 | 56 | 0 |
| Nostalgia | 0 | 2 | 8 | 5 | 3 | 49 | 1 |
| Solas | 0 | 0 | 7 | 4 | 4 | 28 | 16 |
| Rethinking Voxels | 0 | 0 | 0 | 4 | 0 | 34 | 32 |
| MakeUp Ultra Fast | 0 | 0 | 14 | 2 | 15 | 35 | 0 |

What we took: Photon's physical sky and Purkinje night vision; Complementary's
idea of material realism without a resource pack, keyed on block IDs; the
mip chain as the cheap blur every pack uses. What we left out on purpose:
every pack leans on temporal accumulation, and most on voxel or flood-fill
light. Both need history buffers or 3D textures and memory the 8 GB Air does
not have to spare under a modpack.

## What changed

| System | Phase 5 |
| --- | --- |
| Sky | `prepare` marches single scattering (Rayleigh, Mie, ozone, a multiple-scattering term) into a 128x129 sky-view LUT; row 128 holds the sun, moon and cloud light. `prepare1` integrates sky irradiance (up, down, toward and away from the sun) from the LUT itself: 48 cosine-weighted samples and a lit ground. Fast-acos azimuth and a sine-warped elevation axis keep the horizon sharp. |
| Light | One GGX BRDF for forward light, SSR and water (`lib/brdf.glsl`). Sun, moon and ambient come from the LUT in physical ratios, so dawn, dusk and night need no palettes. |
| Exposure | `composite` meters the frame (96 taps) into a 1x1 history; `final` adapts between EV -6.4 and the bright limit. Purkinje shift at night. |
| Materials | `lib/materials.glsl`: smoothness, F0, metal, emission, translucency, porosity and drainage per block group: glass, stained glass, ice, slime/honey, portal, lamps, lava, flames, metal, polished stone, concrete, glazed terracotta, obsidian, soil, turf. |
| Rain | Porous surfaces darken; hard surfaces get a glossy film; puddles (mirror, raindrop rings) form only on hard up-facing ground. Soil, sand and turf soak the water up. |
| Reflections | `deferred` traces SSR on smooth opaque pixels against a G-buffer (`colortex1`) and reads the hit from colortex0's mip chain at the width the GGX lobe spreads to, so a puddle mirrors and a wet road smears. Thickness grows with the ray's per-step depth change, which removed stripes on vertical metal. |
| Water | A participating medium: per-channel Beer-Lambert over the view path plus the bed's depth, in-scatter lit by the LUT, biome tint as extra absorption, Snell refraction of the opaque copy (`colortex2`), Fresnel 0.02, SSR, GGX glint, shore foam. From below: Snell's window and per-channel path attenuation. |
| Glass | Premultiplied tinted body plus a Fresnel reflection that alpha does not scale (`alpha = mix(texAlpha, 1, F)`). |
| Haze | Beer-Lambert aerial perspective with an exponential height profile; in-scatter is the LUT horizon at the fragment's own angle from the sun (`docs/LOOK-CONTRACT.md`). |
| Clouds | The painted cloud layer and cirrus moved from the sky pass to `deferred`, so only visible sky pays for them, and they appear in water reflections. |
| Effects | Lens flare and god rays scale with the LUT's sun light and are added before exposure. |

## Look review fixes (preview city, Balanced)

- **Rain turned everything into a mirror.** Every wet surface was raised to
  smoothness 0.72 (SSR weight 0.95) and SSR read a single sharp texel; grass
  blocks mirrored tree trunks. Now the hard-surface film is 0.66 and SSR
  reads a roughness-matched mip, while soil and turf (new IDs 10036, 10037)
  stay matte and hold no puddles.
- **Golden-hour wash-out.** The haze took its colour from the horizon at the
  fragment's azimuth, so a roof below a low sun sampled the aureole's peak
  (Mie phase ~36x isotropic at 2 degrees against ~5x at its true 25 degrees).
  The haze now keeps the fragment's true scattering angle.
- **Untinted sea floor from below.** With the camera under water, only the
  view path was fogged, so a shallow sunlit floor showed cream sand at
  (205, 198, 176). Water dims sky light by one level per block, so the level
  now gives the depth: the sun and moon are attenuated per channel along
  their slant path down, and the sky fill takes the column's colour.

## Results (offline, M1, 1920x1080, GPU ms, median of 30 frames)

`tools/bench_gpu.py --all-profiles`. Totals drift about ±0.7 ms with the
fanless Air's temperature; compare stage columns rather than totals.

| Profile | Island | City |
| --- | --- | --- |
| Potato | 6.0 | 6.8 |
| Low | 7.0 | 8.0 |
| Balanced | 8.8 | 9.5 |
| Cinematic | 9.8 | 11.1 |
| Adaptive | 9.1 | 10.2 |

The Phase 4 Balanced baseline was 6.7 (island) and 7.6 (city): Phase 5 costs
about 2 ms. In the city, the shadow map and SSR are about 1.1 ms each and
the cloud layer 0.6 ms. The sky LUT plus irradiance costs under 0.3 ms. In
rain, more pixels are glossy and `deferred` rises from 2.0 to about 3.0 ms.
The roughness mip chain measured no cost (rain, deferred 3.0-3.1 ms with it,
3.2-3.4 without).

## Not verified (before the in-game run below)

Everything above is the offline preview, which emulates Iris but is not
Iris. Still to check in game: frame rate under Aurelia Metropolis, Iris's
handling of `colortex0MipmapEnabled` in `deferred`, modded blocks that have
no ID (they shade as rough stone), and the Nether and End with the new
passes.

## In-game checklist

1. Prism instance **ClaudeShader**, pack `AureliaShaders-Phase5.zip` (already
   selected), Balanced profile.
2. Noon street and canal: SSR on polished stone and water, teal water with a
   visible bed in the shallows.
3. Sunset looking at the sun from a roof: warm haze, roofs still readable.
4. Rain on a road and a lawn: soft road reflections, puddles that mirror,
   a darker lawn with no reflections.
5. Night: dark but readable, stars, lamp light, blue-shifted shadows.
6. Swim under water and look up: Snell's window, no seams.
7. F3 frame time in a busy district for two minutes after warm-up.

## In-game results (2026-10-19, ClaudeShader, Iris 1.7.6, M1, 1080p, RD 8)

Pass after fixes: noon town and lake, sunset, rain, night, underwater, Nether,
End. `colortex0MipmapEnabled` works in `deferred` (SSR on water at sunset).
Not covered: SSR on polished stone (the test world has no stone city).

Fixes the run found:
- Atlas tiles on water and sky: gbuffers read colortex2/3, which Iris does
  not bind outside fullscreen passes. Moved to colortex6/5 (validator guard).
- The End was lit like Overworld noon: `aureliaNoSky()` (`hasCeiling ||
  !hasSkylight`) now gates sun, sky light, flare and god rays.
- Nether lava tonemapped to cream: the no-sky exposure floor was EV -6.4
  (17.6x gain). It is now EV -4.0, with Nether/End ambient and fog x5.28.
- Rain: water and glass sun glints fade with (1 - rain)^2.
- Potato: `program.deferred.enabled = false` when SSR, the cloud layer and
  refraction are all off (the pass had nothing to do).

Frame rate, town view (105 78 100), noon, clear, F3 samples after warm-up:

| Setup | fps |
|---|---|
| Vanilla, shaders off | 180-193 |
| Aurelia Potato | 67-79 |
| Aurelia Low | 45-62 |
| Aurelia Balanced | 39-46 |
| Complementary Reimagined, Jah's low settings | 39-40 |

No single Balanced feature costs more than ~8 fps here (shadows ~52, SSR off
~50); with every feature off the pack runs 73-75.

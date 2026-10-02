# Aurelia Look Contract v1

Status: **frozen definition, v1.** Introduced by P3.0B. This document and
`shaders/lib/look.glsl` are the single source of truth for the visual quantities
shared by Aurelia Shaders and, later, Aurelia LOD.

This is a **contracts/deduplication** boundary, not a visual redesign. Every
value and expression moved into `look.glsl` is behaviour-identical to the code
it replaced. P3.0B changed no rendered pixel (verified: the offline preview is
byte-identical — see the P3.0B report). Tuning begins in P3.1.

## Binding rules

1. **Directions are world/player-space unit vectors.** Player space is
   camera-relative and unrotated (`docs/PHASE2A.md`). Iris celestial uniforms
   (`sunPosition`, `moonPosition`, `shadowLightPosition`) are **view space**,
   length 100, so each is rotated by `mat3(gbufferModelViewInverse)` exactly
   once, inside `look.glsl`. No view-space component (`.y`) may be read directly
   as if it were world space.
2. **Colours are linear RGB.** sRGB decode happens only where a value first
   enters the pipeline (`lib/color.glsl`). `look.glsl` never re-encodes.
3. **GLSL is the source of truth.** `shaders.properties` cannot consume GLSL
   definitions. Iris options that also shape the look are therefore duplicated
   between `lib/options.glsl`/`shaders.properties` and this contract by
   necessity; the sync rule is in "Duplicated by necessity" below.
4. **Aurelia LOD mirrors this contract in Java, in P3.7.** Nothing here is read
   by the LOD yet. The D-LOD diagnostic (record-only) settles whether the LOD
   draws pass through Iris's `final` tonemap before that work is scoped.

## Fields

| Field | Definition location | Value / formula (v1) | Status |
| --- | --- | --- | --- |
| `sunDirection` | `aureliaSunDirection()` | `normalize(mat3(gbufferModelViewInverse) * sunPosition)` | final |
| `moonDirection` | `aureliaMoonDirection()` | `normalize(mat3(gbufferModelViewInverse) * moonPosition)` | final; the night disc comes from `moonPosition`, never the shadow source |
| `sunHeight` | `aureliaSunHeight()` | `aureliaSunDirection().y` | final |
| `sunUp` | `aureliaSunVisibility()` | `smoothstep(-0.10, 0.08, sunHeight)` | final |
| `nightFactor` | `aureliaNightFactor()` | `1 - smoothstep(-0.15, 0.05, sunHeight)` | defined; still unconsumed (the atmosphere drives dusk from `horizonFactor`); reserved for a later phase |
| horizon factor | `aureliaHorizonFactor(height)` | `1 - smoothstep(0.05, 0.48, max(height,0))` | final; band widened in P4 so dawn/golden hour (up to ~28° sun elevation) keep warmth |
| `sunColor` | `aureliaSunColor(height)` | `mix(noon(1.00,0.97,0.91), sunset(1.00,0.57,0.31), horizonFactor)` | final |
| ambient tint | `aureliaAmbientTint(skyLight)` | `mix(neutral(0.50), sky(0.43,0.50,0.62), 0.18 + 0.08*skyLight)` | final |
| ambient sky scale | `AURELIA_AMBIENT_SKY_SCALE` | `0.44` | final; consumed by the ambient composition in `lib/lighting.glsl`, not by `aureliaAmbientTint` itself |
| `zenithColor` | `aureliaZenithColor(skyColorLinear)` | `skyColorLinear * 0.74 + (0.010, 0.020, 0.040)` | base of the P3.1 atmosphere gradient and the no-atmosphere fallback; still a tuning surface |
| `horizonColor` | `aureliaHorizonColor(fogColorLinear)` | identity — the linear form of `fogColor`, the fog's far-distance limit | final |
| fog curve | `aureliaFogFactor(dist, density, rain)` | see below | final |
| weather attenuation | constants below | linear coefficients on `rainStrength` | final |
| exposure | `AURELIA_EXPOSURE` option; contract baseline `AURELIA_EXPOSURE_BASELINE` | pre-tonemap multiply; baseline `1.00` | applied in `tonemap.glsl` from P3.2 |

### Fog curve

```
fog(d, density, rain) =
    clamp( (1 - exp(-d * 0.0045 * density)) * (0.80 + 0.20 * rain), 0, 0.78 )
```

Constants: `AURELIA_FOG_DENSITY_K = 0.0045`, `AURELIA_FOG_RAIN_MIN = 0.80`,
`AURELIA_FOG_RAIN_RANGE = 0.20`, `AURELIA_FOG_MAX = 0.78`. `density` is passed
in by the caller (`AURELIA_FOG_DENSITY`, an Iris option), so `look.glsl` has no
compile-time dependency on `options.glsl`. Reference values at `density = 1`,
dry (`rain = 0`, multiplier `0.80`): `fog(10) ≈ 0.035`, `fog(30) ≈ 0.101`,
`fog(60) ≈ 0.189`, `fog(100) ≈ 0.290`, `fog(128) ≈ 0.350`. Near-field stays
crisp (under 5% inside ~15 blocks), mid-distance gains subtle atmosphere, and
the RD8 far edge reads ~35% toward the horizon with terrain form intact. The
cap is never approached at normal render distances (it binds past ~820 blocks
dry at `density = 1`); it exists for far-plane/LOD geometry. Tuned in P4
(ATMOSPHERE segment): `K` `0.0031 → 0.0045`, single-constant change, no curve,
target, or signature change.

### Weather attenuation constants

| Constant | Value | Applied to |
| --- | --- | --- |
| `AURELIA_RAIN_SUN_DIM` | `0.38` | direct sun and its water glint (`1 - k*rain`) |
| `AURELIA_RAIN_SKY_FLATTEN` | `0.45` | sky ramp blend toward the horizon colour |
| `AURELIA_RAIN_GLOW_DIM` | `0.55` | solar glow dimming |
| `AURELIA_RAIN_SHADOW_SOFTEN` | `0.35` | shadow-strength reduction |

The constants above are unchanged. The pack's remaining weather behavior —
the celestial-body slopes in `lib/sky.glsl`, reproduced here so the LOD
mirror (which draws no bodies) does not accidentally reintroduce them as
glow — is:

- sun disc (`aureliaApplySunDisc`): `disc *= (1 - rain)` — full overcast
  hides the disc; the aureole keeps the `AURELIA_RAIN_GLOW_DIM` dimming only.
- moon disc + aureole (`aureliaApplyMoon`): `*= (1 - rain)`.
- stars (`aureliaApplyStars`): `*= (1 - rain)`, gated by
  `darkness = 1 - smoothstep(-0.28, -0.10, sunHeight)` (ordered edges;
  the reversed-edge form is undefined behavior per the GLSL specification).

## Test vectors

Fixed vectors for validating the LOD mirror in P3.7 and guarding regressions
here. Values not finalised until P3.1 are labelled **provisional**.

| # | Conditions | Assertions |
| --- | --- | --- |
| V1 | Overworld clear noon | `sunHeight ≈ 1`, `sunUp = 1`, `nightFactor = 0`, `sunColor ≈ noon`, `aureliaFogFactor(64,…)` as specified |
| V2 | Overworld clear, sun near horizon | `horizonFactor` near 1, `sunColor ≈ sunset`, fog(64) as specified |
| V3 | Overworld clear midnight | `sunUp = 0`, `nightFactor = 1`, night palette from the P3.1 atmosphere (still a tuning surface) |
| V4 | Overworld noon, `rainStrength = 1` | all four weather coefficients applied as specified |
| V5 | Nether / End | dimension palette selection — **provisional**; scope is fixed in P3.1, not v1 |

## Duplicated by necessity (sync rule)

`shaders.properties` and `lib/options.glsl` hold Iris options that feed the
contract. These are **not** duplicated *math*, but they do shape the look and
must stay consistent with `look.glsl` when either side changes:

- `AURELIA_NIGHT_LIFT`, `AURELIA_DIRECT_LIGHT` — used by the forward-light
  composition in `lib/lighting.glsl` (not by `look.glsl` itself).
- `AURELIA_FOG_DENSITY` — the `density` argument to `aureliaFogFactor`.
- `AURELIA_SKY_SATURATION` — applied in `lib/tonemap.glsl`, after the contract's
  linear stage.

Do **not** invent a fake single source of truth for these: Iris must read them
from `shaders.properties`, so the GLSL constants and the Iris options are
separate by design. The sync requirement is documentation, not code.

## Aurelia LOD Look Contract: fogging distant geometry

When Aurelia LOD integrates, its renderer reproduces the pack's atmosphere
analytically from the quantities below — no sampling of this pack's buffers.
All steps run in **linear RGB**; sRGB decode of the Iris inputs happens first
(the pack does this in `lib/color.glsl`, `aureliaSrgbToLinear`).

1. **Distance metric.** `d = length(fragmentWorldPos - cameraWorldPos)`, the
   Euclidean camera distance in blocks. The pack evaluates
   `length(viewPosition)` where `viewPosition` is already camera-relative, so
   this is identical.
2. **Fog factor** (`aureliaFogFactor`, `lib/look.glsl`):
   `f = clamp((1 - exp(-d * 0.0045 * density)) * (0.80 + 0.20 * rain), 0, 0.78)`.
   `rain` is Iris `rainStrength` in `[0, 1]`. `density` mirrors the user's
   `AURELIA_FOG_DENSITY` Iris option (profile defaults: POTATO `0.85`, LOW
   `0.90`, BALANCED/ADAPTIVE `1.00`, CINEMATIC `1.20`); the LOD default is
   `1.00`.
3. **Fog color** (`aureliaFogColor`, `lib/sky.glsl`): the analytic sky dome
   palette evaluated **along the fragment direction**
   `dir = normalize(fragmentWorldPos - cameraWorldPos)` (player/world space),
   **minus the solar aureole** (no sun disc, no glow lobes — those live within
   a couple of degrees of the disc, where fogged geometry rarely sits):
   - Day/night blend: `day = smoothstep(-0.10, 0.08, sunHeight)`, where
     `sunHeight` is the world-space sun direction's `.y`
     (`normalize(mat3(gbufferModelViewInverse) * sunPosition).y`).
   - `zenith = mix((0.011, 0.019, 0.045), (0.070, 0.160, 0.430), day)`,
     then `zenith = mix(zenith, skyColorLinear * 0.55, 0.20 * day)`.
   - `horizon = mix((0.030, 0.047, 0.088), fogColorLinear, day)`.
   - Golden-hour bell: `golden = smoothstep(-0.12, 0.02, sunH) *
     (1 - smoothstep(0.06, 0.30, sunH))`, `sunH = max(sunHeight, 0)`.
     Azimuth gate: `nearSun = smoothstep(0.05, 0.85, azimuthAlign)` where
     `azimuthAlign` is the cosine between the `xz` projections of `dir` and
     the sun direction (0 when either projection is degenerate).
     `horizon = mix(horizon, (0.30, 0.42, 0.62), 0.45 * golden)`, then
     `horizon = mix(horizon, sunColor(sunH) * 0.90, 0.80 * golden * nearSun)`
     with `sunColor(h) = mix((1.00, 0.97, 0.91), (1.00, 0.57, 0.31),
     1 - smoothstep(0.05, 0.48, h))`.
   - `ramp = smoothstep(-0.28, 0.62, dir.y)`;
     `sky = mix(horizon, zenith, ramp)`.
   - Overcast: `overcast = mix((0.34, 0.38, 0.44), (0.16, 0.20, 0.27), ramp)`,
     then `overcast *= mix(0.14, 1.0, day)` — the overcast pair is a daylight
     palette, so it is dimmed by the same day/night blend as the dome; without
     this a rainy night renders far brighter than a clear night instead of
     staying navy;
     `fogColor = mix(sky, overcast, 0.45 * rain)`.
   `skyColorLinear` / `fogColorLinear` are the linear decodes of Iris's
   `skyColor` / `fogColor` uniforms; `lightDirection` is the world-space sun
   direction above. Night fog is the dome's navy, never black; rain fog is the
   same overcast the sky shows.
4. **Composite.** `out = mix(litLinear, fogColor, f)` in linear, before the
   pack's tonemap. Because the fog target equals the dome color behind the
   fragment at the horizon, distant terrain converges to the sky seam-free by
   construction.
5. **Cap behavior.** `f` clamps at `0.78`, so even far-plane geometry keeps
   ~22% of its own signal: atmosphere, never soup. Underwater uses a separate
   denser curve (`AURELIA_UNDERWATER_FOG_K = 0.070`, cap `0.86`, gated on
   `AURELIA_WATER_UNDERWATER` + `isEyeInWater == 1`); the LOD's above-water
   path ignores it.

## What intentionally stayed where it was

These expressions were left in place rather than moved, because moving them
would risk evaluation-order, precision, include-order, or preset behaviour:

- **`aureliaShadowDirection()` / `shadowLightPosition`** (`lib/lighting.glsl`).
  Not a visual catalogue field: `shadowLightPosition` is the highest celestial
  body — the moon at night — and is the exact shadow-camera source. Keeping it
  distinct from `sunPosition` is a correctness invariant, see `docs/PHASE2A.md`.
- **The shadow receiver and PCF** (`lib/shadows.glsl`). Includes `look.glsl` is
  deliberately avoided there (it is included by `lighting.glsl` immediately
  after `look.glsl`, so the constants are already in scope); a second include
  would re-declare `look.glsl`'s uniforms and helpers.
- **Fog application** (`aureliaApplyFogContract`, `lib/sky.glsl`): lives next
  to the dome palette it fades toward (direction-aware, with the underwater
  branch under `AURELIA_WATER_UNDERWATER`); only the distance/density curve
  (`aureliaFogFactor`) stays in `lib/look.glsl`. `lib/lighting.glsl` keeps the
  two-argument `aureliaApplyFog` wrapper for its callers.
- **The sky ramp shape, glow geometry and `lowSun` curve**
  (`gbuffers_skybasic.fsh`): P3.1 tuning surface, not contract.
- **Block-light and torch constants** (`lib/lighting.glsl`): presentation,
  P3.2 tuning surface.

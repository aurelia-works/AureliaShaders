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
| `sunHeight` | `aureliaSunHeight()` | `aureliaSunDirection().y` | final |
| `sunUp` | `aureliaSunVisibility()` | `smoothstep(-0.10, 0.08, sunHeight)` | final |
| `nightFactor` | `aureliaNightFactor()` | `1 - smoothstep(-0.15, 0.05, sunHeight)` | defined; not consumed by the P3.1 atmosphere (which drives dusk from `horizonFactor`); reserved for P3.2+ |
| horizon factor | `aureliaHorizonFactor(height)` | `1 - smoothstep(0.04, 0.34, max(height,0))` | final |
| `sunColor` | `aureliaSunColor(height)` | `mix(noon(1.00,0.97,0.91), sunset(1.00,0.57,0.31), horizonFactor)` | final |
| ambient tint | `aureliaAmbientTint(skyLight)` | `mix(neutral(0.50), sky(0.43,0.50,0.62), 0.18 + 0.08*skyLight)` | final |
| ambient sky scale | `AURELIA_AMBIENT_SKY_SCALE` | `0.60` | final |
| `zenithColor` | `aureliaZenithColor(skyColorLinear)` | `skyColorLinear * 0.82 + (0.010, 0.020, 0.040)` | base of the P3.1 atmosphere gradient and the no-atmosphere fallback; still a tuning surface |
| `horizonColor` | `aureliaHorizonColor(fogColorLinear)` | identity — the linear form of `fogColor`, the fog's far-distance limit | final |
| fog curve | `aureliaFogFactor(dist, density, rain)` | see below | final |
| weather attenuation | constants below | linear coefficients on `rainStrength` | final |
| exposure | `AURELIA_EXPOSURE` option; contract baseline `AURELIA_EXPOSURE_BASELINE` | pre-tonemap multiply; baseline `1.00` | applied in `tonemap.glsl` from P3.2 |

### Fog curve

```
fog(d, density, rain) =
    clamp( (1 - exp(-d * 0.0035 * density)) * (0.80 + 0.20 * rain), 0, 0.85 )
```

Constants: `AURELIA_FOG_DENSITY_K = 0.0035`, `AURELIA_FOG_RAIN_MIN = 0.80`,
`AURELIA_FOG_RAIN_RANGE = 0.20`, `AURELIA_FOG_MAX = 0.85`. `density` is passed
in by the caller (`AURELIA_FOG_DENSITY`, an Iris option), so `look.glsl` has no
compile-time dependency on `options.glsl`.

### Weather attenuation constants

| Constant | Value | Applied to |
| --- | --- | --- |
| `AURELIA_RAIN_SUN_DIM` | `0.38` | direct sun and its water glint (`1 - k*rain`) |
| `AURELIA_RAIN_SKY_FLATTEN` | `0.45` | sky ramp blend toward the horizon colour |
| `AURELIA_RAIN_GLOW_DIM` | `0.55` | solar glow dimming |
| `AURELIA_RAIN_SHADOW_SOFTEN` | `0.35` | shadow-strength reduction |

## Test vectors

Fixed vectors for validating the LOD mirror in P3.7 and guarding regressions
here. Values not finalised until P3.1 are labelled **provisional**.

| # | Conditions | Assertions |
| --- | --- | --- |
| V1 | Overworld clear noon | `sunHeight ≈ 1`, `sunUp = 1`, `nightFactor = 0`, `sunColor ≈ noon`, `aureliaFogFactor(64,…)` as specified |
| V2 | Overworld clear, sun near horizon | `horizonFactor` near 1, `sunColor ≈ sunset`, fog(64) as specified |
| V3 | Overworld clear midnight | `sunUp = 0`, `nightFactor = 1`, night palette (palette itself **provisional** until P3.1) |
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
- **`aureliaApplyFog`'s decode + mix** (`lib/lighting.glsl`): only the pure
  factor moved into the contract, because the decode depends on `color.glsl`
  and the caller owns `fogColor`'s space.
- **The sky ramp shape, glow geometry and `lowSun` curve**
  (`gbuffers_skybasic.fsh`): P3.1 tuning surface, not contract.
- **Block-light and torch constants** (`lib/lighting.glsl`): presentation,
  P3.2 tuning surface.

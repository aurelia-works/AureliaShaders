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
| horizon factor | `aureliaHorizonFactor(height)` | `1 - smoothstep(0.05, 0.48, max(height,0))` | final; band widened in P4 so dawn/golden hour (up to ~28° sun elevation) keep warmth |
| `sunColor` | `aureliaSunColor(height)` | `mix(noon(1.00,0.97,0.91), sunset(1.00,0.57,0.31), horizonFactor)` | final |
| ambient tint | `aureliaAmbientTint(skyLight)` | `mix(neutral(0.50), sky(0.43,0.50,0.62), 0.18 + 0.08*skyLight)` | final |
| ambient sky scale | `AURELIA_AMBIENT_SKY_SCALE` | `0.44` | final; consumed by the ambient composition in `lib/lighting.glsl`, not by `aureliaAmbientTint` itself |
| `zenithColor` | `aureliaZenithColor(skyColorLinear)` | `skyColorLinear * 0.74 + (0.010, 0.020, 0.040)` | base of the P3.1 atmosphere gradient and the no-atmosphere fallback; still a tuning surface |
| `horizonColor` | `aureliaHorizonColor(fogColorLinear)` | identity — the linear form of `fogColor`, the fog's far-distance limit | final |
| fog curve | `aureliaFogFactor(dist, density, rain)` | see below | final |
| weather attenuation | constants below | linear coefficients on `rainStrength` | final |
| exposure | `AURELIA_EXPOSURE` option (identity at `1.00`) | pre-tonemap multiply, applied in `tonemap.glsl` | final |

### Fog curve

Since Phase 5 the Overworld fades through physical haze (Beer-Lambert
extinction toward the sky LUT's horizon radiance; see "Aurelia LOD Look
Contract" below). The curve remains for the Nether, called with
`3 * density`:

```
fog(d, density, rain) =
    clamp( (1 - exp(-d * 0.0022 * density)) * (0.80 + 0.20 * rain), 0, 0.78 )
```

Constants: `AURELIA_FOG_DENSITY_K = 0.0022` (was `0.0045` until the in-game
tuning in `98a01d2`), `AURELIA_FOG_RAIN_MIN = 0.80`,
`AURELIA_FOG_RAIN_RANGE = 0.20`, `AURELIA_FOG_MAX = 0.78`, plus border fog
over the last 25% of render distance. `density` is passed in by the caller
(`AURELIA_FOG_DENSITY`, an Iris option), so `look.glsl` has no compile-time
dependency on `options.glsl`.

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
| V1 | Overworld clear noon | `sunHeight ≈ 1`, `sunUp = 1`, `sunColor ≈ noon`, `aureliaFogFactor(64,…)` as specified |
| V2 | Overworld clear, sun near horizon | `horizonFactor` near 1, `sunColor ≈ sunset`, fog(64) as specified |
| V3 | Overworld clear midnight | `sunUp = 0`, night palette from the P3.1 atmosphere (still a tuning surface) |
| V4 | Overworld noon, `rainStrength = 1` | all four weather coefficients applied as specified |
| V5 | Nether / End | dimension palette selection — **provisional**; scope is fixed in P3.1, not v1 |

## Duplicated by necessity (sync rule)

`shaders.properties` and `lib/options.glsl` hold Iris options that feed the
contract. These are **not** duplicated *math*, but they do shape the look and
must stay consistent with `look.glsl` when either side changes:

- `AURELIA_NIGHT_LIFT`, `AURELIA_DIRECT_LIGHT` — used by the forward-light
  composition in `lib/lighting.glsl` (not by `look.glsl` itself).
- `AURELIA_FOG_DENSITY` — the `density` argument to `aureliaFogTerms` (haze
  extinction) and `aureliaFogFactor` (Nether).
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
2. **Extinction** (Overworld, `aureliaFogTerms`, `lib/sky.glsl`). Since
   Phase 5 the haze is a Beer-Lambert medium, not a fog curve:
   `sigma = 0.0016 * density * (1 + 1.8 * rain)` per block
   (`AURELIA_HAZE_EXTINCTION`, `lib/look.glsl`; far denser than clean air, or
   a block world would show no depth within a render distance), and
   `T = exp(-sigma * d)`. `rain` is Iris `rainStrength` in `[0, 1]`.
   `density` mirrors the `AURELIA_FOG_DENSITY` option (profile defaults:
   POTATO `0.85`, LOW `0.90`, BALANCED/ADAPTIVE `1.00`, CINEMATIC `1.20`);
   the LOD default is `1.00`.
3. **Height** (`AURELIA_FOG_HAZE`, every profile but Potato). The haze
   thins exponentially above `y = 63` with a 90-block scale height, and the
   optical depth along the ray integrates that profile exactly:
   `h0 = cameraY - 63`, `k = (fragmentY - cameraY) / 90`,
   `base = exp(-max(h0, -40) / 90)`,
   `profile = |k| > 1e-3 ? base * (1 - exp(-k)) / k : base`, and
   `sigma *= clamp(profile, 0.08, 1.6)`.
4. **In-scatter colour.** The haze glows with the sky just above the
   horizon: the sky-view LUT radiance (`aureliaSkyRadianceAtAngle`,
   `lib/atmosphere.glsl`) at height `y = 0.04 + 0.5 * max(dir.y, 0)` and at
   the azimuth whose angle from the sun is the fragment's own,
   `cosAzimuth = (dot(dir, sun) - y * sun.y) / (sqrt(1 - y*y) * |sun.xz|)`.
   Keeping the true scattering angle matters at golden hour: flattening a
   fragment below a low sun onto the horizon at its own azimuth would put it
   in the Mie aureole's peak. The LUT is single scattering through Rayleigh,
   Mie and ozone (`lib/atmosphere.glsl`, a pure function of the sun
   direction and rain), so an LOD renderer reproduces it by evaluating the
   same model, not by sampling this pack's buffers.
5. **Composite.** With `border = smoothstep(0.78 * far, far, d)` and
   `behind` the LUT radiance along `dir` itself,
   `out = lit * T * (1 - border) + mix(haze * (1 - T), behind, border)`, in
   linear, before exposure and the film curve. The world's edge therefore
   resolves into the sky behind it, seam-free by construction.
6. **Other media.** The Nether keeps the curve form,
   `f = clamp((1 - exp(-d * 0.0022 * 3 * density)) * (0.80 + 0.20 * rain), 0, 0.78)`
   plus border fog over the last 25% of render distance (`aureliaFogFactor`),
   toward its own fog colour. Underwater
   (`AURELIA_WATER_UNDERWATER`, `isEyeInWater == 1`) uses a denser curve
   (`AURELIA_UNDERWATER_FOG_K = 0.070`, cap `0.86`) toward the water
   column's radiance (`lib/water.glsl`). The LOD's above-water path ignores
   both.

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
- **Fog application** (`aureliaFogTerms`, `lib/sky.glsl`): lives next to the
  sky it fades toward (direction-aware, with the underwater branch under
  `AURELIA_WATER_UNDERWATER`); the haze constants and the Nether curve
  (`aureliaFogFactor`) stay in `lib/look.glsl`. Terrain, entities and
  textured geometry evaluate it per vertex and apply it with
  `aureliaApplyFogTerms`; water, glass and SSR hits evaluate it per pixel.
- **The sky ramp shape, glow geometry and `lowSun` curve**
  (`gbuffers_skybasic.fsh`): P3.1 tuning surface, not contract.
- **Block-light and torch constants** (`lib/lighting.glsl`): presentation,
  P3.2 tuning surface.

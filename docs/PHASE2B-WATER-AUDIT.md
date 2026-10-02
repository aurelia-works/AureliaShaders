# Aurelia Shaders — Phase 2B water audit

Audit only. No water program is added by this document, and no shading decision
in it is final until Jah has seen it in game. The purpose is to establish what
water *is* today, which coordinate spaces a water program must use, and which
cheap techniques are architecturally available on the current pipeline.

Audited at `agent/shaders-sky-horizon-fix` @ `ab88a7d`.

## What water is today

There is no water program in this pack. Verified three ways: no
`gbuffers_water.*` on disk; the string `water` appears exactly once in the whole
shader source, in a comment in `shaders.properties`; and none of the three
release zips contain a water program.

Iris therefore resolves `gbuffers_water` through its documented fallback chain,
`gbuffers_water` -> `gbuffers_terrain`. So translucent terrain — including water
— is currently shaded by this pack's own `gbuffers_terrain.vsh`/`.fsh`.

Consequences, all of them current behaviour rather than defects:

- Water is decoded as terrain: `aureliaDecodeSrgbTerrain` treats the atlas
  sample as sRGB albedo and the biome tint as sRGB, with `vertexColor.a` used as
  terrain AO.
- Water receives shadows. `gbuffers_terrain.fsh` calls `aureliaForwardLight`,
  which calls `aureliaShadowVisibility`. This is the correct pairing with
  `shadowTranslucent = false` in `shaders.properties`, which keeps water out of
  the *caster* pass: water is shadowed by terrain, but never casts.
- Water has no translucency model of its own, no surface normal perturbation, no
  reflection term, and no view-dependent response. It is lit exactly like a
  horizontal opaque block.

The practical effect is that "water" today is the terrain shader applied to a
translucent surface. Adding `gbuffers_water` will *replace* this fallback, so the
fallback behaviour is the compatibility baseline that a new program must
reproduce before it improves on it.

## Pipeline ordering, and the one hard constraint

Iris documents that `gbuffers_water`, `gbuffers_weather`, and
`gbuffers_hand_water` are the programs that render *after* `deferred`. This pack
has no `deferred` program, so the order is: opaque gbuffers, then water.

That means at the moment water draws, `colortex0` already holds the rendered
opaque scene. It is tempting to read it back for a cheap refraction offset.

**That is not available.** A gbuffers program writes `colortex0`, and sampling a
texture that is currently bound as the render target is a feedback loop with
undefined results. Scene-colour refraction would require either a second colour
buffer or a composite pass. `docs/PHASE2A.md` excludes both from Phase 2B, so
refraction-by-scene-sample is out of scope and should not be designed around.

`depthtex1` is the pre-translucent opaque copy and stays readable during the
water pass, so depth-based effects — water thickness, depth-difference
opacity, shoreline softening — remain available at the cost of one depth read.
(`depthtex0` is live during translucents and may hold the water surface
itself; verified against the installed Iris 1.7.6 pipeline.)

## Coordinate space contract

The seven spaces a water program touches, with the source of truth in this pack.
The final column is the failure mode if the space is misread.

| Quantity | Required space | Current source | Failure if misread |
| --- | --- | --- | --- |
| World position | player space — camera-relative, unrotated | `playerPosition = (gbufferModelViewInverse * vec4(viewPosition, 1.0)).xyz` in the terrain/entities vertex stage | Feeding view space to `shadowModelView` offsets the shadow lookup by camera orientation |
| View position | view/eye space | `viewPosition = (gl_ModelViewMatrix * gl_Vertex).xyz` | Valid only for rotation-invariant uses such as `length()` for fog |
| Camera position | not currently used anywhere in this pack | none | Do not introduce the `cameraPosition` uniform for water until its space is confirmed against Iris docs; this pack has no precedent for it |
| Normals | world orientation, recovered from view space | `mat3(gbufferModelViewInverse) * (gl_NormalMatrix * gl_Normal)` | Reading a view-space component (`.y`) yields a camera-pitch dependency — the exact defect fixed in `ab88a7d` |
| Reflection direction | world/player space, both terms | must be built, not yet present | Mixing a world normal with `normalize(viewPosition)` rotates the reflection with camera yaw and pitch |
| Sky lookup | `skyColor` uniform, sRGB-encoded | `gbuffers_skybasic.fsh` decodes via `aureliaSrgbToLinear` | Treating `skyColor` as linear over-brightens the reflection; there is no sky render target to sample |
| Depth / fog | fog uses `length(viewPosition)`; floor depth via `depthtex1` (pre-translucent opaque copy; `depthtex0` is live during translucents) | `aureliaApplyFog` in `lib/lighting.glsl` | A second, water-specific fog model would diverge from terrain at the shoreline |

Iris confirms `sunPosition`, `moonPosition`, and `shadowLightPosition` are all
**view space** with length 100, and `gl_NormalMatrix` produces a **view space**
normal. `gbufferModelView` is documented as player space -> view space, and
`shadowModelView` as equal to the shadow program's `gl_ModelViewMatrix`, which is
why `shadowModelView` consumes player-space positions.

## Camera-pitch and camera-yaw dependency

The defect fixed in `ab88a7d` was one instance of a general class: an Iris
uniform that is supplied in view space was read as if it were world space.
Because view space is defined by the camera basis, such a read silently tracks
camera pitch or yaw instead of the world.

Two concrete instances to guard against in water:

1. **Celestial vectors.** `sunPosition`, `moonPosition`, and
   `shadowLightPosition` are view space. Any water term derived from their
   components must first pass through `mat3(gbufferModelViewInverse)`, exactly as
   `aureliaSunDirection()` and `aureliaShadowDirection()` already do in
   `lib/lighting.glsl`. A specular sun glint on water is the most likely place
   for this to reappear.
2. **Reflection and view vectors.** A reflection direction needs the world-space
   view vector, which is `normalize(playerPosition - cameraPlayerPosition)`, not
   `normalize(viewPosition)`. Combining a world-space normal with a view-space
   view vector produces a reflection that is correct at one camera orientation
   and wrong at every other.

Verification method for any water change: grep the new program for every
view-space uniform and confirm each read sits behind
`mat3(gbufferModelViewInverse)`, then confirm no `.y` is read from a view-space
vector. `gbuffers_skybasic.fsh:34` is the reference implementation of the fix.

## Precision and M1 notes

- The pack's established precision pattern is to interpolate a direction
  unnormalised and `normalize()` in the fragment stage. Water should follow it
  rather than normalising per vertex.
- `AURELIA_SHADOW_RESOLUTION` and the shadow texel size come from a compile-time
  option shared with `shadow.fsh`; a water program that receives shadows must
  reuse `aureliaShadowVisibility` rather than re-deriving the projection.
- Apple M1 is a tile-based GPU behind Iris's compatibility-to-core translation.
  Water should avoid adding dependent texture reads beyond the one atlas sample
  it already performs, and should not introduce a new render target.
- Rain already softens shadow contrast and dims direct light. Water should read
  `rainStrength` for surface response rather than adding a second weather path.

## Scope guard for Phase 2B

Excluded by `docs/PHASE2A.md` and by the M1 budget: SSR, ray tracing, PBR
material maps, multi-pass or cubemap reflections, and any additional colour
render target. An analytic treatment — procedural normal perturbation, Fresnel
from the world-space view/normal relationship, `skyColor` as the reflection
source, and `depthtex1` (pre-translucent opaque copy) for thickness — stays inside the current architecture
and the existing one-fullscreen-pass budget.

## Recommended implementation sequence

The fallback replacement and the new shading are two different risks and should
be two different changes.

1. Add `gbuffers_water.vsh`/`.fsh` that reproduces the `gbuffers_terrain`
   fallback exactly: same decode, same `aureliaForwardLight`, same
   `aureliaApplyFog`, same shadow receive. Validate and confirm in game that
   water is visually unchanged. This isolates the fallback-replacement risk.
2. Only then add the analytic water terms behind a compile-time option, so the
   change is revertible from the Iris options screen without a code edit.

## Open items

- `gbuffers_skybasic.fsh` derives its horizon haze from `shadowLightPosition`,
  which Iris documents as the *highest celestial body* — the moon at night. The
  rest of the pack deliberately keeps analytical daylight on `sunPosition` to
  avoid treating the moon as sunlight. Night-only and low amplitude, but the two
  files currently disagree about which light source governs a sky term.

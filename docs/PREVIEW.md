# Offline preview harness

`tools/preview.py` renders the pack's own GLSL offscreen, on the Mac's GPU,
with no Minecraft and no visible window. It exists so look decisions can be made
and checked without launching the game.

```
python3 -m venv tools/.venv
tools/.venv/bin/pip install -r tools/preview-requirements.txt

tools/.venv/bin/python tools/preview.py --profile BALANCED
tools/.venv/bin/python tools/preview.py --all-profiles --time 0.40
tools/.venv/bin/python tools/preview.py --time 0.50 --rain 0.8
tools/.venv/bin/python tools/preview.py --underwater
tools/.venv/bin/python tools/preview.py --debug 5      # shadow factor
```

Output lands in `preview/` (git-ignored). `--time` is the Minecraft day cycle:
`0.25` is noon, `0.0` dawn, `0.5` dusk, `0.75` midnight.

## How it works

Iris compiles the pack inside a compatibility-profile environment and supplies a
set of runtime uniforms. The harness reconstructs just enough of that to run the
**unmodified** programs from `shaders/`:

1. `preview_glsl.py` resolves Iris rooted includes, converts
   `#version 330 compatibility` to a core-profile shader, and rewrites the
   compatibility builtins the pack uses — `ftransform()`,
   `gl_ModelViewMatrix`, `gl_NormalMatrix`, `gl_TextureMatrix`,
   `gl_MultiTexCoord*`, `gl_Color`, `gl_Vertex`, `gl_Normal` — into explicit
   uniforms and attributes. Rewriting happens in memory; `shaders/` is never
   edited, so a shot can never drift from what Iris compiles.
2. `preview_scene.py` generates a synthetic voxel world: a heightfield island
   with a shoreline, biome tint, per-vertex terrain AO in `gl_Color.a` (Iris
   `separateAo`), a smooth lightmap with real sky occlusion, alpha-cutout
   foliage, a translucent water surface, and a glowstone pillar as the only
   block-light source. Sky light is stored relative to full daylight so one
   cached geometry build serves every time of day.
3. `preview_render.py` creates a hidden `GLFW` core-profile context, renders a
   real shadow map using the pack's own `shadow` program, draws the scene into an
   `RGBA16F` target matching the `colortex0` directive, and runs `final.fsh` to
   produce the PNG.

Preset selection is read from `shaders.properties`, so `--profile CINEMATIC`
applies exactly the option values Iris would apply, including which boolean
options the preset disables.

## Render targets

The harness reads the pack's own render-target directives rather than assuming
them. `tools/preview_targets.py` parses `/* RENDERTARGETS: ... */`,
`colortexNFormat`, `colortexNClear` / `colortexNClearColor`, and
`size.buffer.colortexN`, and `preview_render.py` allocates the declared target
set and runs every composite-style program (`deferred`, `composite*`, `final`)
in Iris order, binding each pass's declared targets and its `colortexN` /
`depthtex0` / `depthtex1` / `shadowtex0` samplers. The water program's
pre-translucent snapshot is bound as `depthtex1`, matching Iris 1.7.6
(`depthtex0` stays the live scene depth for composite/final timing).
`python3 tools/preview_targets.py` runs a
self-check and dumps the current target set.

At present the pack declares a single `RGBA16F` `colortex0` and one composite
pass (`final`), so this path reduces exactly to the previous single-target
behaviour; a phase that adds a second target or a composite pass is exercised by
the same code.

## What this proves

- The GLSL compiles, links, and interpolates as declared, on the same driver
  family Iris uses on macOS.
- The colour the maths implies, including the linear scene buffer, the
  tone mapper, and the single sRGB transfer.
- Coordinate-space correctness. The pack's known bug class — reading a view-space
  Iris uniform as a world vector — is directly observable here: a wrong
  `gbufferModelViewInverse` mirrors the sun and visibly relights the scene.
- Relative behaviour across presets, and the pack's own debug views
  (`--debug 0..6`).

## What this does NOT prove

- **Iris's own uniform binding and render-layer assignment.** The harness
  supplies those uniforms itself.
- **Iris's macOS compatibility-to-core source rewrite.** The Khronos
  reference compiler used by `tools/validate_shaderpack.py` does not perform it
  either, so neither offline path exercises it.
- **In-game frame pacing or thermal behaviour.** `--bench` reports a wall-clock
  mean for this scene at this resolution with no warmup, which is useful for
  comparing one change against another and is *not* a Minecraft frame time. The
  numbers in a first run include shader compilation and are not comparable.
- Anything about blocks, biomes, or weather the synthetic scene does not
  contain. It is a stand-in with the right interfaces, not a Minecraft world.

A change is **not** certifiable by this harness alone. Visual claims still need
one in-game check on a real Iris install.

## Coordinate spaces

The pack's `docs/PHASE2A.md` and memory notes record the rule this harness
depends on: `sunPosition`, `moonPosition` and `shadowLightPosition` are view
space with length 100, so any use as a world vector must first pass through
`mat3(gbufferModelViewInverse)`. The harness supplies all three and reconstructs
them from a view rotation that is the exact inverse of the one it hands the
vertex stage, so a sign or transpose error there shows up as a mirrored sun
rather than as a subtle grading difference.

`view()` builds the view rotation with its third row negated, so a point in front
of the camera yields a positive clip `w`. `model_view_inverse()` is the true
inverse, not the transpose.

## Failure modes this harness was built to catch

Recorded because each one produced a plausible-looking image rather than an
error, and each is a class that can recur in shader work:

| Symptom | Cause | Why nothing failed loudly |
| --- | --- | --- |
| Flat single-colour frame | Vertex attribute locations out of order with the interleaved buffer | `glGetError` stays clean |
| Water invisible, terrain 1/6 drawn | Triangle count passed to `glDrawElements` as the index count | No GL error; a 2-triangle batch draws nothing |
| Black sun | 3-channel image uploaded as `GL_RGBA` | **No GL error at all**; verified only by reading texels back |
| Sun in the wrong place | `gbufferModelViewInverse` transposed | Silently relights the scene |
| Everything reads as unshadowed | Shadow frustum centred a full shadow-distance ahead of the eye, putting the eye on the map edge where the receiver's border guard returns "lit" | Correct-looking image, feature inert |
| Everything underwater | Terrain heights never rose above sea level | Scene built without asserting its own composition |

Guards now in place: the attribute layout has a single source of truth shared by
the generated vertex prelude and the buffer builder; buffer arrays are shape
checked; `index_count` is distinct from `count`; texture uploads assert their
channel count; and the CLI includes the debug view and nonzero rain strength in
output filenames so distinct deterministic renders cannot silently overwrite
each other.

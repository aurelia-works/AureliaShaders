#!/usr/bin/env python3
"""Regression test for V1-WATER-IRIS: water floor depth must come from depthtex1.

Jar-verified fact (installed ``iris-1.7.6+mc1.20.1.jar``, disassembled with
``javap -c -p``):

- ``IrisRenderingPipeline.beginTranslucents()`` unconditionally calls
  ``RenderTargets.copyPreTranslucentDepth()`` (bytecode offset 27) BEFORE
  ``deferredRenderer.renderAll()`` and translucent rendering — this holds even
  when the pack ships no deferred program.
- ``copyPreTranslucentDepth()`` copies the depth read buffer into the
  ``noTranslucents`` texture (constructed with the name ``"depthtex1"``, via
  ``copyTexImage2D`` or ``DepthCopyStrategy.copy``).
- ``IrisSamplers.addWorldDepthSamplers`` (gbuffers programs) binds sampler
  ``depthtex0`` to the LIVE ``getDepthTexture()`` and ``depthtex1`` to
  ``getDepthTextureNoTranslucents()``.

Therefore during ``gbuffers_water``: ``depthtex1`` is the pre-translucent
opaque floor; ``depthtex0`` may hold the water surface itself (or the live
attachment the pass writes into) — sampling it for floor thickness is wrong
and a feedback risk. The fix binds the floor reconstruction to ``depthtex1``
with no extra read or pass. ``final``/``distant_rain`` timings differ and are
deliberately NOT switched by this test.

This test asserts three things:

1. ``shaders/gbuffers_water.fsh`` declares and samples ``depthtex1`` for the
   floor reconstruction, and contains no ``depthtex0`` token at all.
2. ``tools/preview_render.py`` binds its pre-translucent (opaque-only) depth
   snapshot to the water program as ``depthtex1`` — matching Iris — instead of
   ``depthtex0``. (The composite/final ``depthtex0`` binding for the live scene
   depth is a different timing and is out of scope.)
3. End-to-end determinism: an ADAPTIVE overhead render is byte-identical across
   runs, and water pixels over known-shallow floor columns differ from water
   pixels over known-deep floor columns — i.e. the thickness path is live from
   snapshot to pixel. Thresholds are "differs" margins, not JND claims.

Run: tools/.venv/bin/python tools/test_water_depthtex.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()
WATER_FSH = SHADERS_ROOT / "gbuffers_water.fsh"
RENDER_PY = Path(__file__).parent / "preview_render.py"

SEA_LEVEL = 14.0
WATER_Y = SEA_LEVEL + 0.9


def check_shader_binding() -> list[str]:
    failures: list[str] = []
    source = WATER_FSH.read_text(encoding="utf-8")
    if "uniform sampler2D depthtex1;" not in source:
        failures.append("gbuffers_water.fsh does not declare `uniform sampler2D depthtex1;`")
    if not re.search(r"texture\s*\(\s*depthtex1\s*,", source):
        failures.append("gbuffers_water.fsh does not sample depthtex1 for the floor reconstruction")
    code = re.sub(r"//.*", "", source)  # comments may name depthtex0 to forbid it
    if "depthtex0" in code:
        failures.append("gbuffers_water.fsh references depthtex0 outside comments (live depth during translucents)")
    return failures


def check_harness_binding() -> list[str]:
    failures: list[str] = []
    source = RENDER_PY.read_text(encoding="utf-8")
    if 'location("depthtex1")' not in source:
        failures.append("harness never queries the water program's depthtex1 location")
    if 'sampler("depthtex1"' not in source:
        failures.append("harness never binds the depth snapshot as depthtex1")
    # The snapshot→program binding lives in _draw_geometry; the composite-pass
    # live-depth binding (_bind_composite_samplers) is a different timing.
    draw_geometry = source.split("def _draw_geometry")[1].split("def _geometry_for")[0]
    if '"depthtex0"' in draw_geometry:
        failures.append("harness still binds a depth texture as depthtex0 on the water path")
    return failures


def render_overhead() -> tuple[np.ndarray, object]:
    from preview import camera_for, presets
    from preview_render import PreviewRenderer, Sky, perspective
    from preview_scene import SEA_LEVEL as SCENE_SEA, load_scene

    assert abs(SCENE_SEA + 0.9 - WATER_Y) < 1e-6
    overrides, undefined = presets(SHADERS_ROOT, "ADAPTIVE")
    atlas, world, batches = load_scene(seed=3)
    camera = camera_for("skydive")
    sky = Sky(time=0.25, rain=0.0)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)
    try:
        first, _ = renderer.render(batches, atlas, camera, sky)
        second, _ = renderer.render(batches, atlas, camera, sky)
    finally:
        renderer.close()
    from preview_render import _FAR as FAR, _NEAR as NEAR

    projection = perspective(camera.fov, 960 / 540, NEAR, FAR)
    return first, second, (world, camera, projection)


def sample_water_groups(image: np.ndarray, world, camera, projection) -> tuple[np.ndarray, np.ndarray]:
    """Median RGB of water pixels over shallow vs deep floor columns.

    Every sample is a point on the water plane projected through the same
    view/projection the renderer used; groups split on the column's floor
    height (thickness = WATER_Y - height). Medians resist canopy occluders.
    """
    eye = np.asarray(camera.eye, np.float64)
    view = np.asarray(camera.view(), np.float64)
    proj = np.asarray(projection, np.float64)
    size, origin = world.size, world.origin
    shallow, deep = [], []
    for ix in range(0, size, 1):
        for iz in range(0, size, 1):
            floor_h = float(world.height[ix, iz])
            if not (floor_h < WATER_Y - 0.05):
                continue  # terrain above the plane: no water pixel here
            thickness = WATER_Y - floor_h
            if 0.3 <= thickness <= 1.6:
                bucket = shallow
            elif thickness >= 6.0:
                bucket = deep
            else:
                continue
            world_pt = np.array([ix + origin + 0.5, WATER_Y, iz + origin + 0.5])
            clip = proj @ view @ np.append(world_pt - eye, 1.0)
            if clip[3] <= 0:
                continue
            ndc = clip[:3] / clip[3]
            if np.any(np.abs(ndc[:2]) > 0.92):
                continue
            h, w = image.shape[:2]
            px, py = int((ndc[0] * 0.5 + 0.5) * w), int((1.0 - (ndc[1] * 0.5 + 0.5)) * h)
            if 0 <= px < w and 0 <= py < h:
                bucket.append(image[py, px].astype(np.float32)[:3])
    if len(shallow) < 20 or len(deep) < 20:
        raise AssertionError(
            f"too few projected water samples (shallow {len(shallow)}, deep {len(deep)}); "
            "scene or camera changed, update the test, not the scene"
        )
    return np.median(np.asarray(shallow), axis=0), np.median(np.asarray(deep), axis=0)


def main() -> int:
    failures = check_shader_binding()
    for failure in failures:
        print(f"FAIL: {failure}")
    failures += check_harness_binding()
    for failure in check_harness_binding():
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: water shader and harness bind the floor depth as depthtex1")

    first, second, ctx = render_overhead()
    if first.shape != second.shape:
        print(f"FAIL: frame shapes differ: {first.shape} vs {second.shape}")
        return 1
    if not np.array_equal(first, second):
        diff = np.abs(first.astype(int) - second.astype(int))
        print(f"FAIL: overhead water render is not deterministic (max delta {diff.max()})")
        return 1
    print("PASS: ADAPTIVE overhead render is byte-identical across runs")

    world, camera, projection = ctx
    shallow_med, deep_med = sample_water_groups(first, world, camera, projection)
    gap = float(np.linalg.norm(shallow_med - deep_med))
    print(f"shallow median RGB: {np.round(shallow_med, 1)}  "
          f"deep median RGB: {np.round(deep_med, 1)}  gap: {gap:.1f}/255")
    if gap < 4.0:
        print("FAIL: shallow and deep water render identically; the thickness path is not live")
        return 1
    print("PASS: shallow and deep water differ end-to-end (thickness path live)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

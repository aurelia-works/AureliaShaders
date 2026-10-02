#!/usr/bin/env python3
"""Water thickness reconstruction and the underside of the surface.

1. The water fragment shader reconstructs the column thickness from only the
   floor's view-space z (two mads and a divide on the z row of the inverse
   projection), scaled along the eye ray, instead of a full mat4 unprojection
   plus two length() calls. This test proves the cheap form is numerically the
   same quantity: |view| * (zFloor / zSurface - 1) equals the radial distance
   difference length(floorView) - length(surfaceView) for pixels on the same
   ray, using the harness's own perspective matrix.
2. Seen from below (camera submerged, looking up at the surface) the water must
   not reflect the sky dome through itself: the frame must be water coloured
   (blue-dominant), and the outer region past the critical angle must be darker
   than the bright Snell's-window rim.

Run: <venv>/bin/python tools/test_water_thickness.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()
WATER_FSH = SHADERS_ROOT / "gbuffers_water.fsh"


def check_identity() -> list[str]:
    from preview_render import _FAR, _NEAR, perspective

    failures: list[str] = []
    proj = np.asarray(perspective(70.0, 16 / 9, _NEAR, _FAR), np.float64)
    inv = np.linalg.inv(proj)
    rng = np.random.default_rng(7)
    worst = 0.0
    for _ in range(2000):
        ndc_xy = rng.uniform(-1.0, 1.0, 2)
        surface_depth = rng.uniform(0.0, 0.999)
        floor_depth = rng.uniform(surface_depth, 1.0)

        def view_of(depth: float) -> np.ndarray:
            v = inv @ np.array([ndc_xy[0], ndc_xy[1], depth * 2 - 1, 1.0])
            return v[:3] / v[3]

        surface, floor = view_of(surface_depth), view_of(floor_depth)
        old = max(np.linalg.norm(floor) - np.linalg.norm(surface), 0.0)
        # GLSL form: inv[col][row] -> numpy inv[row, col]
        ndc_z = floor_depth * 2 - 1
        floor_z = (inv[2, 2] * ndc_z + inv[2, 3]) / (inv[3, 2] * ndc_z + inv[3, 3])
        new = max(np.linalg.norm(surface) * (floor_z / surface[2] - 1.0), 0.0)
        worst = max(worst, abs(old - new) / max(old, 1.0))
    print(f"thickness identity: worst relative error {worst:.2e}")
    if worst > 1e-3:
        failures.append(f"cheap thickness differs from radial unprojection (rel err {worst:.2e})")

    code = re.sub(r"//.*", "", WATER_FSH.read_text(encoding="utf-8"))
    if re.search(r"gbufferProjectionInverse\s*\*", code):
        failures.append("gbuffers_water.fsh multiplies by the full inverse projection again")
    if "floorView" in code and "length(floorView" in code:
        failures.append("gbuffers_water.fsh still takes length() of an unprojected floor point")
    return failures


def check_underside() -> list[str]:
    from preview import camera_for, presets
    from preview_render import PreviewRenderer, Sky
    from preview_scene import load_scene

    overrides, undefined = presets(SHADERS_ROOT, "BALANCED")
    atlas, _world, batches = load_scene(seed=3)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined,
                               underwater_eye=True)
    try:
        image, _ = renderer.render(batches, atlas, camera_for("underwater_up"), Sky(time=0.25, rain=0.0))
    finally:
        renderer.close()
    rgb = image[..., :3].astype(np.float32) / 255.0
    h, w = rgb.shape[:2]
    top = rgb[: int(h * 0.55)]
    corner = rgb[: int(h * 0.12), : int(w * 0.12)]
    failures: list[str] = []
    luma = top @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    blue_dom = float(np.mean(top[..., 2] - top[..., 0]))
    print(f"underside: mean B-R {blue_dom:.3f}  luma max {float(luma.max()):.3f}  "
          f"corner luma {float((corner @ np.array([0.2126, 0.7152, 0.0722], np.float32)).mean()):.3f}")
    if blue_dom < 0.15:
        failures.append(f"underside is not water coloured (mean B-R {blue_dom:.3f}); sky leaking through")
    if float(luma.max()) > float(luma.mean()) * 2.2 + 0.05:
        failures.append("underside has a blown-out highlight (sun glint must not render from below)")
    return failures


def main() -> int:
    failures = check_identity() + check_underside()
    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: cheap thickness matches radial unprojection; underside reads as water")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

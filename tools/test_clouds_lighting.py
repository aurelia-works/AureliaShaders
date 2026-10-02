#!/usr/bin/env python3
"""Source-contract tests for the cloud pass (gbuffers_clouds.vsh/.fsh).

These pin the decisions that were bugs or hazards, so a later edit cannot
silently reintroduce them. They read the shipped GLSL; they do not render.

* Fog is applied to the WORLD-axes camera-relative position (playerPosition),
  never a view-space vector: aureliaFogColor reads direction.y / direction.xz
  against world-space sun/zenith, so a view-space vector tilts the horizon with
  camera pitch.
* Face lighting uses the real vertex normal (1.20.1 clouds are
  POSITION_TEX_COLOR_NORMAL) with a zero-normal guard, so a pass that does not
  feed normals degrades to "top face" instead of NaN.
* The fragment stage does not pay a pow() sRGB decode per cloud pixel, and
  discards at vanilla's 0.1 alpha threshold.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def code(name: str) -> str:
    text = (ROOT / "shaders" / name).read_text(encoding="utf-8")
    return re.sub(r"//[^\n]*", "", text)


def main() -> int:
    v, f = code("gbuffers_clouds.vsh"), code("gbuffers_clouds.fsh")
    failures: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    fog = re.search(r"aureliaApplyFogContract\(\s*color\s*,\s*(\w+)", f)
    check(fog is not None, "clouds.fsh must apply aureliaApplyFogContract")
    if fog:
        check(fog.group(1) == "playerPosition",
              f"cloud fog must use world-axes playerPosition, not {fog.group(1)}")

    check("gl_Normal" in v, "clouds.vsh must read the face normal (gl_Normal)")
    check(re.search(r"length\(normal\)", v) is not None and "vec3(0.0, 1.0, 0.0)" in v,
          "clouds.vsh must guard a zero normal with an up fallback")
    check("aureliaMoonDirection" in v, "night clouds must be moon-lit (aureliaMoonDirection)")

    before_soft = f.split("#ifdef AURELIA_CLOUDS_SOFT")[0]
    check(re.search(r"\bpow\s*\(", before_soft) is None,
          "no pow() before the SOFT block in clouds.fsh (use the squared decode)")
    check("aureliaSrgbToLinear" not in f,
          "clouds.fsh must not run the pow-based sRGB decode per pixel")
    check(re.search(r"textureColor\.a\s*<\s*0\.1\b", f) is not None,
          "clouds.fsh must discard below vanilla's 0.1 alpha threshold")
    check("vertexColor" not in f, "clouds.fsh must not consume vanilla's baked vertex tint")

    # Every varying the fragment reads must be written by the vertex stage.
    for name in re.findall(r"^\s*in\s+\w+\s+(\w+)\s*;", f, re.MULTILINE):
        check(re.search(rf"\bout\s+\w+\s+{name}\b", v) is not None,
              f"varying {name} is read by clouds.fsh but not written by clouds.vsh")

    for line in failures:
        print("FAIL:", line)
    if failures:
        return 1
    print("test_clouds_lighting: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

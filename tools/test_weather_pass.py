#!/usr/bin/env python3
"""Source-contract tests for the weather pass and the distant-rain helper.

Pinned decisions (each was a defect or hazard):

* Weather fog is computed per vertex from WORLD-axes playerPosition. The blend
  is linear in colour, so the vertex stage emits (fog-on-black, white-minus-
  black) and the fragment stage does ``color * keep + offset``. A keep factor
  written as ``1 - (white - black)`` would be the fog factor itself, not the
  surviving share, and invert distant rain.
* The fragment stage stays minimal (rain is the most overdrawn thing on screen):
  no fog contract call, no lightmap, no pow().
* Snow is detected from the texture's chroma and takes a white path, so it is
  not cool-greyed by the rain grading.
* distant_rain.glsl: no sin-based hash (precision loss as frameTimeCounter
  grows), textureLod after data-dependent returns, world-axes height.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADERS = ROOT / "shaders"


def code(path: Path) -> str:
    return re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))


def main() -> int:
    v = code(SHADERS / "gbuffers_weather.vsh")
    f = code(SHADERS / "gbuffers_weather.fsh")
    d = code(SHADERS / "lib" / "distant_rain.glsl")
    failures: list[str] = []

    def check(ok: bool, message: str) -> None:
        if not ok:
            failures.append(message)

    check(len(re.findall(r"aureliaApplyFogContract\([^;]*playerPosition", v)) == 2,
          "weather.vsh must evaluate the fog contract twice (black, white) on playerPosition")
    check(re.search(r"fogTerms\s*=\s*vec4\(\s*fogOnBlack\s*,\s*fogOnWhite\.\w+\s*-\s*fogOnBlack\.\w+\s*\)", v) is not None,
          "fogTerms.a must be (white - black): the surviving share, not the fog factor")
    check(re.search(r"\*\s*fogTerms\.a\s*\+\s*fogTerms\.rgb", f) is not None,
          "weather.fsh must apply fog as color * keep + offset")
    check("aureliaApplyFogContract" not in f, "weather.fsh must not run the fog contract per pixel")
    check("lmcoord" not in f and "lmcoord" not in v, "weather has no use for the lightmap")
    check(re.search(r"\bpow\s*\(", f) is None, "weather.fsh must not call pow()")
    check(re.search(r"smoothstep\([^;]*chroma", f) is not None, "snow must be classified by texture chroma")
    check(re.search(r"min\([^;]*,\s*0\.9\s*\)", f) is not None, "coverage must stay clamped below 1.0")

    check("sin(" not in d, "distant_rain.glsl must not use a sin() hash")
    check(re.search(r"\btexture\s*\(", d) is None, "distant_rain.glsl must sample depth with textureLod")
    check(len(re.findall(r"textureLod\(\s*depthtex0", d)) == 2, "expected two textureLod(depthtex0, ...) fetches")
    check("gbufferModelViewInverse" in d, "camera-height estimator must work in world axes")

    for line in failures:
        print("FAIL:", line)
    if failures:
        return 1
    print("test_weather_pass: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Source-contract test for the painted cloud layer (AURELIA_CLOUD_LAYER).

Pins two hazards found in game (2026-10-02):

* Vanilla clouds must be hidden by a FRAGMENT discard. An early return in
  gbuffers_clouds.vsh still drew the slab through Iris's cloud path, with
  unset varyings, as dark rectangles on the horizon.
* lib/clouds2d.glsl once declared frameTimeCounter and cameraPosition, so a
  program that also included lib/water.glsl failed to compile on the
  redeclaration. Both now come from lib/look.glsl and noisetex is declared
  behind AURELIA_NOISETEX_DECLARED. Phase 5 paints the layer in deferred.fsh
  (visible sky pixels only) and gbuffers_water reflects it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

SHADERS = Path(__file__).resolve().parents[1] / "shaders"


def code(path: Path) -> str:
    return re.sub(r"//[^\n]*", "", path.read_text(encoding="utf-8"))


def main() -> int:
    failures = []
    fsh = code(SHADERS / "gbuffers_clouds.fsh")
    if not re.search(r"#ifdef\s+AURELIA_CLOUD_LAYER\s+discard;", fsh):
        failures.append("gbuffers_clouds.fsh must discard under AURELIA_CLOUD_LAYER")
    vsh = code(SHADERS / "gbuffers_clouds.vsh")
    if "AURELIA_CLOUD_LAYER" in vsh or re.search(r"\breturn\s*;", vsh):
        failures.append("gbuffers_clouds.vsh must not hide clouds by an early vertex return")
    includers = sorted(
        p.name for p in SHADERS.rglob("*.*sh")
        if "/lib/clouds2d.glsl" in p.read_text(encoding="utf-8")
    )
    if includers != ["deferred.fsh", "gbuffers_water.fsh"]:
        failures.append(f"lib/clouds2d.glsl must be included by the deferred and water passes only, got {includers}")
    layer = code(SHADERS / "lib" / "clouds2d.glsl")
    if re.search(r"uniform\s+\w+\s+(frameTimeCounter|cameraPosition)\b", layer):
        failures.append("lib/clouds2d.glsl must take frameTimeCounter/cameraPosition from lib/look.glsl")
    if not re.search(r"#ifndef\s+AURELIA_NOISETEX_DECLARED\s+#define\s+AURELIA_NOISETEX_DECLARED\s+uniform\s+sampler2D\s+noisetex;", layer):
        failures.append("lib/clouds2d.glsl must declare noisetex behind AURELIA_NOISETEX_DECLARED")
    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("PASS: cloud layer hides vanilla clouds per fragment; includers cannot redeclare uniforms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

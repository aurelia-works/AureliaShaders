#!/usr/bin/env python3
"""Source-contract test for the painted cloud layer (AURELIA_CLOUD_LAYER).

Pins two hazards found in game (2026-10-02):

* Vanilla clouds must be hidden by a FRAGMENT discard. An early return in
  gbuffers_clouds.vsh still drew the slab through Iris's cloud path, with
  unset varyings, as dark rectangles on the horizon.
* lib/clouds2d.glsl declares frameTimeCounter and cameraPosition, so only
  gbuffers_skybasic may include it; any program that also includes
  lib/water.glsl (frameTimeCounter) would fail to compile on a redeclaration.
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
    if includers != ["gbuffers_skybasic.fsh"]:
        failures.append(f"lib/clouds2d.glsl must be included by gbuffers_skybasic.fsh only, got {includers}")
    for f in failures:
        print(f"FAIL: {f}")
    if failures:
        return 1
    print("PASS: cloud layer hides vanilla clouds per fragment and stays sky-pass only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

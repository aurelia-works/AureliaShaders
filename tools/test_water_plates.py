#!/usr/bin/env python3
"""Regression test for V1-WATER: block-stepped above-water colour plates.

Live defect (in-game screenshots 2026-09-29_09.57.11/.25, ADAPTIVE profile):
overhead river water shows pale rectangular plates aligned to block columns.

Root-cause model: Minecraft bathymetry is voxel-stepped, so the water column
thickness ``t`` reconstructed from ``depthtex1`` (the pre-translucent opaque
copy) jumps by whole blocks at voxel
walls. Overhead, Fresnel is ~0.02, so the pixel is the depth-driven body colour
composited over the floor at the depth-driven alpha. Two high-contrast mappings
of that stepped signal produced the plates:

1. the body curve ran from near-white SHALLOW (0.97, 0.98, 1.00) to MID blue,
2. the shoreline alpha ran to exactly 0 at the waterline (``alpha *= shoreFade``),
   so neighbouring 1-block columns alternated between "no water, see floor"
   and "full water".

Per-vertex biome tint steps are NOT excluded as a secondary contributor: the
screenshots alone cannot separate tint from bathymetry, and this test covers
only the depth/body/alpha path. At grazing angles the radial thickness used
in-shader overstates the true column (slant); the grazing case below is
representative, not exact.

The offline GL harness cannot produce voxel steps: its water is one flat plane
over a smooth heightfield, so thickness varies continuously and no plate ever
forms (that is why an earlier preview wrongly claimed "no artifacts"). This
test is the representative block-stepped case instead: it evaluates the
*shipped GLSL arithmetic* -- numeric constants parsed from
``shaders/lib/water.glsl`` and ``shaders/gbuffers_water.fsh``, failing loudly
if the parsed shape changes -- over a voxel-stepped shoreline transect and a
floor/lighting sensitivity grid, and bounds the per-step composite jump.

What this proves: the depth/body/shore curve's per-block step-contrast is
reduced ~2-3x across the grid. It does NOT prove plates are visually absent:
the 0.15 bound is an engineering margin, not a calibrated JND, and live Iris
depthtex1 copy timing, real bathymetry/biome tint, and the final in-game look need
the NEEDS-IN-GAME checklist in the report.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WATER_GLSL = ROOT / "shaders" / "lib" / "water.glsl"
WATER_FSH = ROOT / "shaders" / "gbuffers_water.fsh"

# 1-block voxel steps across a shoreline: thin columns alternate with
# one-block-deeper neighbours, then the floor falls away block by block.
TRANSECT = (0.15, 1.15, 0.15, 1.15, 2.15, 3.15, 4.15)

BASE_ALPHA = 0.72  # translucent water albedo alpha, as in the preview atlas

# Floor/lighting sensitivity grid: lit floor colour x forward-lit water colour.
# Covers sunlit sand, the bright-sand/shadowed-water corner that broke the
# first candidate (alpha floor 0.60 stepped 0.171 there), and dark rock.
CASES = {
    "sand_sunlit": (np.array([0.55, 0.48, 0.34]), np.array([0.30, 0.38, 0.55])),
    "brightSand_shadowed": (np.array([0.65, 0.60, 0.50]), np.array([0.20, 0.25, 0.35])),
    "brightSand_sunlit": (np.array([0.65, 0.60, 0.50]), np.array([0.30, 0.38, 0.55])),
    "darkRock_shadowed": (np.array([0.25, 0.24, 0.26]), np.array([0.20, 0.25, 0.35])),
}

# Representative grazing case: view-cosine 0.3 gives Schlick ~0.18 and a
# ~0.09 reflection weight, so the body plate signal shrinks ~9% while sky
# reflection dominates. Slant-thickening of the true column is NOT modelled.
GRAZING_REFLECTION = np.array([0.35, 0.50, 0.75])
GRAZING_BODY_KEEP = 0.91

MAX_PLATE_STEP = 0.15  # adjacent-column composite jump (linear euclidean)
MAX_SHALLOW_FLOOR_DIST = 0.45  # shallow water must keep the floor readable
MIN_DEPTH_SEPARATION = 0.06  # deep water must still read deeper than shallow
# Thickness at which the depth grading is judged: fully on the MID->DEEP limb.
DEEP_REFERENCE_T = 10.0


def _vec3(source: str, name: str) -> np.ndarray:
    match = re.search(
        rf"const\s+vec3\s+{re.escape(name)}\s*=\s*vec3\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)",
        source,
    )
    if not match:
        raise AssertionError(f"could not parse {name} from water.glsl; update the test, not the parse")
    return np.array([float(match.group(1)), float(match.group(2)), float(match.group(3))])


def _float(source: str, name: str) -> float:
    match = re.search(
        rf"const\s+float\s+{re.escape(name)}\s*=\s*([\d.]+)\s*;",
        source,
    )
    if not match:
        raise AssertionError(f"could not parse {name} from water.glsl; update the test, not the parse")
    return float(match.group(1))


def _shore_params(fsh: str) -> tuple[float, float, float]:
    """Return ``(edge0, edge1, alpha_floor)`` of the shoreline fade.

    Accepts the accepted ``alpha *= shoreFade;`` form (floor 0) and the
    softened ``alpha *= mix(FLOOR, 1.0, shoreFade);`` form. Anything else is a
    loud failure, not a silent pass.
    """
    fade = re.search(
        r"float\s+aureliaWaterShoreFade\s*\(\s*float\s+\w+\s*\)\s*\{\s*"
        r"return\s+smoothstep\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,",
        (WATER_GLSL.read_text(encoding="utf-8")),
    )
    if not fade:
        raise AssertionError("could not parse aureliaWaterShoreFade; update the test, not the parse")
    edge0, edge1 = float(fade.group(1)), float(fade.group(2))
    softened = re.search(
        r"alpha\s*\*=\s*mix\(\s*([\d.]+)\s*,\s*1\.0\s*,\s*shoreFade\s*\)\s*;", fsh
    )
    if softened:
        return edge0, edge1, float(softened.group(1))
    if re.search(r"alpha\s*\*=\s*shoreFade\s*;", fsh):
        return edge0, edge1, 0.0
    raise AssertionError(
        "unrecognised shoreline alpha form in gbuffers_water.fsh; update the test, not the parse"
    )


def _smoothstep(edge0: float, edge1: float, x: np.ndarray) -> np.ndarray:
    t = np.clip((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def composite(thickness: float, shallow: np.ndarray, mid: np.ndarray, deep: np.ndarray,
              s2m: tuple[float, float], m2d: tuple[float, float],
              shore: tuple[float, float, float],
              floor: np.ndarray, lit_body: np.ndarray, grazing: bool = False) -> np.ndarray:
    """Overhead composite: body(t) at alpha(t) over the floor.

    Overhead the Fresnel cosine is ~1, so Schlick sits at its 0.02 minimum and
    the reflection/glint terms are negligible by construction; the plate signal
    is body-times-alpha, which is exactly what this evaluates. With
    ``grazing=True`` a representative sky reflection carries ~9% of the pixel.
    """
    absorb = shallow + (mid - shallow) * _smoothstep(*s2m, np.float64(thickness))
    absorb = absorb + (deep - absorb) * _smoothstep(*m2d, np.float64(thickness))
    body = lit_body * absorb
    if grazing:
        body = body * GRAZING_BODY_KEEP + GRAZING_REFLECTION * (1.0 - GRAZING_BODY_KEEP)
    shore_fade = float(_smoothstep(shore[0], shore[1], np.float64(thickness)))
    alpha = BASE_ALPHA * (shore[2] + (1.0 - shore[2]) * shore_fade)
    return body * alpha + floor * (1.0 - alpha)


def worst_step(shallow: np.ndarray, mid: np.ndarray, deep: np.ndarray,
               s2m: tuple[float, float], m2d: tuple[float, float],
               shore: tuple[float, float, float],
               floor: np.ndarray, lit_body: np.ndarray, grazing: bool = False) -> float:
    comps = [composite(t, shallow, mid, deep, s2m, m2d, shore, floor, lit_body, grazing)
             for t in TRANSECT]
    return max(float(np.linalg.norm(comps[i] - comps[i - 1])) for i in range(1, len(comps)))


def main() -> int:
    water = WATER_GLSL.read_text(encoding="utf-8")
    fsh = WATER_FSH.read_text(encoding="utf-8")
    if "#ifdef AURELIA_WATER_DEPTH" not in water or "#ifdef AURELIA_WATER_SHORE" not in water:
        raise AssertionError("depth/shore gates moved; update the test, not the parse")
    shallow = _vec3(water, "AURELIA_WATER_BODY_SHALLOW")
    mid = _vec3(water, "AURELIA_WATER_BODY_MID")
    deep = _vec3(water, "AURELIA_WATER_BODY_DEEP")
    s2m = (_float(water, "AURELIA_WATER_SHALLOW_TO_MID"), _float(water, "AURELIA_WATER_MID_TO_DEEP"))
    m2d = (_float(water, "AURELIA_WATER_MID_TO_DEEP"), _float(water, "AURELIA_WATER_DEEP_FULL"))
    shore = _shore_params(fsh)

    comps = [composite(t, shallow, mid, deep, s2m, m2d, shore, *CASES["sand_sunlit"])
             for t in TRANSECT]
    steps = [float(np.linalg.norm(comps[i] - comps[i - 1])) for i in range(1, len(comps))]
    print(f"transect thicknesses : {list(TRANSECT)}")
    print(f"reference-case steps : {[round(s, 3) for s in steps]}")

    failures: list[str] = []
    for name, (floor, lit_body) in CASES.items():
        for grazing in (False, True):
            worst = worst_step(shallow, mid, deep, s2m, m2d, shore, floor, lit_body, grazing)
            tag = f"{name}{'_grazing' if grazing else ''}"
            print(f"worst 1-block jump [{tag:26s}]: {worst:.3f} (limit {MAX_PLATE_STEP})")
            if worst > MAX_PLATE_STEP:
                failures.append(
                    f"PLATES [{tag}]: worst 1-block adjacent jump {worst:.3f} exceeds "
                    f"{MAX_PLATE_STEP} -- voxel-stepped bathymetry imprints rectangular plates"
                )
    floor, lit_body = CASES["sand_sunlit"]
    shallow_dist = float(np.linalg.norm(comps[0] - floor))
    print(f"shallow vs floor     : {shallow_dist:.3f} (limit {MAX_SHALLOW_FLOOR_DIST})")
    if shallow_dist > MAX_SHALLOW_FLOOR_DIST:
        failures.append(
            f"READABILITY: shallow water hides the floor (dist {shallow_dist:.3f} > "
            f"{MAX_SHALLOW_FLOOR_DIST})"
        )
    separation = float(np.linalg.norm(
        composite(DEEP_REFERENCE_T, shallow, mid, deep, s2m, m2d, shore, *CASES["sand_sunlit"]) - comps[1]
    ))
    print(f"deep vs shallow sep  : {separation:.3f} (minimum {MIN_DEPTH_SEPARATION})")
    if separation < MIN_DEPTH_SEPARATION:
        failures.append(
            f"GRADING: depth curve flattened (separation {separation:.3f} < "
            f"{MIN_DEPTH_SEPARATION}); the fix must compress plates, not remove depth"
        )
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("PASS: block-step step-contrast reduced across the grid; shallows readable; depth grading intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

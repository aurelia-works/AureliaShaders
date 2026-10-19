#!/usr/bin/env python3
"""Regression test for V1-WATER: block-stepped above-water colour plates.

Live defect (in-game screenshots 2026-09-29_09.57.11/.25, ADAPTIVE profile):
overhead river water showed PALE rectangular plates aligned to block columns.
Minecraft bathymetry is voxel-stepped, so the water column thickness
reconstructed from ``depthtex1`` jumps by whole blocks at voxel walls, and the
old palette mapped that stepped signal through a near-white SHALLOW colour and
a shoreline alpha that ran to zero. Thin columns came out paler than both the
bed and the deeper water beside them.

Phase 5 replaced the palette with a participating medium (lib/water.glsl,
gbuffers_water.fsh): the bed is read from the opaque scene and attenuated per
channel by Beer-Lambert over the view path plus the bed's depth, and the
column adds its own in-scatter. A stepped bed still shows steps, as a real
stepped bed would, but the defect's signature cannot return as long as the
composite keeps these properties, which this test checks with the shipped
constants over a voxel-stepped transect and a set of bed colours:

* never paler: no column is brighter than the brighter of the bare bed and
  infinitely deep water (the old plates were brighter than both);
* monotonic: luminance moves from the bed toward deep water as the column
  thickens, with no reversal;
* convex: each extra block changes the colour less than the one before
  (Beer-Lambert), so the shallowest step is the largest and bounded;
* readable: a one-block column still shows most of the bed;
* graded: ten blocks of water read clearly deeper than one.

Overhead only (Fresnel 0.02, no fog), in reflectance units: radiance divided
by the downwelling irradiance over pi, so the bed is its albedo. What this
does NOT prove: live depthtex1 timing, biome tint steps, and the in-game look.
"""

from __future__ import annotations

import re
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
WATER_GLSL = ROOT / "shaders" / "lib" / "water.glsl"
WATER_FSH = ROOT / "shaders" / "gbuffers_water.fsh"

# Still water stands 14/16 of a block above its bed block's top, so overhead
# columns are 0.875, 1.875, ... deep; thin and deep neighbours alternate first.
TRANSECT = (0.875, 1.875, 0.875, 1.875, 2.875, 3.875, 4.875)
DEPTHS = np.array((0.875, 1.875, 2.875, 3.875, 4.875, 6.875, 9.875))

BEDS = {
    "sand": np.array([0.55, 0.48, 0.34]),
    "bright_sand": np.array([0.65, 0.60, 0.50]),
    "gravel": np.array([0.35, 0.33, 0.32]),
    "dark_rock": np.array([0.25, 0.24, 0.26]),
}
LUMA = np.array([0.2126, 0.7152, 0.0722])
F0 = 0.02  # overhead Fresnel

# Largest 1-block jump (linear euclidean, reflectance). With the shipped
# coefficients a bright sand bed steps 0.211 from 0.875 to 1.875 blocks, red
# going first; the bound guards against sharper coefficients, not physics.
MAX_FIRST_STEP = 0.25
MIN_SHALLOW_SEEN = 0.55       # luminance share of the bed seen through 0.875 blocks
MIN_DEPTH_SEPARATION = 0.06   # 0.875 vs 9.875 blocks, luminance
PALE_EPS = 1e-6


def _vec3(source: str, name: str) -> np.ndarray:
    match = re.search(
        rf"const\s+vec3\s+{re.escape(name)}\s*=\s*vec3\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*\)", source)
    if not match:
        raise AssertionError(f"could not parse {name} from water.glsl; update the test, not the parse")
    return np.array([float(g) for g in match.groups()])


def _float(source: str, name: str) -> float:
    match = re.search(rf"const\s+float\s+{re.escape(name)}\s*=\s*([\d.]+)\s*;", source)
    if not match:
        raise AssertionError(f"could not parse {name} from water.glsl; update the test, not the parse")
    return float(match.group(1))


def _check_shape(fsh: str, water: str) -> None:
    """Fail loudly if the shipped composite is no longer what this models."""
    code = re.sub(r"//[^\n]*", "", fsh)
    needed = {
        "Beer-Lambert over the view path plus the bed depth":
            r"exp\(\s*-extinction\s*\*\s*\(\s*thickness\s*\+\s*bedDepth\s*\)\s*\)",
        "bed depth from the view ray": r"bedDepth\s*=\s*thickness\s*\*\s*abs\(\s*eyeToFragment\.y\s*\)",
        "bed seen through the column": r"seen\s*=\s*\(\s*1\.0\s*-\s*fresnel\s*\)\s*\*\s*transmittance",
        "refracted composite": r"bed\s*\*\s*seen\s*\+\s*surface\s*\*\s*fog\.a",
        "column in-scatter": r"aureliaWaterInscatter\(\s*downwelling\s*,\s*extinction\s*,\s*thickness\s*\)",
    }
    for what, pattern in needed.items():
        if not re.search(pattern, code):
            raise AssertionError(f"gbuffers_water.fsh changed shape ({what}); update the test, not the parse")
    if not re.search(r"\(1\.0\s*-\s*transmittance\)", water):
        raise AssertionError("aureliaWaterInscatter changed shape; update the test, not the parse")


def composite(bed: np.ndarray, t: float, extinction: np.ndarray, scattering: float,
              backscatter: float) -> np.ndarray:
    """Overhead pixel in reflectance units (no fog, no glint, sky reflection 0)."""
    transmittance = np.exp(-extinction * (t + t))  # thickness + bedDepth, straight down
    seen = (1.0 - F0) * transmittance
    body = (scattering / extinction) * backscatter * (1.0 - np.exp(-extinction * t))
    return bed * seen + (1.0 - F0) * body


def main() -> int:
    water = WATER_GLSL.read_text(encoding="utf-8")
    fsh = WATER_FSH.read_text(encoding="utf-8")
    _check_shape(fsh, water)
    absorption = _vec3(water, "AURELIA_WATER_ABSORPTION")
    scattering = _float(water, "AURELIA_WATER_SCATTERING")
    backscatter = _float(water, "AURELIA_WATER_BACKSCATTER")
    extinction = absorption + scattering
    deep = (1.0 - F0) * (scattering / extinction) * backscatter

    failures: list[str] = []
    for name, bed in BEDS.items():
        trans = [composite(bed, t, extinction, scattering, backscatter) for t in TRANSECT]
        steps = [float(np.linalg.norm(trans[i] - trans[i - 1])) for i in range(1, len(trans))]
        column = [composite(bed, t, extinction, scattering, backscatter) for t in DEPTHS]
        lum = np.array([float(c @ LUMA) for c in column])
        print(f"{name:12s} steps {[round(s, 3) for s in steps]}  luma {lum.round(3).tolist()}")

        ceiling = np.maximum(bed, deep)
        for t, c in zip(DEPTHS, column):
            if np.any(c > ceiling + PALE_EPS):
                failures.append(f"PALE [{name}] {t} blocks is brighter than both bed and deep water: {c.round(3)}")
        target = float(deep @ LUMA)
        distance = np.abs(lum - target)
        if np.any(np.diff(distance) > PALE_EPS):
            failures.append(f"NON-MONOTONIC [{name}]: luminance does not settle toward deep water: {lum.round(3)}")
        jumps = np.abs(np.diff(lum)) / np.diff(DEPTHS)  # per block: the depths are not evenly spaced
        if np.any(np.diff(jumps) > PALE_EPS):
            failures.append(f"NOT CONVEX [{name}]: a deeper block changes more than a shallower one: {jumps.round(3)}")
        if max(steps) > MAX_FIRST_STEP:
            failures.append(f"PLATES [{name}]: 1-block jump {max(steps):.3f} exceeds {MAX_FIRST_STEP}")
        seen = float((composite(bed, DEPTHS[0], extinction, 0.0, 0.0) @ LUMA) / (bed @ LUMA))
        if seen < MIN_SHALLOW_SEEN:
            failures.append(f"READABILITY [{name}]: one block shows only {seen:.2f} of the bed")
        if abs(lum[0] - lum[-1]) < MIN_DEPTH_SEPARATION:
            failures.append(f"GRADING [{name}]: 10 blocks read like 1 ({lum[0]:.3f} vs {lum[-1]:.3f})")

    for failure in failures:
        print(f"FAIL: {failure}")
    if failures:
        return 1
    print("PASS: water never paler than its bed, settles monotonically with depth, shallows readable")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

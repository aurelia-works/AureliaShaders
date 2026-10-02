"""Regression test: Nether (hasCeiling) sky/fog must follow Minecraft's fogColor,
not the sun-driven day/night palette.

The defect this guards: the Nether's sun is fixed below the horizon, so the
analytic palette fell to its night navy there instead of the Nether fogColor.
`lib/sky.glsl` now returns fogColor directly from both palette entry points
when Iris's `hasCeiling` uniform is true. The assertions pin behaviour:

  - hasCeiling = false (Overworld, or an Iris without the uniform): the upper
    frame DIFFERS between noon and midnight (the palette is alive);
  - hasCeiling = true: the upper frame is IDENTICAL between noon and midnight
    (time-independent) and flat (no gradient, no stars, no discs).

Run: tools/.venv/bin/python tools/test_sky_nether.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from preview import camera_for, presets
from preview_render import PreviewRenderer, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()
NOON, MIDNIGHT = 0.25, 0.75


def top_band(image: np.ndarray) -> np.ndarray:
    """Upper-left block: open sky for the nightsky camera (the foliage and the
    cloud slab sit to the right and below)."""
    rgb = image[..., :3].astype(np.float32)
    return rgb[: rgb.shape[0] * 2 // 5, : rgb.shape[1] * 2 // 5]


def main() -> int:
    overrides, undefined = presets(SHADERS_ROOT, "BALANCED")
    atlas, _, batches = load_scene(seed=3)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)
    original = renderer._common_uniforms
    nether = {"on": False}

    def patched(camera, sky, adaptive):
        uniforms = original(camera, sky, adaptive)
        uniforms["hasCeiling"] = nether["on"]
        # Constant Minecraft colours so only the palette logic can vary.
        uniforms["fogColor"] = np.array([0.20, 0.05, 0.03], np.float32)
        uniforms["skyColor"] = np.array([0.20, 0.05, 0.03], np.float32)
        return uniforms

    renderer._common_uniforms = patched

    def band(time: float, on: bool) -> np.ndarray:
        nether["on"] = on
        image, _ = renderer.render(batches, atlas, camera_for("nightsky"), Sky(time=time))
        if len(sys.argv) > 1:  # optional: dump frames for eyeballing
            from PIL import Image
            Image.fromarray(image[..., :3]).save(f"{sys.argv[1]}_{int(on)}_{time}.png")
        return top_band(image)

    failures = []
    over_day, over_night = band(NOON, False), band(MIDNIGHT, False)
    delta_over = float(np.abs(over_day - over_night).mean())
    print(f"overworld noon-vs-midnight mean delta: {delta_over:.2f}/255")
    if delta_over < 5.0:
        failures.append("overworld sky should change between noon and midnight")

    nether_day, nether_night = band(NOON, True), band(MIDNIGHT, True)
    delta_nether = float(np.abs(nether_day - nether_night).max())
    spread = float(nether_night.reshape(-1, 3).std(axis=0).max())
    print(f"nether noon-vs-midnight max delta: {delta_nether:.2f}  spread: {spread:.2f}")
    if delta_nether > 1.0:
        failures.append("nether sky must not depend on time of day")
    if spread > 1.5:
        failures.append("nether sky must be a flat fogColor, with no gradient or stars")

    if failures:
        for message in failures:
            print(f"FAIL: {message}")
        return 1
    print("PASS: hasCeiling pins the sky to fogColor; Overworld is untouched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

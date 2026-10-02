"""Regression test: heavy rain must hide the sky's celestial bodies and must
never brighten the night.

Offline reproduced failures this guards (in-game rain/night behavior still
to verify live; numbers below are the reproducible in-process baseline from
this file's own RED run — BALANCED, seed 3 — not CLI captures):

  1. At rainStrength 1.0 the full sun disc stayed visible (sunview, t=0.03:
     395 pixels above 0.80 luma vs 655 dry). Vanilla hides the sun behind
     rain clouds; the disc path only dimmed to ~45%.
  2. At rainStrength 1.0 the moon disc and star field stayed visible at night
     (nightsky, t=0.75: frame max 0.74 luma, p99.9 0.72).
  3. Rain BRIGHTENED the night sky 4.00x (nightsky mean luma 0.0517 dry vs
     0.2069 at rain 1.0): the authored day-tuned overcast pair was mixed into
     the night navy at full weight instead of being dimmed by the day/night
     blend.

The assertions are directional (rain hides bodies; rain never brightens
night), not fitted to exact pixel values, so they guard the behaviour
without locking the palette.

Run: tools/.venv/bin/python tools/test_sky_rain.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from preview import camera_for, presets
from preview_render import PreviewRenderer, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()

# Sun low in frame (matches the sunview camera's t~=0.03 aim); moon overhead
# at midnight (matches the nightsky camera's aim).
SUN_CASE = ("sunview", 0.03)
MOON_CASE = ("nightsky", 0.75)


def luma(image: np.ndarray) -> np.ndarray:
    rgb = image[..., :3].astype(np.float32) / 255.0
    return rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def render(renderer: PreviewRenderer, atlas: np.ndarray, batches: dict,
           camera_name: str, time: float, rain: float) -> np.ndarray:
    image, _ = renderer.render(batches, atlas, camera_for(camera_name),
                               Sky(time=time, rain=rain))
    return image


def main() -> int:
    failures = []
    overrides, undefined = presets(SHADERS_ROOT, "BALANCED")
    atlas, _, batches = load_scene(seed=3)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)

    frames = {}
    for label, (cam, t), rain in (
        ("sun-dry", SUN_CASE, 0.0),
        ("sun-rain1", SUN_CASE, 1.0),
        ("night-dry", MOON_CASE, 0.0),
        ("night-rain1", MOON_CASE, 1.0),
    ):
        frames[label] = luma(render(renderer, atlas, batches, cam, t, rain))

    # T1: rain must never brighten the night sky. The bug mixed the day
    # overcast into the night navy and reached a 4.00x mean-luma ratio.
    night_dry, night_rain = frames["night-dry"].mean(), frames["night-rain1"].mean()
    print(f"T1 night mean luma: dry={night_dry:.4f} rain1={night_rain:.4f} "
          f"(ratio {night_rain / max(night_dry, 1e-6):.2f}x)")
    if night_rain > night_dry * 1.5:
        failures.append(
            f"T1: rain brightens the night sky ({night_rain:.4f} vs dry {night_dry:.4f})")

    # T2: the sun disc must hide in full overcast. The dry sunrise baseline
    # keeps ~650 pixels above 0.80 luma (disc + core glow); rain 1.0 must
    # leave at most a 10% remnant of that glare.
    sun_dry = int((frames["sun-dry"] > 0.80).sum())
    sun_rain = int((frames["sun-rain1"] > 0.80).sum())
    print(f"T2 sunrise pixels >0.80 luma: dry={sun_dry} rain1={sun_rain}")
    if sun_dry < 100:
        failures.append(f"T2: setup broken, dry sun glare too small ({sun_dry})")
    elif sun_rain > 0.10 * sun_dry:
        failures.append(
            f"T2: sun shines through full rain ({sun_rain} bright pixels, dry {sun_dry})")

    # T3: moon and stars must hide in full overcast. The rainy night frame
    # must contain no bright outliers: dry-night moon peaks at ~0.9, so a
    # 0.5 ceiling is far above any smooth-sky value yet far below any disc.
    night_max = float(frames["night-rain1"].max())
    night_p999 = float(np.percentile(frames["night-rain1"], 99.9))
    print(f"T3 rainy-night max={night_max:.3f} p99.9={night_p999:.3f}")
    if night_max > 0.50:
        failures.append(
            f"T3: moon/stars visible through full rain (max luma {night_max:.3f})")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: heavy rain hides sun/moon/stars and never brightens the night")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

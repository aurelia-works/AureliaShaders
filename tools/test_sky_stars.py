"""Regression test: the star fade must be monotonic through dusk and zero by day.

The defect this guards: `aureliaApplyStars` in `shaders/lib/sky.glsl` used
`float darkness = smoothstep(-0.10, -0.28, sunHeight)` — edge0 greater than
edge1, which is undefined behavior per the GLSL specification (section 8.3:
results are undefined if edge0 >= edge1). Most drivers happen to return the
reversed ramp, which is why the offline renders looked right, but the shader
was relying on undefined behavior, so the fade was fixed to the explicit form
`1.0 - smoothstep(-0.28, -0.10, sunHeight)`.

The assertions pin the specified behavior, not exact pixels:

  - daylight (sun well up): no star points anywhere in the upper frame;
  - dusk progression (sunHeight +0.0 down past -0.28): point brightness in
    the upper frame rises monotonically, then holds at full night;
  - full night: the point field is substantially above the daylight floor.

Method: stars are single-pixel spikes, while clouds, the moon glow and the
dome gradient are all broad. Subtracting a 5x5 median removes everything
broad, leaving point contrast; the 99th percentile of that residual (`hp99`)
tracks the star field. The analysis window is the top half of the `nightsky`
camera frame (elevations the midnight moon never reaches at the sampled
dusk times), and all samples run dry (`rain = 0`). Thresholds below carry
~2x headroom over the measured BALANCED/seed-3 baseline, recorded in the
prints; they are ceilings/ratios on behavior, not fitted pixel values.

Run: tools/.venv/bin/python tools/test_sky_stars.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from preview import camera_for, presets
from preview_render import PreviewRenderer, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()

# Dusk progression for the midnight-moon camera: the moon stays low (out of
# the top-half analysis window) at every sampled time, and the sun is out of
# frame from t=0.45 on, so the residual tracks the star field alone.
DAY_TIME = 0.45
DUSK_SERIES = (0.50, 0.51, 0.52, 0.53, 0.55)

# Ceiling on daylight point contrast (measured ~0.010); the dusk plateau
# measures ~0.045, so this leaves 2x headroom below any star field.
DAY_HP99_MAX = 0.020
# Full-night point contrast must exceed this multiple of the daylight floor.
NIGHT_DAY_RATIO_MIN = 3.0
# Allowed dip between consecutive dusk samples (8-bit quantization noise).
MONOTONIC_EPS = 0.002


def luma(image: np.ndarray) -> np.ndarray:
    rgb = image[..., :3].astype(np.float32) / 255.0
    return rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)


def median_filter(a: np.ndarray, k: int = 5) -> np.ndarray:
    p = k // 2
    ap = np.pad(a, p, mode="edge")
    h, w = a.shape
    wins = np.empty((h, w, k * k), np.float32)
    i = 0
    for dy in range(k):
        for dx in range(k):
            wins[:, :, i] = ap[dy:dy + h, dx:dx + w]
            i += 1
    return np.median(wins, axis=2)


def point_contrast(renderer: PreviewRenderer, atlas: np.ndarray, batches: dict,
                   time: float) -> float:
    image, _ = renderer.render(batches, atlas, camera_for("nightsky"),
                               Sky(time=time, rain=0.0))
    top = luma(image)[: image.shape[0] // 2, :]
    return float(np.percentile(top - median_filter(top), 99))


def main() -> int:
    failures = []
    overrides, undefined = presets(SHADERS_ROOT, "BALANCED")
    atlas, _, batches = load_scene(seed=3)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)

    day = point_contrast(renderer, atlas, batches, DAY_TIME)
    print(f"day t={DAY_TIME}: hp99={day:.4f} (ceiling {DAY_HP99_MAX})")
    if day > DAY_HP99_MAX:
        failures.append(f"daylight star points visible (hp99 {day:.4f})")

    series = []
    for t in DUSK_SERIES:
        v = point_contrast(renderer, atlas, batches, t)
        series.append(v)
        print(f"dusk t={t}: hp99={v:.4f}")
    for prev, cur, t in zip(series, series[1:], DUSK_SERIES[1:]):
        if cur < prev - MONOTONIC_EPS:
            failures.append(
                f"star fade not monotonic at t={t} ({prev:.4f} -> {cur:.4f})")

    night = series[-1]
    print(f"night/day point-contrast ratio: {night / max(day, 1e-6):.2f}x "
          f"(minimum {NIGHT_DAY_RATIO_MIN}x)")
    if night < NIGHT_DAY_RATIO_MIN * max(day, 1e-6):
        failures.append("star field never rises above the daylight floor")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: star fade rises monotonically through dusk and is zero by day")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

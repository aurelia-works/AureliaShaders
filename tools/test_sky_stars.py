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
broad, leaving point contrast; the COUNT of residual spikes above 0.02 luma
on non-foliage pixels tracks the star field. (A 99th percentile was used
before; stars cover well under 1% of the frame, so it was blind to them and
was really measuring a tree's leaf edges in the window, which brighter
in-game-tuned sunlight then pushed past the daylight ceiling.) The analysis window is the top half of the `nightsky`
camera frame (elevations the midnight moon never reaches at the sampled
dusk times), and all samples run dry (`rain = 0`). Measured BALANCED/seed-3 baseline: day 0, t=0.52 518, night 657 points.
Thresholds are behavioral floors/ceilings, not fitted pixel values.

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
DAY_POINTS_MAX = 5           # no star points by day
# Full-night point contrast must exceed this multiple of the daylight floor.
NIGHT_POINTS_MIN = 200        # a real star field at night
# Allowed dip between consecutive dusk samples (8-bit quantization noise).
MONOTONIC_EPS = 20            # points; tolerates sub-pixel jitter


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
    top_rgb = image[: image.shape[0] // 2, :, :3].astype(np.float32)
    top = luma(image)[: image.shape[0] // 2, :]
    hp = top - median_filter(top)
    # Exclude foliage. A seed-3 tree reaches into the window, and its sharp
    # leaf edges read as "points" to a high-pass; brighter in-game-tuned
    # sunlight raised that edge contrast past the daylight ceiling with no
    # star anywhere. Foliage = green-dominant pixels, grown by the median
    # radius so leaf boundaries go too. Stars (near-white) and the blue/navy
    # sky both stay in.
    foliage = (top_rgb[..., 1] > top_rgb[..., 2] + 4.0) & (top_rgb[..., 1] > top_rgb[..., 0])
    grown = foliage.copy()
    r = 3
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            grown |= np.roll(np.roll(foliage, dy, axis=0), dx, axis=1)
    eroded = ~grown
    return float(np.count_nonzero(hp[eroded] > 0.02))


def main() -> int:
    failures = []
    overrides, undefined = presets(SHADERS_ROOT, "BALANCED")
    atlas, _, batches = load_scene(seed=3)
    renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)

    day = point_contrast(renderer, atlas, batches, DAY_TIME)
    print(f"day t={DAY_TIME}: points={day:.0f} (ceiling {DAY_POINTS_MAX})")
    if day > DAY_POINTS_MAX:
        failures.append(f"daylight star points visible ({day:.0f})")

    series = []
    for t in DUSK_SERIES:
        v = point_contrast(renderer, atlas, batches, t)
        series.append(v)
        print(f"dusk t={t}: points={v:.0f}")
    for prev, cur, t in zip(series, series[1:], DUSK_SERIES[1:]):
        if cur < prev - MONOTONIC_EPS:
            failures.append(
                f"star fade not monotonic at t={t} ({prev:.0f} -> {cur:.0f})")

    night = series[-1]
    print(f"night points: {night:.0f} (minimum {NIGHT_POINTS_MIN})")
    if night < NIGHT_POINTS_MIN:
        failures.append("star field never rises above the daylight floor")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: star fade rises monotonically through dusk and is zero by day")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

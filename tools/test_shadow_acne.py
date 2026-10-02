"""Regression test: noon shadow factor must not show self-shadow acne.

With the sun high, almost every upward face of the island is unshadowed, so the
debug-5 shadow factor should be ~1.0 over most of the frame. Acne (a surface
shadowing itself through depth quantisation) shows up as a large mid-grey band
fraction: pixels strictly between full shadow and full light. The old depth-only
bias left 11-12% of the noon overview in that band at LOW/CINEMATIC; the
texel-scaled normal-offset bias plus distorted map keeps it near 2-5%.

Thresholds are ceilings with ~1.5x headroom over the post-fix measurement, plus
sanity floors (lit area dominant, real shadows still present) so that a
"fix" that simply turns shadows off cannot pass.

Run: tools/.venv/bin/python tools/test_shadow_acne.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from preview import camera_for, presets
from preview_render import PreviewRenderer, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()

NOON = 0.25
PENUMBRA_MAX = 0.08       # measured 0.019 .. 0.055 after the fix
LIT_MIN = 0.85            # measured 0.93 .. 0.97
SHADOW_MIN = 0.005        # measured 0.011 .. 0.025: shadows must still exist


def main() -> int:
    atlas, _, batches = load_scene(seed=3)
    failures = []
    for profile in ("LOW", "BALANCED", "CINEMATIC"):
        overrides, undefined = presets(SHADERS_ROOT, profile)
        overrides = dict(overrides)
        overrides["AURELIA_DEBUG_VIEW"] = "5"
        renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)
        image, _ = renderer.render(batches, atlas, camera_for("overview"),
                                   Sky(time=NOON, rain=0.0))
        factor = image[..., :3].astype(np.float32).mean(axis=2) / 255.0
        lit = float((factor > 0.97).mean())
        shadow = float((factor < 0.7).mean())
        penumbra = float(((factor > 0.55) & (factor < 0.97)).mean())
        print(f"{profile:9s} lit={lit:.3f} shadow={shadow:.3f} penumbra={penumbra:.3f}")
        if penumbra > PENUMBRA_MAX:
            failures.append(f"{profile}: acne-like mid-grey fraction {penumbra:.3f} > {PENUMBRA_MAX}")
        if lit < LIT_MIN:
            failures.append(f"{profile}: lit fraction {lit:.3f} < {LIT_MIN}")
        if shadow < SHADOW_MIN:
            failures.append(f"{profile}: no shadows rendered ({shadow:.4f})")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: noon shadow factor is clean and shadows are still cast")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

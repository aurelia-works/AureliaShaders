"""Regression tests for the final grade: banding, ACES matrices, alpha.

Defects guarded (shaders/final.fsh, shaders/lib/tonemap.glsl):

  1. 8-bit banding. Sky and fog are smooth float gradients; the final pass
     quantizes them to RGBA8 and the ACES curve stretches the shadows, leaving
     visible contour steps. The final pass adds +-0.5 LSB interleaved-gradient
     noise before quantization. This test renders a sky-only frame with and
     without the dither line and requires the longest run of identical pixels
     along a row to collapse.
  2. ACES matrices. GLSL mat3 constructors fill columns; a transposed matrix
     hue-shifts clipped warm colours. The test parses the matrices out of the
     GLSL, rebuilds them column-major, and requires the canonical Hill rows,
     unit row sums (neutral stays neutral) and the canonical curve constants.
  3. The screen alpha is explicit 1.0, not the scene buffer's alpha.

Run: tools/.venv/bin/python tools/test_grade_banding.py
"""

import re
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

from preview import camera_for, presets
from preview_render import PreviewRenderer, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()

CANON_IN = np.array([[0.59719, 0.35458, 0.04823],
                     [0.07600, 0.90834, 0.01566],
                     [0.02840, 0.13383, 0.83777]])
CANON_OUT = np.array([[1.60475, -0.53108, -0.07367],
                      [-0.10208, 1.10813, -0.00605],
                      [-0.00327, -0.07276, 1.07602]])
DITHER = re.compile(r"\n    // 1-ALU-class interleaved.*?\* \(1\.0 / 255\.0\);\n", re.S)


def glsl_mat3(source: str, name: str) -> np.ndarray:
    m = re.search(rf"mat3 {name}\s*=\s*mat3\(([^;]*)\);", source, re.S)
    v = np.array([float(x) for x in m.group(1).replace("\n", " ").split(",")])
    return v.reshape(3, 3).T  # constructor args are columns -> transpose to rows


def longest_run(image: np.ndarray) -> float:
    """Mean over rows of the longest horizontal run of equal RGB pixels."""
    same = np.all(image[:, 1:, :3] == image[:, :-1, :3], axis=2)
    best = []
    for row in same:
        cur = mx = 0
        for s in row:
            cur = cur + 1 if s else 0
            mx = max(mx, cur)
        best.append(mx)
    return float(np.mean(best))


def sky_frame(root: Path) -> np.ndarray:
    overrides, undefined = presets(root, "BALANCED")
    atlas, _, batches = load_scene(seed=3)
    renderer = PreviewRenderer(root, overrides=overrides, undefined=undefined)
    image, _ = renderer.render(batches, atlas, camera_for("sky"),
                               Sky(time=0.35, rain=0.0))
    return image[: image.shape[0] // 3]  # top third: pure sky gradient


def main() -> int:
    failures = []
    tonemap = (SHADERS_ROOT / "lib/tonemap.glsl").read_text(encoding="utf-8")
    final = (SHADERS_ROOT / "final.fsh").read_text(encoding="utf-8")

    for name, canon in (("inputMat", CANON_IN), ("outputMat", CANON_OUT)):
        got = glsl_mat3(tonemap, name)
        if not np.allclose(got, canon, atol=1e-6):
            failures.append(f"{name} is not the canonical ACES fit (transposed?)")
        sums = got.sum(axis=1)
        print(f"{name} row sums: {np.round(sums, 5)}")
        if not np.allclose(sums, 1.0, atol=2e-5):
            failures.append(f"{name} rows do not sum to 1: neutral would tint")
    for const in ("0.0245786", "0.000090537", "0.983729", "0.4329510", "0.238081"):
        if const not in tonemap:
            failures.append(f"ACES curve constant {const} missing")

    if not re.search(r"vec4\(color, 1\.0\)", final):
        failures.append("final.fsh must write an explicit alpha of 1.0")

    if not DITHER.search(final):
        failures.append("dither block not found in final.fsh (test pattern stale?)")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            off = (Path(tmp).resolve() / "shaders")
            shutil.copytree(SHADERS_ROOT, off)
            (off / "final.fsh").write_text(DITHER.sub("\n", final), encoding="utf-8")
            run_off = longest_run(sky_frame(off))
        run_on = longest_run(sky_frame(SHADERS_ROOT))
        print(f"mean longest equal-pixel run in sky rows: no dither {run_off:.1f}, "
              f"dither {run_on:.1f}")
        if run_off < 8.0:
            failures.append("undithered sky is not banded; test lost its power")
        if run_on > run_off * 0.5:
            failures.append("dither does not break up sky banding")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: canonical ACES matrices, explicit alpha, dither breaks banding")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

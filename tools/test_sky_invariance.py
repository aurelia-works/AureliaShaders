"""Regression test: the analytic sky must not depend on Minecraft's sky mesh.

The in-game failure this guards: Minecraft hands gbuffers_skybasic DIFFERENT
vertex colours per sky draw call (the upper dome is tinted by the sky colour,
the lower plane by a lighter horizon/void tint) and draws those pieces at
DIFFERENT camera distances (so gl_FragCoord.z differs between them). Two bugs
let that geometry-only state into the analytic atmosphere:

  1. the sky output was multiplied by aureliaSrgbToLinear(vertexColor.rgb) -
     the authored palette was multiplied by Minecraft's region colours, which
     split the day sky into a dark saturated upper half and a light lower
     half, and multiplied the night navy to pure black;
  2. the screen-space ray was unprojected with gl_FragCoord.z instead of a
     fixed far-plane depth, so the reconstructed direction depended on which
     sky piece covered the pixel.

This test renders the full pipeline twice: once with the harness's plain
uniform-white sky cube, once with a cube that strongly varies vertex colour
between the upper and lower geometry AND sits the lower half at a much closer
radius (so fragment depth differs). The analytic atmosphere must produce the
identical RGB at every pixel in both runs; any difference means geometry-only
state is leaking into the sky again.

Run: tools/.venv/bin/python tools/test_sky_invariance.py
"""

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))

import preview_render as pr
from preview import presets
from preview_render import PreviewRenderer, RawBatch, Sky
from preview_scene import load_scene

SHADERS_ROOT = (Path(__file__).parent.parent / "shaders").resolve()


def two_tone_skybox(upper_radius: float = 600.0, lower_radius: float = 120.0) -> RawBatch:
    """A sky cube whose vertex colours and depths vary per geometry piece.

    Colours imitate Iris's real sky-mesh tinting: the upper faces carry the
    sky colour, the lower faces the lighter fog/void tint, the sides graded by
    the face normal's height. The lower half is drawn at a far smaller radius,
    so its fragment depth (and therefore gl_FragCoord.z) differs strongly from
    the dome's. With the buggy shader both differences changed the rendered
    sky; with the fixed shader they must change nothing.
    """
    sky_color = np.array([0.44, 0.63, 1.00], np.float32)     # vanilla-like upper tint
    fog_color = np.array([0.68, 0.80, 0.97], np.float32)     # vanilla-like lower tint
    r_up, r_lo = float(upper_radius), float(lower_radius)
    faces = (
        # (normal, corners) - wound so the inside is visible, mirroring skybox().
        ((1, 0, 0), ((r_up, -r_lo, -r_lo), (r_up, -r_lo, r_lo), (r_up, r_up, r_up), (r_up, r_up, -r_up))),
        ((-1, 0, 0), ((-r_up, -r_lo, r_lo), (-r_up, -r_lo, -r_lo), (-r_up, r_up, -r_up), (-r_up, r_up, r_up))),
        ((0, 1, 0), ((-r_up, r_up, -r_up), (r_up, r_up, -r_up), (r_up, r_up, r_up), (-r_up, r_up, r_up))),
        ((0, -1, 0), ((-r_lo, -r_lo, r_lo), (r_lo, -r_lo, r_lo), (r_lo, -r_lo, -r_lo), (-r_lo, -r_lo, -r_lo))),
        ((0, 0, 1), ((-r_up, -r_lo, r_lo), (-r_up, r_up, r_lo), (r_up, r_up, r_lo), (r_up, -r_lo, r_lo))),
        ((0, 0, -1), ((r_up, -r_lo, -r_lo), (r_up, r_up, -r_lo), (-r_up, r_up, -r_lo), (-r_up, -r_lo, -r_lo))),
    )
    position, normal, color, index = [], [], [], []
    for face, (n, corners) in enumerate(faces):
        base = face * 4
        position.extend(corners)
        normal.extend([n] * 4)
        # Vertex colour graded by the face's own height, as Minecraft does.
        height = float(n[1])
        tint = fog_color + (sky_color - fog_color) * (height * 0.5 + 0.5)
        color.extend([(*tint, 1.0)] * 4)
        index.extend([[base, base + 1, base + 2], [base + 2, base + 3, base]])
    count = len(position)
    return RawBatch(
        position,
        np.asarray(normal, np.float32),
        np.zeros((count, 2), np.float32),
        np.asarray(color, np.float32),
        np.ones((count, 2), np.float32),
        index,
    )


def render_frame(renderer: PreviewRenderer, atlas: np.ndarray, batches: dict, sky: Sky) -> np.ndarray:
    image, _ = renderer.render(batches, atlas, camera_for_sky(), sky)
    return image


def camera_for_sky():
    from preview import camera_for

    return camera_for("sky")


def main() -> int:
    overrides, undefined = presets(SHADERS_ROOT, "ADAPTIVE")
    atlas, _, batches = load_scene(seed=3)
    sky = Sky(time=0.25, rain=0.0)

    frames: dict[str, np.ndarray] = {}
    original_skybox = pr.skybox
    variants = (
        ("uniform", lambda: original_skybox()),
        ("two-tone/depth-varied", two_tone_skybox),
    )
    for label, skybox_builder in variants:
        original = pr.skybox
        pr.skybox = skybox_builder
        try:
            # A fresh renderer per variant: the geometry cache keys on batch
            # identity, but rebuilding proves nothing is carried over.
            renderer = PreviewRenderer(SHADERS_ROOT, overrides=overrides, undefined=undefined)
            frames[label] = render_frame(renderer, atlas, batches, sky)
        finally:
            pr.skybox = original

    a, b = frames["uniform"], frames["two-tone/depth-varied"]
    if a.shape != b.shape:
        print(f"FAIL: frame shapes differ: {a.shape} vs {b.shape}")
        return 1
    diff = np.abs(a.astype(int) - b.astype(int))
    worst = int(diff.max())
    changed = int((diff.sum(axis=2) > 2).sum())
    print(f"max channel delta: {worst}   pixels changed >2: {changed} / {a.shape[0]*a.shape[1]}")
    if worst > 2:
        ys, xs = np.where(diff.sum(axis=2) > 2)
        print(f"FAIL: sky RGB depends on sky-mesh vertex colour/depth (e.g. at "
              f"({ys[0]},{xs[0]}): {tuple(a[ys[0], xs[0]])} vs {tuple(b[ys[0], xs[0]])})")
        return 1
    print("PASS: analytic sky RGB is invariant to sky-mesh vertex colour and fragment depth")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
